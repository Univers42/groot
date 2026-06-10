use crate::abac::{Decision, Evaluator, PermissionMode, PolicyBundle};
use crate::config::ServerConfig;
use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use axum::body::Body;
use axum::extract::Request;
use axum::http::header;
use axum::middleware::Next;
use axum::response::Response;
use crate::metrics::{escape_label, Metrics};
use data_plane_core::{
    DataOperation, DataPlaneError, DatabaseMount, EngineAdapter, EngineCapabilities,
    MigrationRequest, Plan, PoolRegistry, RawStatement, RequestIdentity, SchemaDdlRequest,
    TxBeginRequest, TxHandle, WorkloadContext,
};
use data_plane_pool::{
    DefaultPoolRegistry, EnvMountResolver, HttpEngineAdapter, MongoEngineAdapter,
    MysqlEngineAdapter, PgDialect, PostgresEngineAdapter, ProviderConfig, RedisEngineAdapter,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use tokio::sync::Mutex;
use tower_http::{cors::CorsLayer, trace::TraceLayer};

/// Lives inside `AppState`. Owns active multi-statement transaction handles
/// keyed by `tx_id`. Concurrent calls to the same `tx_id` are serialised by
/// the per-handle internal `Mutex` (see `PgTxHandle`), but the registry-level
/// map itself uses a tokio `Mutex` because we mutate it across `.await`.
#[derive(Default)]
struct TransactionRegistry {
    map: Mutex<HashMap<String, TransactionEntry>>,
}

struct TransactionEntry {
    handle: Arc<dyn TxHandle>,
    tenant_id: String,
    /// `pool_key` of the pool this tx's connection was checked out from. Used to
    /// pin that pool against eviction/reaping while the tx is open, and to
    /// unpin it on commit/rollback.
    pool_key: String,
    // Kept for diagnostics — `#[allow(dead_code)]` documents the intent.
    #[allow(dead_code)]
    mount_id: String,
    #[allow(dead_code)]
    opened_at: SystemTime,
    /// When the tx pin expires. The reaper (`reap_expired`) best-effort rolls
    /// back + unpins entries past this, and `get` refuses an expired entry, so a
    /// begun-but-never-finalised tx cannot pin its pool forever.
    expires_at: SystemTime,
}

impl TransactionRegistry {
    async fn register(
        &self,
        handle: Arc<dyn TxHandle>,
        tenant_id: String,
        mount_id: String,
        pool_key: String,
        ttl: Duration,
    ) -> String {
        let tx_id = handle.tx_id().to_string();
        let now = SystemTime::now();
        let mut map = self.map.lock().await;
        map.insert(
            tx_id.clone(),
            TransactionEntry {
                handle,
                tenant_id,
                pool_key,
                mount_id,
                opened_at: now,
                expires_at: now + ttl,
            },
        );
        tx_id
    }

    /// Look up a live tx. An entry past its `expires_at` is treated as absent
    /// (the reaper will roll it back + unpin its pool shortly): the contract is
    /// that the registry stops handing out an expired handle, so a stale tx_id
    /// surfaces a clean `transaction_not_found` rather than executing on a
    /// connection that's about to be reaped.
    async fn get(&self, tx_id: &str) -> Option<(Arc<dyn TxHandle>, String)> {
        let now = SystemTime::now();
        let map = self.map.lock().await;
        map.get(tx_id)
            .filter(|e| e.expires_at > now)
            .map(|e| (e.handle.clone(), e.tenant_id.clone()))
    }

    /// Remove the entry, returning both the handle and the `pool_key` so the
    /// caller can unpin the pool after finalising the tx.
    async fn take(&self, tx_id: &str) -> Option<(Arc<dyn TxHandle>, String)> {
        let mut map = self.map.lock().await;
        map.remove(tx_id).map(|e| (e.handle, e.pool_key))
    }

    /// Remove every entry past its `expires_at`, returning their (handle,
    /// pool_key) so the caller can best-effort roll back the handle and unpin its
    /// pool OUTSIDE the lock (both are async). A begun-but-never-committed tx
    /// otherwise pins its pool forever (never evictable / reapable). Idempotent;
    /// safe to call on a timer.
    async fn reap_expired(&self) -> Vec<(Arc<dyn TxHandle>, String)> {
        let now = SystemTime::now();
        let mut map = self.map.lock().await;
        let expired: Vec<String> = map
            .iter()
            .filter(|(_, e)| e.expires_at <= now)
            .map(|(id, _)| id.clone())
            .collect();
        expired
            .into_iter()
            .filter_map(|id| map.remove(&id))
            .map(|e| (e.handle, e.pool_key))
            .collect()
    }
}

#[derive(Clone)]
pub struct AppState {
    config: Arc<ServerConfig>,
    engines: Arc<Vec<EngineDescriptor>>,
    registry: Arc<DefaultPoolRegistry>,
    /// The DSN resolver, shared (same `Arc`) with every engine adapter so a
    /// rotation can evict its credential cache. Holding it here lets ONE handler
    /// (`/v1/admin/rotate`) perform BOTH halves of a rotation atomically: drain
    /// the registry pool AND evict the resolver's cached DSN. Without both, a
    /// stale cached DSN would survive a pool drain (gap G8 / S2).
    resolver: Arc<EnvMountResolver>,
    transactions: Arc<TransactionRegistry>,
    /// Optional in-Rust ABAC evaluator. Populated when
    /// `DATA_PLANE_PERMISSION_BUNDLE` env is a valid JSON bundle; otherwise
    /// `/v1/permissions/decide` returns 503 and callers fall back to the
    /// permission-engine HTTP path.
    evaluator: Option<Arc<Evaluator>>,
    /// Process-wide request/uptime counters exposed at `/metrics`.
    metrics: Arc<Metrics>,
}

impl AppState {
    #[must_use]
    pub fn new(config: ServerConfig) -> Self {
        let evaluator = build_evaluator(&config);
        // Strategy pattern: one Arc<dyn EngineAdapter> per engine, all behind
        // the same PoolRegistry trait. Adding a new engine (R7 MySQL, etc.)
        // is one line — no other call site changes.
        //
        // gap G8: build the resolver from ServerConfig (the single env-reader),
        // so credential providers + the DSN cache are configured from ONE source
        // and not a second `from_env` path. All provider knobs default empty →
        // providers DISABLED, so this is parity-equivalent to the old
        // `from_env()` until a token/addr is set.
        let mounts_json = std::env::var("DATA_PLANE_MOUNTS").unwrap_or_default();
        let provider_cfg = ProviderConfig {
            adapter_registry_url: config.adapter_registry_url.clone(),
            adapter_registry_token: config.adapter_registry_token.clone(),
            vault_addr: config.vault_addr.clone(),
            vault_token: config.vault_token.clone(),
            vault_dsn_prefix: config.vault_dsn_prefix.clone(),
            vault_dsn_field: config.vault_dsn_field.clone(),
        };
        let resolver = Arc::new(EnvMountResolver::from_config(
            &mounts_json,
            &provider_cfg,
            config.credential_cache_ttl_ms,
        ));
        let postgres: Arc<dyn EngineAdapter> =
            Arc::new(PostgresEngineAdapter::new(resolver.clone()));
        // CockroachDB rides the Postgres adapter (pgwire) under its own engine
        // id with a serializable-only descriptor, so a `cockroachdb` mount
        // routes here.
        let cockroach: Arc<dyn EngineAdapter> = Arc::new(PostgresEngineAdapter::with_dialect(
            resolver.clone(),
            PgDialect::Cockroach,
        ));
        let mongo: Arc<dyn EngineAdapter> =
            Arc::new(MongoEngineAdapter::new(resolver.clone()));
        let mysql: Arc<dyn EngineAdapter> =
            Arc::new(MysqlEngineAdapter::new(resolver.clone()));
        // MariaDB rides the MySQL adapter (same wire protocol + dispatch) under
        // its own engine id, so a `mariadb` mount routes here.
        let mariadb: Arc<dyn EngineAdapter> =
            Arc::new(MysqlEngineAdapter::with_engine_name(resolver.clone(), "mariadb"));
        let redis: Arc<dyn EngineAdapter> =
            Arc::new(RedisEngineAdapter::new(resolver.clone()));
        let http: Arc<dyn EngineAdapter> =
            Arc::new(HttpEngineAdapter::new(resolver.clone()));
        let adapters: Vec<Arc<dyn EngineAdapter>> =
            vec![postgres, cockroach, mongo, mysql, mariadb, redis, http];
        // Boot-time honesty self-check (04/S1b): fail fast if any descriptor
        // advertises an op the adapter doesn't dispatch.
        assert_capability_honesty(&adapters);
        let registry = Arc::new(DefaultPoolRegistry::with_max_pools(adapters, config.max_pools));
        Self {
            config: Arc::new(config),
            engines: Arc::new(default_engines()),
            registry,
            resolver,
            transactions: Arc::new(TransactionRegistry::default()),
            evaluator,
            metrics: Arc::new(Metrics::default()),
        }
    }

    /// Rotation entrypoint (gap G8 / S2). A credential rotation must invalidate
    /// BOTH cached views of the old credential or a stale DSN survives:
    ///   1. the resolver's DSN cache entry for `pool_key`, and
    ///   2. the pool the registry opened with that old DSN.
    /// We evict the cache FIRST so that even if the drain races a concurrent
    /// `get_or_create`, the rebuild cannot re-read the stale cached DSN. Returns
    /// the number of pools actually drained (0 if the key was unknown or the
    /// pool is pinned by an open tx — the idle reaper retires the latter once the
    /// tx finishes). `pool_key` embeds the credential version, so a newer
    /// version's pool is never touched. No secret is logged or returned.
    pub async fn rotate(&self, pool_key: &str) -> usize {
        self.resolver.evict_cached(pool_key);
        let before = self.registry.stats().await.map(|s| s.len()).unwrap_or(0);
        // drain_pool_key is a no-op for an unknown/pinned key; comparing the pool
        // count before/after tells the caller whether a pool was actually closed.
        let _ = self.registry.drain_pool_key(pool_key).await;
        let after = self.registry.stats().await.map(|s| s.len()).unwrap_or(0);
        before.saturating_sub(after)
    }

    /// The pool registry (shared `Arc`). Used by the background reaper in
    /// `server::run` to drive idle-pool draining + expired-tx unpinning.
    #[must_use]
    pub fn registry(&self) -> Arc<DefaultPoolRegistry> {
        self.registry.clone()
    }

    /// One reaper tick: drop idle pools past their `idle_ttl`, then roll back +
    /// unpin any transaction past its TTL (so an abandoned tx can't pin its pool
    /// forever). Best-effort; a single failing rollback never aborts the tick.
    /// Pinned pools are never reaped (the registry excludes `tx_pins > 0`), and
    /// reaping the tx unpins it FIRST, so this ordering converges: a future tick
    /// then sees the now-unpinned, idle pool and drains it.
    pub async fn reap_once(&self) {
        let _ = self.registry.release_idle().await;
        for (handle, pool_key) in self.transactions.reap_expired().await {
            // Best-effort rollback of the abandoned tx, then ALWAYS unpin its
            // pool (mirrors the commit/rollback route's guaranteed unpin).
            let _ = handle.rollback().await;
            self.registry.unpin_tx(&pool_key).await;
        }
    }
}

/// Boot-time capability self-check (04/S1b). Every adapter's advertised
/// descriptor must agree with the operations it actually dispatches
/// (`supported_ops`), so we fail fast at startup rather than serve a lying
/// `/v1/capabilities`. Both sides are compile-time constants, so a mismatch is a
/// programming error, never runtime-triggerable. The same invariant is gated in
/// CI by `make verify-m18` (the `capability_honesty` tests).
fn assert_capability_honesty(adapters: &[Arc<dyn EngineAdapter>]) {
    for adapter in adapters {
        let caps = adapter.capabilities();
        let ops = adapter.supported_ops();
        for kind in &data_plane_core::DataOperationKind::ALL {
            assert_eq!(
                caps.supports_op(kind),
                ops.contains(kind),
                "capability descriptor for engine '{}' lies about {:?}: supports_op={} but dispatch supported_ops={}",
                adapter.engine(),
                kind,
                caps.supports_op(kind),
                ops.contains(kind),
            );
        }
    }
}

fn build_evaluator(config: &ServerConfig) -> Option<Arc<Evaluator>> {
    let raw = config.permission_bundle_inline.trim();
    if raw.is_empty() {
        return None;
    }
    let bundle: PolicyBundle = match serde_json::from_str(raw) {
        Ok(b) => b,
        Err(e) => {
            tracing::warn!(
                "DATA_PLANE_PERMISSION_BUNDLE is not valid PolicyBundle JSON ({}); local evaluator disabled",
                e
            );
            return None;
        }
    };
    let mode = PermissionMode::from_env_string(&config.permission_mode);
    Some(Arc::new(Evaluator::new(bundle, mode)))
}

pub fn router(state: AppState) -> Router {
    let metrics_state = state.clone();
    Router::new()
        .route("/v1/health", get(health))
        .route("/metrics", get(metrics_handler))
        .route("/v1/capabilities", get(capabilities))
        .route("/v1/query", post(execute_query))
        .route("/v1/schema", post(describe_schema))
        .route("/v1/schema/ddl", post(apply_schema_ddl))
        .route("/v1/transactions", post(begin_transaction))
        .route("/v1/transactions/:tx_id/execute", post(execute_in_transaction))
        .route("/v1/transactions/:tx_id/commit", post(commit_transaction))
        .route("/v1/transactions/:tx_id/rollback", post(rollback_transaction))
        .route("/v1/admin/raw", post(execute_raw_admin))
        .route("/v1/admin/migrate", post(apply_migration_admin))
        .route("/v1/admin/rotate", post(rotate_credential_admin))
        .route("/v1/permissions/decide", post(decide_permission))
        .fallback(not_found)
        .layer(axum::middleware::from_fn_with_state(metrics_state, track_metrics))
        .layer(TraceLayer::new_for_http())
        .layer(CorsLayer::permissive())
        .with_state(state)
}

/// Counts every finished request by status class, except the scrape/probe
/// paths so the counters reflect real API traffic.
async fn track_metrics(State(state): State<AppState>, req: Request, next: Next) -> Response {
    let path = req.uri().path().to_string();
    let method = req.method().clone();
    // Capture the inbound W3C trace context + correlation id so data-plane logs
    // join the same distributed trace as the TS query-router and Go control
    // plane (wiki/05 §2 — cross-tier observability).
    let traceparent = header_str(&req, "traceparent");
    let request_id = header_str(&req, "x-request-id");
    let resp = next.run(req).await;
    if path != "/metrics" && path != "/v1/health" {
        let status = resp.status().as_u16();
        state.metrics.record(status);
        tracing::info!(
            %method,
            path = %path,
            status,
            traceparent = %traceparent,
            request_id = %request_id,
            "data-plane request"
        );
    }
    resp
}

fn header_str(req: &Request, name: &str) -> String {
    req.headers()
        .get(name)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string()
}

/// Prometheus exposition: service_up + uptime + request counts + per-mount pool
/// saturation (from the live `PoolRegistry::stats()`). Dependency-free, same
/// `baas_*` shape as the Go control plane.
async fn metrics_handler(State(state): State<AppState>) -> Response {
    let (_, c2, c4, c5) = state.metrics.snapshot();
    let mut out = String::new();
    out.push_str("# HELP baas_service_up 1 while the service is serving\n");
    out.push_str("# TYPE baas_service_up gauge\n");
    out.push_str("baas_service_up{service=\"data-plane-router\"} 1\n");
    out.push_str("# HELP baas_uptime_seconds Seconds since process start\n");
    out.push_str("# TYPE baas_uptime_seconds gauge\n");
    out.push_str(&format!(
        "baas_uptime_seconds{{service=\"data-plane-router\"}} {}\n",
        state.metrics.uptime_secs()
    ));
    out.push_str("# HELP baas_http_requests_total HTTP requests by status class\n");
    out.push_str("# TYPE baas_http_requests_total counter\n");
    for (class, n) in [("2xx", c2), ("4xx", c4), ("5xx", c5)] {
        out.push_str(&format!(
            "baas_http_requests_total{{service=\"data-plane-router\",status=\"{class}\"}} {n}\n"
        ));
    }
    out.push_str("# HELP baas_data_plane_pool_connections Pool connections per mount and state\n");
    out.push_str("# TYPE baas_data_plane_pool_connections gauge\n");
    if let Ok(stats) = state.registry.stats().await {
        for s in stats {
            let mount = escape_label(&s.mount_id);
            let engine = escape_label(&s.engine);
            for (st, v) in [
                ("active", s.active_connections),
                ("idle", s.idle_connections),
                ("waiting", s.waiting_requests),
            ] {
                out.push_str(&format!(
                    "baas_data_plane_pool_connections{{service=\"data-plane-router\",mount=\"{mount}\",engine=\"{engine}\",state=\"{st}\"}} {v}\n"
                ));
            }
        }
    }
    Response::builder()
        .header(header::CONTENT_TYPE, "text/plain; version=0.0.4; charset=utf-8")
        .body(Body::from(out))
        .expect("static metrics response is always valid")
}

#[derive(Debug, Clone, Serialize)]
struct HealthResponse {
    status: &'static str,
    service: &'static str,
    version: &'static str,
    product_mode: String,
}

async fn health(State(state): State<AppState>) -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok",
        service: "data-plane-router",
        version: env!("CARGO_PKG_VERSION"),
        product_mode: state.config.product_mode.clone(),
    })
}

#[derive(Debug, Clone, Serialize)]
struct CapabilitiesResponse {
    router: RouterDescriptor,
    engines: Vec<EngineDescriptor>,
}

#[derive(Debug, Clone, Serialize)]
struct RouterDescriptor {
    language: &'static str,
    mode: String,
    query_execution: &'static str,
    transaction_sessions: &'static str,
    local_pdp: &'static str,
}

#[derive(Debug, Clone, Serialize)]
struct EngineDescriptor {
    engine: String,
    phase: String,
    capabilities: EngineCapabilities,
}

async fn capabilities(State(state): State<AppState>) -> Json<CapabilitiesResponse> {
    Json(CapabilitiesResponse {
        router: RouterDescriptor {
            language: "rust",
            mode: state.config.product_mode.clone(),
            query_execution: "postgresql_pool+mongodb_pool+mysql_pool+redis_pool+http_pool",
            transaction_sessions: "contract_only",
            local_pdp: "planned",
        },
        engines: state.engines.as_ref().clone(),
    })
}

#[derive(Debug, Clone, Deserialize)]
struct QueryRequest {
    identity: RequestIdentity,
    mount: DatabaseMount,
    operation: DataOperation,
}

async fn execute_query(
    State(state): State<AppState>,
    Json(request): Json<QueryRequest>,
) -> impl IntoResponse {
    if let Err(message) = validate_identity_mount(&state, &request.identity, &request.mount) {
        return bad_request(message);
    }
    if request.operation.resource.trim().is_empty() {
        return bad_request("operation.resource is required".to_string());
    }

    // Engines with a live Rust pool. MariaDB rides the MySQL adapter. Engines
    // beyond this list (jdbc, cassandra, neo4j, es, qdrant, influx) stay
    // contract-only and are rejected here.
    let executable_engines = [
        "postgresql", "cockroachdb", "mongodb", "mysql", "mariadb", "redis", "http",
    ];
    if !executable_engines.contains(&request.mount.engine.as_str()) {
        return not_implemented(
            "engine_execution_not_enabled",
            "engine has no Rust pool; supported engines: postgresql, cockroachdb, mysql, mariadb, mongodb, redis, http",
        );
    }

    // Capability-aware planner (G6, two-phase). Phase 1 rejects an impossible
    // (engine, op) pair (supports_op + batch ceiling); Phase 2 routes by op
    // shape over the const cost table. No-op for the engines mounted today —
    // plain CRUD has an empty shape, so every current request stays Native
    // (parity-safe). `/v1/query` is never inside a tx or streaming, so the
    // workload context is plain; the tx route guards transactions separately.
    if let Some(descriptor) = state
        .engines
        .iter()
        .find(|e| e.engine == request.mount.engine)
    {
        let decision = data_plane_core::plan(
            &request.operation,
            &request.mount.engine,
            &descriptor.capabilities,
            &WorkloadContext::default(),
            state.config.planner_federation_enabled,
        );
        match decision.plan {
            Plan::Native => {} // fall through to pool execution (unchanged)
            Plan::Reject(err) => {
                tracing::info!(reason = decision.reason, engine = %request.mount.engine, "planner rejected operation");
                return map_data_plane_error(&err);
            }
            Plan::Federate { target } => {
                // The federation seam (resolve_federation) lowers Federate to a
                // Reject while the flag is off, so this arm is reachable only
                // once federation is wired. Until then it is a clean 501.
                tracing::info!(reason = decision.reason, target, "planner selected federation target (not yet executable)");
                return map_data_plane_error(&data_plane_core::DataPlaneError::NotImplemented {
                    feature: format!("federation to {target}"),
                });
            }
        }
    }

    let pool = match state.registry.get_or_create(request.mount).await {
        Ok(pool) => pool,
        Err(err) => return map_data_plane_error(&err),
    };
    match pool.execute(request.operation, request.identity).await {
        Ok(result) => (StatusCode::OK, Json(result)).into_response(),
        Err(err) => map_data_plane_error(&err),
    }
}

/// Reject a request whose engine advertises a required capability as `false`
/// with a clean 422 `UnsupportedCapability` (G6: a semantic, not syntactic,
/// rejection), instead of letting it die as a deep 501 inside the adapter (e.g.
/// `begin()` on mongo, `migrate` on a `ddl:false` engine). Uses the trusted
/// server-side descriptor, never request input. A no-op when the engine isn't in
/// the descriptor table (the adapter still guards).
fn require_capability(
    state: &AppState,
    engine: &str,
    capability: &str,
    has: impl Fn(&EngineCapabilities) -> bool,
) -> Result<(), axum::response::Response> {
    if let Some(descriptor) = state.engines.iter().find(|e| e.engine == engine) {
        if !has(&descriptor.capabilities) {
            return Err(map_data_plane_error(
                &DataPlaneError::UnsupportedCapability {
                    engine: engine.to_string(),
                    capability: capability.to_string(),
                },
            ));
        }
    }
    Ok(())
}

fn map_data_plane_error(err: &DataPlaneError) -> axum::response::Response {
    let (status, code) = match err {
        DataPlaneError::NotImplemented { .. } => (StatusCode::NOT_IMPLEMENTED, "not_implemented"),
        // G6: an (engine, op) the engine cannot serve is a *semantically*
        // invalid request — the body is well-formed but the capability is
        // unavailable — so 422 Unprocessable Entity, distinct from a malformed
        // request (400). Only this variant flips; InvalidRequest/Identifier
        // stay 400.
        DataPlaneError::UnsupportedCapability { .. } => {
            (StatusCode::UNPROCESSABLE_ENTITY, "unsupported_capability")
        }
        DataPlaneError::InvalidIdentifier { .. } => (StatusCode::BAD_REQUEST, "invalid_identifier"),
        DataPlaneError::InvalidRequest { .. } => (StatusCode::BAD_REQUEST, "invalid_request"),
        DataPlaneError::MountNotFound { .. } => (StatusCode::NOT_FOUND, "mount_not_found"),
        DataPlaneError::TransactionNotFound { .. } => (StatusCode::NOT_FOUND, "transaction_not_found"),
        DataPlaneError::CredentialUnavailable { .. } => {
            (StatusCode::BAD_GATEWAY, "credential_unavailable")
        }
        // A configured provider was reached but failed (transport/non-2xx/missing
        // field). Mirror CredentialUnavailable's status (502) — an upstream
        // credential source we depend on did not deliver, so it is a gateway
        // failure, not a client (422) error.
        DataPlaneError::CredentialProviderFailed { .. } => {
            (StatusCode::BAD_GATEWAY, "credential_provider_failed")
        }
        DataPlaneError::Backend { .. } => (StatusCode::BAD_GATEWAY, "backend_error"),
        DataPlaneError::Conflict { .. } => (StatusCode::CONFLICT, "conflict"),
    };
    (
        status,
        Json(ApiError {
            error: code.to_string(),
            message: err.to_string(),
        }),
    )
        .into_response()
}

// ── /v1/schema ───────────────────────────────────────────────────────────────
//
// Engine-agnostic schema introspection (M22, live-database mode). Returns the
// mount's tables/collections with normalized column types, PK/FK metadata and
// enum values (`SchemaDescriptor` in data-plane-core). NOT admin-gated: any
// authenticated identity that passes `validate_identity_mount` may read its
// OWN mount's schema (same gating as `begin_transaction` — identity/mount
// validation + a capability gate, nothing more). Engines without an
// introspection surface (redis, http) advertise `introspect: false` and are
// rejected here with a clean 422 instead of a deep 501.

#[derive(Debug, Clone, Deserialize)]
struct DescribeSchemaRequest {
    identity: RequestIdentity,
    mount: DatabaseMount,
}

async fn describe_schema(
    State(state): State<AppState>,
    Json(request): Json<DescribeSchemaRequest>,
) -> impl IntoResponse {
    if let Err(message) = validate_identity_mount(&state, &request.identity, &request.mount) {
        return bad_request(message);
    }
    // Honesty gate: only engines advertising `introspect` serve the schema
    // surface (a route capability like `ddl`, not an operation kind).
    if let Err(resp) =
        require_capability(&state, &request.mount.engine, "introspect", |c| c.introspect)
    {
        return resp;
    }
    let pool = match state.registry.get_or_create(request.mount).await {
        Ok(pool) => pool,
        Err(err) => return map_data_plane_error(&err),
    };
    match pool.describe_schema(request.identity).await {
        Ok(result) => (StatusCode::OK, Json(result)).into_response(),
        Err(err) => map_data_plane_error(&err),
    }
}

// ── /v1/schema/ddl ────────────────────────────────────────────────────────────
//
// Engine-agnostic schema DDL (M22, step 2): ONE operation per request
// (add_column | drop_column | alter_column_type | create_table | drop_table)
// — single-op by contract because MySQL DDL self-commits, so a batch would
// fake atomicity. NOT admin-gated (mirrors /v1/schema): mount ownership is
// enforced upstream by the query-router's resolveConnection, the same trust
// model as /v1/query writes. Gated on the `schema_ddl` capability flag —
// deliberately distinct from `ddl` (the /v1/admin/migrate gate), because
// mongodb serves this surface but not migrations.

#[derive(Debug, Clone, Deserialize)]
struct SchemaDdlEnvelope {
    identity: RequestIdentity,
    mount: DatabaseMount,
    ddl: SchemaDdlRequest,
}

async fn apply_schema_ddl(
    State(state): State<AppState>,
    Json(request): Json<SchemaDdlEnvelope>,
) -> impl IntoResponse {
    if let Err(message) = validate_identity_mount(&state, &request.identity, &request.mount) {
        return bad_request(message);
    }
    if request.ddl.table.trim().is_empty() {
        return bad_request("ddl.table is required".to_string());
    }
    // Honesty gate: only engines advertising `schema_ddl` serve this surface.
    if let Err(resp) =
        require_capability(&state, &request.mount.engine, "schema_ddl", |c| c.schema_ddl)
    {
        return resp;
    }
    let pool = match state.registry.get_or_create(request.mount).await {
        Ok(pool) => pool,
        Err(err) => return map_data_plane_error(&err),
    };
    match pool.apply_schema_ddl(request.ddl, request.identity).await {
        Ok(result) => (StatusCode::OK, Json(result)).into_response(),
        Err(err) => map_data_plane_error(&err),
    }
}

// Default transaction TTL — after this the registry stops handing out the
// handle on lookup. The connection is NOT force-closed here; a follow-up
// slice can add a reaper task that calls rollback on expired entries.
const DEFAULT_TX_TTL_SECS: u64 = 30;

#[derive(Debug, Clone, Serialize)]
struct TxBeginResponse {
    tx_id: String,
    mount_id: String,
    expires_in_ms: u64,
}

async fn begin_transaction(
    State(state): State<AppState>,
    Json(request): Json<TxBeginRequest>,
) -> impl IntoResponse {
    if let Err(message) = validate_identity_mount(&state, &request.identity, &request.mount) {
        return bad_request(message);
    }
    // Honesty gate: an engine whose `begin()` is NotImplemented (mongo/redis/
    // http) advertises `transactions:false` — reject here with 400 rather than
    // 501 from deep in the adapter.
    if let Err(resp) =
        require_capability(&state, &request.mount.engine, "transactions", |c| c.transactions)
    {
        return resp;
    }

    // Capture identity/mount info BEFORE moving `request` into pool.begin.
    let tenant_id = request.identity.tenant_id.clone();
    let mount = request.mount.clone();
    // `pool_key` identifies the pool the tx's connection comes from, so we can
    // pin it against eviction/reaping for the life of the transaction.
    let pool_key = mount.pool_key();

    let pool = match state.registry.get_or_create(mount).await {
        Ok(pool) => pool,
        Err(err) => return map_data_plane_error(&err),
    };
    let handle = match pool.begin(request).await {
        Ok(handle) => handle,
        Err(err) => return map_data_plane_error(&err),
    };
    // Pin the pool now that a tx holds one of its connections: the registry
    // must not close it (eviction / idle reap) until commit/rollback unpins.
    state.registry.pin_tx(&pool_key).await;

    let ttl = Duration::from_secs(DEFAULT_TX_TTL_SECS);
    let mount_id = handle.mount_id().to_string();
    let handle_arc: Arc<dyn TxHandle> = Arc::from(handle);
    let tx_id = state
        .transactions
        .register(handle_arc, tenant_id, mount_id.clone(), pool_key, ttl)
        .await;

    (
        StatusCode::CREATED,
        Json(TxBeginResponse {
            tx_id,
            mount_id,
            expires_in_ms: ttl.as_millis() as u64,
        }),
    )
        .into_response()
}

#[derive(Debug, Clone, Deserialize)]
struct TxExecuteRequest {
    identity: RequestIdentity,
    operation: DataOperation,
}

async fn execute_in_transaction(
    State(state): State<AppState>,
    Path(tx_id): Path<String>,
    Json(request): Json<TxExecuteRequest>,
) -> impl IntoResponse {
    if !request.identity.is_tenant_scoped() {
        return bad_request("identity.tenant_id is required".to_string());
    }
    let (handle, tx_tenant) = match state.transactions.get(&tx_id).await {
        Some(entry) => entry,
        None => {
            return (
                StatusCode::NOT_FOUND,
                Json(ApiError {
                    error: "transaction_not_found".to_string(),
                    message: format!("no open transaction with id {tx_id}"),
                }),
            )
                .into_response();
        }
    };
    // Cross-tenant guard: a tenant cannot resume another tenant's tx by
    // guessing the tx_id. Identity-tenant must match the tenant that opened
    // the transaction.
    if request.identity.tenant_id != tx_tenant {
        return bad_request(
            "identity tenant does not match the tenant that opened this transaction".to_string(),
        );
    }
    if request.operation.resource.trim().is_empty() {
        return bad_request("operation.resource is required".to_string());
    }

    match handle.execute(request.operation, request.identity).await {
        Ok(result) => (StatusCode::OK, Json(result)).into_response(),
        Err(err) => map_data_plane_error(&err),
    }
}

async fn commit_transaction(
    State(state): State<AppState>,
    Path(tx_id): Path<String>,
) -> impl IntoResponse {
    let (handle, pool_key) = match state.transactions.take(&tx_id).await {
        Some(entry) => entry,
        None => {
            return (
                StatusCode::NOT_FOUND,
                Json(ApiError {
                    error: "transaction_not_found".to_string(),
                    message: format!("no open transaction with id {tx_id}"),
                }),
            )
                .into_response();
        }
    };
    let result = handle.commit().await;
    // The tx no longer holds the pool's connection — release the pin so the
    // registry may evict/reap it again. Always unpin, even on commit error.
    state.registry.unpin_tx(&pool_key).await;
    match result {
        Ok(()) => (StatusCode::OK, Json(TxFinalize { tx_id, state: "committed" })).into_response(),
        Err(err) => map_data_plane_error(&err),
    }
}

async fn rollback_transaction(
    State(state): State<AppState>,
    Path(tx_id): Path<String>,
) -> impl IntoResponse {
    let (handle, pool_key) = match state.transactions.take(&tx_id).await {
        Some(entry) => entry,
        None => {
            return (
                StatusCode::NOT_FOUND,
                Json(ApiError {
                    error: "transaction_not_found".to_string(),
                    message: format!("no open transaction with id {tx_id}"),
                }),
            )
                .into_response();
        }
    };
    let result = handle.rollback().await;
    state.registry.unpin_tx(&pool_key).await;
    match result {
        Ok(()) => (StatusCode::OK, Json(TxFinalize { tx_id, state: "rolled_back" })).into_response(),
        Err(err) => map_data_plane_error(&err),
    }
}

#[derive(Debug, Clone, Serialize)]
struct TxFinalize {
    tx_id: String,
    state: &'static str,
}

// ── /v1/admin/raw ───────────────────────────────────────────────────────────
//
// Power-user endpoint: arbitrary engine-native statement (DDL, ALTER,
// indexes, raw SELECT for aggregations). The route enforces that the caller
// has the `service_role` role or the `admin` scope; engines TRUST the gate
// and execute the statement verbatim against the mount's connection.
//
// The endpoint exists so that "full DB control" stops being aspirational —
// the audit flagged it as a real product gap. Engines that don't support a
// raw surface return NotImplemented from the trait default.

#[derive(Debug, Clone, Deserialize)]
struct AdminRawRequest {
    identity: RequestIdentity,
    mount: DatabaseMount,
    #[serde(flatten)]
    statement: RawStatement,
}

async fn execute_raw_admin(
    State(state): State<AppState>,
    Json(request): Json<AdminRawRequest>,
) -> impl IntoResponse {
    if let Err(message) = validate_identity_mount(&state, &request.identity, &request.mount) {
        return bad_request(message);
    }
    if !is_admin(&request.identity) {
        return (
            StatusCode::FORBIDDEN,
            Json(ApiError {
                error: "forbidden".to_string(),
                message: "/v1/admin/raw requires role=service_role or scope=admin".to_string(),
            }),
        )
            .into_response();
    }
    if request.statement.statement.trim().is_empty() {
        return bad_request("statement is required".to_string());
    }

    let pool = match state.registry.get_or_create(request.mount).await {
        Ok(pool) => pool,
        Err(err) => return map_data_plane_error(&err),
    };
    match pool.execute_raw(request.statement, request.identity).await {
        Ok(result) => (StatusCode::OK, Json(result)).into_response(),
        Err(err) => map_data_plane_error(&err),
    }
}

fn is_admin(identity: &RequestIdentity) -> bool {
    identity.roles.iter().any(|r| r == "service_role" || r == "admin")
        || identity.scopes.iter().any(|s| s == "admin")
}

// ── /v1/permissions/decide ──────────────────────────────────────────────────
//
// In-Rust ABAC/RBAC decision endpoint. Mirrors the NestJS
// `DecisionsService.decide()` shape so the query-router can swap targets
// without changing its request envelope. When the local evaluator isn't
// configured (no DATA_PLANE_PERMISSION_BUNDLE env) the endpoint returns 503
// and the caller falls back to the permission-engine HTTP path.

#[derive(Debug, Clone, Deserialize)]
struct DecisionUser {
    id: String,
}

#[derive(Debug, Clone, Deserialize)]
struct DecideRequest {
    user: DecisionUser,
    resource_type: String,
    resource_name: String,
    op: String,
    #[serde(default)]
    tenant_id: Option<String>,
    #[serde(default)]
    project_id: Option<String>,
    #[serde(default)]
    app_id: Option<String>,
}

async fn decide_permission(
    State(state): State<AppState>,
    Json(request): Json<DecideRequest>,
) -> impl IntoResponse {
    // tenant/project/app are accepted for future scoping; today's evaluator
    // doesn't use them (the SQL function didn't either). Drop on the floor
    // until the bundle format adds tenant-scoped policies.
    let _ = (request.tenant_id, request.project_id, request.app_id);
    let Some(evaluator) = state.evaluator.as_ref() else {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ApiError {
                error: "evaluator_not_configured".to_string(),
                message: "DATA_PLANE_PERMISSION_BUNDLE is not set; fall back to permission-engine HTTP".to_string(),
            }),
        )
            .into_response();
    };
    let action = action_for_op(&request.op);
    let decision: Decision = evaluator.decide(
        &request.user.id,
        &request.resource_type,
        &request.resource_name,
        &action,
    );
    (StatusCode::OK, Json(decision)).into_response()
}

fn action_for_op(op: &str) -> String {
    match op {
        "list" | "get" => "select".to_string(),
        "upsert" => "update".to_string(),
        other => other.to_string(),
    }
}

// ── /v1/admin/migrate ───────────────────────────────────────────────────────
//
// Apply a named migration to a tenant database as an atomic batch. The
// engine wraps every statement in a single transaction, then writes a
// marker into `_baas_migrations(name, applied_at)` so re-applying the same
// name is a no-op. Used by control-plane tools to evolve schema-per-tenant
// without bespoke per-engine wiring.
//
// Admin-gated: same `service_role` / `admin` scope rule as /v1/admin/raw.

#[derive(Debug, Clone, Deserialize)]
struct AdminMigrateRequest {
    identity: RequestIdentity,
    mount: DatabaseMount,
    #[serde(flatten)]
    migration: MigrationRequest,
}

async fn apply_migration_admin(
    State(state): State<AppState>,
    Json(request): Json<AdminMigrateRequest>,
) -> impl IntoResponse {
    if let Err(message) = validate_identity_mount(&state, &request.identity, &request.mount) {
        return bad_request(message);
    }
    if !is_admin(&request.identity) {
        return (
            StatusCode::FORBIDDEN,
            Json(ApiError {
                error: "forbidden".to_string(),
                message: "/v1/admin/migrate requires role=service_role or scope=admin".to_string(),
            }),
        )
            .into_response();
    }
    if request.migration.name.trim().is_empty() {
        return bad_request("migration.name is required".to_string());
    }
    if request.migration.statements.is_empty() {
        return bad_request("migration.statements must not be empty".to_string());
    }
    // Honesty gate: only engines advertising `ddl` can apply migrations.
    if let Err(resp) = require_capability(&state, &request.mount.engine, "ddl", |c| c.ddl) {
        return resp;
    }

    let pool = match state.registry.get_or_create(request.mount).await {
        Ok(pool) => pool,
        Err(err) => return map_data_plane_error(&err),
    };
    match pool.apply_migration(request.migration, request.identity).await {
        Ok(result) => (StatusCode::OK, Json(result)).into_response(),
        Err(err) => map_data_plane_error(&err),
    }
}

// ── /v1/admin/rotate ─────────────────────────────────────────────────────────
//
// Credential-rotation trigger (gap G8 / S2). After a control-plane rotation
// bumps a mount's credential version (or re-issues its secret), this endpoint
// proactively invalidates the OLD credential's cached state so the next request
// rebuilds the pool with the freshly-resolved DSN instead of serving a stale
// one. It performs BOTH halves of a rotation — evict the resolver's DSN cache
// entry AND drain the registry pool — via `AppState::rotate`.
//
// The request carries the full `DatabaseMount` (same shape as /v1/admin/migrate)
// so the pool_key is reconstructed by the SAME `DatabaseMount::pool_key()` the
// hot path uses — no second key format to drift. Callers that already know the
// new version pass the OLD version in `credential_ref.version` to target the
// stale pool (the new version's pool keys distinctly and is left untouched).
//
// Admin-gated: identical `service_role` / `admin` rule + tenant match as
// /v1/admin/migrate (validate_identity_mount + is_admin). No secret is ever read,
// logged, or returned — only a drained-pool count.

#[derive(Debug, Clone, Deserialize)]
struct AdminRotateRequest {
    identity: RequestIdentity,
    mount: DatabaseMount,
}

#[derive(Debug, Clone, Serialize)]
struct AdminRotateResponse {
    pool_key: String,
    pools_drained: usize,
}

async fn rotate_credential_admin(
    State(state): State<AppState>,
    Json(request): Json<AdminRotateRequest>,
) -> impl IntoResponse {
    if let Err(message) = validate_identity_mount(&state, &request.identity, &request.mount) {
        return bad_request(message);
    }
    if !is_admin(&request.identity) {
        return (
            StatusCode::FORBIDDEN,
            Json(ApiError {
                error: "forbidden".to_string(),
                message: "/v1/admin/rotate requires role=service_role or scope=admin".to_string(),
            }),
        )
            .into_response();
    }
    // Reconstruct the pool_key with the same formatter the hot path uses, so the
    // drained key is byte-identical to the one `get_or_create` cached under.
    let pool_key = request.mount.pool_key();
    let pools_drained = state.rotate(&pool_key).await;
    (
        StatusCode::OK,
        Json(AdminRotateResponse { pool_key, pools_drained }),
    )
        .into_response()
}

async fn not_found() -> impl IntoResponse {
    (
        StatusCode::NOT_FOUND,
        Json(ApiError {
            error: "not_found".to_string(),
            message: "route is not exposed by the Rust data-plane-router".to_string(),
        }),
    )
}

fn validate_identity_mount(
    state: &AppState,
    identity: &RequestIdentity,
    mount: &DatabaseMount,
) -> Result<(), String> {
    if !identity.is_tenant_scoped() {
        return Err("identity.tenant_id is required".to_string());
    }
    if identity.tenant_id != mount.tenant_id {
        return Err("identity tenant does not match mount tenant".to_string());
    }
    if !state.engines.iter().any(|engine| engine.engine == mount.engine) {
        return Err(format!("engine '{}' is not mounted in the Rust router", mount.engine));
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize)]
struct ApiError {
    error: String,
    message: String,
}

#[derive(Debug, Clone, Serialize)]
struct NotImplementedResponse {
    error: String,
    message: String,
    next_step: &'static str,
    tx_id: Option<String>,
}

fn bad_request(message: String) -> axum::response::Response {
    (
        StatusCode::BAD_REQUEST,
        Json(ApiError {
            error: "invalid_request".to_string(),
            message,
        }),
    )
        .into_response()
}

fn not_implemented(error: &str, message: &str) -> axum::response::Response {
    (
        StatusCode::NOT_IMPLEMENTED,
        Json(NotImplementedResponse {
            error: error.to_string(),
            message: message.to_string(),
            next_step: "implement PoolRegistry, Postgres/Mongo pools, local PDP, then enable shadow routing",
            tx_id: None,
        }),
    )
        .into_response()
}

fn default_engines() -> Vec<EngineDescriptor> {
    vec![
        EngineDescriptor {
            engine: "postgresql".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::postgresql(),
        },
        EngineDescriptor {
            engine: "cockroachdb".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::cockroachdb(),
        },
        EngineDescriptor {
            engine: "mongodb".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::mongodb(),
        },
        EngineDescriptor {
            engine: "mysql".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::mysql(),
        },
        EngineDescriptor {
            engine: "mariadb".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::mariadb(),
        },
        EngineDescriptor {
            engine: "redis".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::redis(),
        },
        EngineDescriptor {
            engine: "http".to_string(),
            phase: "pool_v2_active".to_string(),
            capabilities: EngineCapabilities::http(),
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use data_plane_core::{DataOperation, DataResult};
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn status_of(err: DataPlaneError) -> StatusCode {
        map_data_plane_error(&err).status()
    }

    /// Minimal `TxHandle` that records how many times `rollback()` fired, so the
    /// reaper test can prove an expired tx is rolled back (not just dropped).
    struct CountingTxHandle {
        tx_id: String,
        mount_id: String,
        rolled_back: Arc<AtomicUsize>,
    }

    #[async_trait::async_trait]
    impl TxHandle for CountingTxHandle {
        fn tx_id(&self) -> &str {
            &self.tx_id
        }
        fn mount_id(&self) -> &str {
            &self.mount_id
        }
        async fn execute(
            &self,
            _op: DataOperation,
            _id: RequestIdentity,
        ) -> Result<DataResult, DataPlaneError> {
            Ok(DataResult { rows: vec![], affected_rows: 0, next_cursor: None, batch: None })
        }
        async fn commit(&self) -> Result<(), DataPlaneError> {
            Ok(())
        }
        async fn rollback(&self) -> Result<(), DataPlaneError> {
            self.rolled_back.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }
        async fn prepare(&self) -> Result<(), DataPlaneError> {
            Ok(())
        }
    }

    fn counting_handle(tx_id: &str, rolled_back: Arc<AtomicUsize>) -> Arc<dyn TxHandle> {
        Arc::new(CountingTxHandle {
            tx_id: tx_id.to_string(),
            mount_id: "db1".to_string(),
            rolled_back,
        })
    }

    #[tokio::test]
    async fn reap_expired_rolls_back_and_yields_pool_key() {
        // An abandoned (begun-but-never-finalised) tx past its TTL must be reaped:
        // removed from the registry, rolled back, and its pool_key surfaced so the
        // caller can unpin the pool (otherwise the pin leaks forever).
        let reg = TransactionRegistry::default();
        let rolled_back = Arc::new(AtomicUsize::new(0));
        // Register with a zero TTL → already expired.
        let tx_id = reg
            .register(
                counting_handle("tx-expired", rolled_back.clone()),
                "t-1".into(),
                "db1".into(),
                "pool-key-1".into(),
                Duration::from_secs(0),
            )
            .await;

        // `get` must already refuse it (contract: stop handing out an expired tx).
        assert!(reg.get(&tx_id).await.is_none(), "expired tx is not handed out by get");

        let reaped = reg.reap_expired().await;
        assert_eq!(reaped.len(), 1, "the one expired tx is reaped");
        let (handle, pool_key) = &reaped[0];
        assert_eq!(pool_key, "pool-key-1", "pool_key surfaced for unpin");
        let _ = handle.rollback().await; // simulate AppState::reap_once
        assert_eq!(rolled_back.load(Ordering::SeqCst), 1, "expired tx rolled back");

        // Idempotent: a second pass finds nothing (entry already removed).
        assert!(reg.reap_expired().await.is_empty(), "reap is idempotent");
    }

    #[tokio::test]
    async fn reap_expired_keeps_live_transactions() {
        let reg = TransactionRegistry::default();
        let rolled_back = Arc::new(AtomicUsize::new(0));
        let tx_id = reg
            .register(
                counting_handle("tx-live", rolled_back.clone()),
                "t-1".into(),
                "db1".into(),
                "pool-key-1".into(),
                Duration::from_secs(3600), // far in the future
            )
            .await;
        assert!(reg.reap_expired().await.is_empty(), "live tx not reaped");
        assert!(reg.get(&tx_id).await.is_some(), "live tx still served by get");
        assert_eq!(rolled_back.load(Ordering::SeqCst), 0, "live tx not rolled back");
    }

    #[test]
    fn error_variants_map_to_expected_http_status() {
        // Request-shape mistakes are client errors (400), distinct from a
        // backend/transport failure (502). This is the contract the Postgres
        // and the other adapters now rely on.
        assert_eq!(
            status_of(DataPlaneError::InvalidRequest { message: "bad shape".into() }),
            StatusCode::BAD_REQUEST,
        );
        assert_eq!(
            status_of(DataPlaneError::InvalidIdentifier { value: "x;--".into() }),
            StatusCode::BAD_REQUEST,
        );
        // G6: an unavailable capability is a semantic (not syntactic) rejection
        // → 422, distinct from a malformed request (400) above.
        assert_eq!(
            status_of(DataPlaneError::UnsupportedCapability {
                engine: "redis".into(),
                capability: "stream".into(),
            }),
            StatusCode::UNPROCESSABLE_ENTITY,
        );
        assert_eq!(
            status_of(DataPlaneError::Backend { message: "engine down".into() }),
            StatusCode::BAD_GATEWAY,
        );
        assert_eq!(
            status_of(DataPlaneError::NotImplemented { feature: "agg".into() }),
            StatusCode::NOT_IMPLEMENTED,
        );
        // An integrity-constraint violation is the caller's fault (409), not a
        // backend failure (502).
        assert_eq!(
            status_of(DataPlaneError::Conflict { message: "duplicate key".into() }),
            StatusCode::CONFLICT,
        );
        // gap G8: an unresolvable credential and a failed provider are both
        // upstream/gateway failures (502), distinct from a 422 client error.
        assert_eq!(
            status_of(DataPlaneError::CredentialUnavailable { mount_id: "m1".into() }),
            StatusCode::BAD_GATEWAY,
        );
        assert_eq!(
            status_of(DataPlaneError::CredentialProviderFailed {
                provider: "vault".into(),
                mount_id: "m1".into(),
            }),
            StatusCode::BAD_GATEWAY,
        );
    }

    // S2 — the rotation entrypoint composes BOTH halves (resolver cache evict +
    // registry pool drain) and is safe on an empty state: an unknown key drains
    // zero pools and never panics. The deep behaviour of each half is proven in
    // the pool crate (resolver `s2_evict_cached_*` + registry `t9`/`t10`); this
    // test locks that `AppState::rotate` actually invokes both without error,
    // using a freshly-built state (no pools created → 0 drained).
    #[tokio::test]
    async fn s2_rotate_entrypoint_drains_and_evicts_safely() {
        // Build with the cache armed so the evict half exercises its real path
        // (ttl > 0) rather than the disabled no-op.
        std::env::set_var("DATA_PLANE_CREDENTIAL_CACHE_TTL_MS", "60000");
        let state = AppState::new(ServerConfig::from_env());
        std::env::remove_var("DATA_PLANE_CREDENTIAL_CACHE_TTL_MS");
        // No pool was ever created → rotating any key drains zero pools, and the
        // resolver-cache evict is a no-op-but-reached. Proves the composition is
        // wired and panic-free; concrete drain/evict behaviour is covered by the
        // pool-crate tests.
        let drained = state.rotate("t-1/default/db1/postgresql/1").await;
        assert_eq!(drained, 0, "no pool exists yet → zero drained");
        // Idempotent: a second rotate of the same key is still a clean no-op.
        assert_eq!(state.rotate("t-1/default/db1/postgresql/1").await, 0);
    }
}
