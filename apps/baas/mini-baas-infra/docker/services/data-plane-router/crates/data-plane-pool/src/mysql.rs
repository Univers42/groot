//! MySQL engine adapter — R7.
//!
//! Mirrors the design of [`crate::postgres`] but for the official
//! `mysql_async` crate. The driver owns a connection pool per
//! [`DatabaseMount::pool_key`] so the hot path never pays the connect cost the
//! legacy `MysqlEngine` TypeScript adapter does on every request
//! (`mysql.createConnection(...)` per call).
//!
//! Tenant isolation:
//!   * MySQL has no GUC equivalent to Postgres `set_config('app.current_*')`,
//!     so this adapter intersects every read filter with `owner_id = ?` server-
//!     side and re-injects `owner_id` into every write payload from the
//!     verified [`RequestIdentity`] before reaching the wire. A forged client
//!     filter or body cannot leak cross-tenant rows.
//!   * Parity contract with the legacy
//!     [`src/apps/query-router/src/engines/mysql.engine.ts`] is preserved:
//!     `owner_id` is the only column the adapter enforces (TS does not write
//!     `tenant_id` either; per-tenant DB isolation lives at the mount layer).
//!
//! Pattern stack:
//!   * Adapter (GoF)       — implements [`EngineAdapter`].
//!   * Object Pool         — `mysql_async::Pool` is already a connection pool.
//!   * Strategy            — operation kind switches the executor branch.
//!   * Template Method     — `build_owner_filter`/`build_owned_columns` shared
//!     across all read/write code paths.

use crate::ident::quote_mysql_ident;
use crate::resolver::MountResolver;
use async_trait::async_trait;
use data_plane_core::{
    CmpOp, DataOperation, DataOperationKind, DataPlaneError, DataPlaneResult, DataResult,
    DatabaseMount, EngineAdapter, EngineCapabilities, EngineHealth, EnginePool, Filter, Folded,
    MigrationRequest, MigrationResult, MigrationStatus, RawStatement, RequestIdentity, ScopeDirective,
    TxBeginRequest, TxHandle,
};
use mysql_async::prelude::Queryable;
use mysql_async::{Conn, Opts, OptsBuilder, Params, Pool, PoolConstraints, PoolOpts, Row, TxOpts};
use mysql_async::{Column, Value as MysqlValue};
use tokio::sync::Mutex;
use serde_json::{Map as JsonMap, Value};
use std::collections::BTreeMap;
use std::sync::Arc;

/// Fields the server controls — strip from any client payload before write,
/// re-inject from the verified identity. Same defensive posture as the Mongo
/// adapter's `RESERVED_FIELDS`.
const RESERVED_COLUMNS: [&str; 1] = ["owner_id"];

/// Adapter that knows how to construct [`MysqlPool`] instances from a
/// [`DatabaseMount`]. Held as `Arc<dyn EngineAdapter>` inside the registry.
pub struct MysqlEngineAdapter {
    resolver: Arc<dyn MountResolver>,
}

impl MysqlEngineAdapter {
    #[must_use]
    pub fn new(resolver: Arc<dyn MountResolver>) -> Self {
        Self { resolver }
    }
}

/// The operation kinds the MySQL adapter dispatches — the single source of
/// truth shared by both dispatch paths' gates (tx and non-tx), the capability
/// descriptor, and the honesty test.
pub(crate) const SUPPORTED_OPS: &[DataOperationKind] = &[
    DataOperationKind::List,
    DataOperationKind::Get,
    DataOperationKind::Insert,
    DataOperationKind::Update,
    DataOperationKind::Delete,
    DataOperationKind::Upsert,
];

#[async_trait]
impl EngineAdapter for MysqlEngineAdapter {
    fn engine(&self) -> &str {
        "mysql"
    }

    fn capabilities(&self) -> EngineCapabilities {
        EngineCapabilities::mysql()
    }

    fn supported_ops(&self) -> &'static [DataOperationKind] {
        SUPPORTED_OPS
    }

    async fn open_pool(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>> {
        let dsn = self.resolver.resolve_dsn(&mount).await?;
        let base_opts = Opts::from_url(&dsn).map_err(|e| DataPlaneError::Backend {
            message: format!("invalid mysql URL: {e}"),
        })?;

        let constraints = PoolConstraints::new(
            mount.pool_policy.min as usize,
            mount.pool_policy.max.max(1) as usize,
        )
        .ok_or_else(|| DataPlaneError::Backend {
            message: format!(
                "invalid mysql pool constraints min={} max={}",
                mount.pool_policy.min, mount.pool_policy.max
            ),
        })?;
        let pool_opts = PoolOpts::new().with_constraints(constraints);

        let opts: Opts = OptsBuilder::from_opts(base_opts).pool_opts(pool_opts).into();
        let pool = Pool::new(opts);

        // schema_per_tenant: the engine-neutral scope directive selects a
        // per-tenant database (`USE tenant_<id>`) on every checkout. The
        // namespace is derived from the mount's tenant_id (identity-
        // independent) so it's resolved once here; `None` for shared_rls /
        // db_per_tenant → no `USE`, byte-identical to before G5.
        let namespace = resolve_namespace(&mount);

        Ok(Box::new(MysqlPool {
            mount_id: mount.id,
            tenant_id: mount.tenant_id,
            pool,
            namespace,
        }))
    }

    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
        Ok(EngineHealth {
            engine: "mysql".to_string(),
            mount_id: pool.mount_id().to_string(),
            status: "unknown".to_string(),
        })
    }
}

/// A pooled MySQL connection set bound to a single mount.
pub struct MysqlPool {
    mount_id: String,
    tenant_id: String,
    pool: Pool,
    /// `Some("tenant_<id>")` for `schema_per_tenant` mounts: the per-tenant
    /// database selected via `USE` on every checkout. `None` (shared_rls /
    /// db_per_tenant) means no `USE` — the DSN-default database, as before G5.
    namespace: Option<String>,
}

impl MysqlPool {
    /// Pin the per-tenant database on a freshly checked-out connection.
    ///
    /// `USE` is re-issued on EVERY checkout (never assumed sticky): pooled
    /// connections are reused, so we cannot trust the database a prior borrower
    /// left selected. It is intentionally NOT run inside the per-request
    /// transaction — `USE` is connection-level state, not transactional. The
    /// schema is pre-sanitized to `[a-z0-9_]` by `safe_schema`, so interpolating
    /// it (`USE` cannot bind parameters) is injection-safe. No-op when `None`.
    async fn select_namespace(&self, conn: &mut Conn) -> DataPlaneResult<()> {
        if let Some(schema) = self.namespace.as_deref() {
            conn.query_drop(format!("USE `{schema}`"))
                .await
                .map_err(backend)?;
        }
        Ok(())
    }
}

/// The per-tenant database name for a `schema_per_tenant` MySQL mount, or
/// `None` for any other strategy (→ DSN-default database, parity). Consumes the
/// engine-neutral [`ScopeDirective`] so the isolation policy stays defined once
/// in `data-plane-core`; the namespace is per-mount, so the mount's tenant_id
/// is fed in as the scoping identity.
fn resolve_namespace(mount: &DatabaseMount) -> Option<String> {
    let identity = RequestIdentity {
        tenant_id: mount.tenant_id.clone(),
        project_id: mount.project_id.clone(),
        app_id: None,
        user_id: None,
        roles: vec![],
        scopes: vec![],
        source: data_plane_core::IdentitySource::ServiceToken,
    };
    match mount.isolation().scope(mount, &identity) {
        ScopeDirective::UseNamespace { namespace } => Some(namespace),
        ScopeDirective::None | ScopeDirective::SetSearchPath { .. } => None,
    }
}

#[async_trait]
impl EnginePool for MysqlPool {
    fn mount_id(&self) -> &str {
        &self.mount_id
    }

    async fn execute(
        &self,
        operation: DataOperation,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        // Second line of defense (the dispatcher should already have rejected
        // tenant/mount mismatches — see routes::validate_identity_mount).
        if identity.tenant_id != self.tenant_id {
            return Err(DataPlaneError::Backend {
                message: "identity tenant does not match pool tenant".into(),
            });
        }

        // Parity with the TS adapter: every request runs in its own
        // transaction so a multi-statement write is atomic per request even
        // before we expose multi-statement EnginePool::begin().
        let mut conn = self.pool.get_conn().await.map_err(backend)?;
        // schema_per_tenant: pin the per-tenant database before the tx opens
        // (USE is connection-level, not transactional). No-op for shared_rls.
        self.select_namespace(&mut conn).await?;
        if !SUPPORTED_OPS.contains(&operation.op) {
            return Err(DataPlaneError::NotImplemented {
                feature: format!("mysql operation {:?}", operation.op),
            });
        }
        let mut tx = conn
            .start_transaction(TxOpts::default())
            .await
            .map_err(backend)?;

        let result = match operation.op {
            DataOperationKind::List => run_list(&mut tx, &operation, &identity).await,
            DataOperationKind::Get => run_get(&mut tx, &operation, &identity).await,
            DataOperationKind::Insert => run_insert(&mut tx, &operation, &identity).await,
            DataOperationKind::Update => run_update(&mut tx, &operation, &identity).await,
            DataOperationKind::Delete => run_delete(&mut tx, &operation, &identity).await,
            DataOperationKind::Upsert => run_upsert(&mut tx, &operation, &identity).await,
            DataOperationKind::Batch | DataOperationKind::Aggregate => {
                Err(DataPlaneError::NotImplemented {
                    feature: "mysql batch/aggregate operation (not implemented)".to_string(),
                })
            }
        };

        match result {
            Ok(data) => {
                tx.commit().await.map_err(backend)?;
                Ok(data)
            }
            Err(e) => {
                // Best-effort rollback; we keep the original error.
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    async fn begin(&self, request: TxBeginRequest) -> DataPlaneResult<Box<dyn TxHandle>> {
        // Multi-statement transaction: check out a conn, set isolation if
        // requested, then `START TRANSACTION`. Conn stays pinned inside the
        // returned handle until commit / rollback drops it back to the pool.
        let mut conn = self.pool.get_conn().await.map_err(backend)?;
        // Pin the per-tenant database before the transaction begins.
        self.select_namespace(&mut conn).await?;
        if let Some(level) = request.isolation.as_ref() {
            let sql = match level {
                data_plane_core::IsolationLevel::ReadCommitted => {
                    "SET TRANSACTION ISOLATION LEVEL READ COMMITTED"
                }
                data_plane_core::IsolationLevel::RepeatableRead => {
                    "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ"
                }
                data_plane_core::IsolationLevel::Serializable => {
                    "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"
                }
                // MySQL has no native snapshot iso; fall back to RR.
                data_plane_core::IsolationLevel::Snapshot => {
                    "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ"
                }
            };
            conn.query_drop(sql).await.map_err(backend)?;
        }
        conn.query_drop("START TRANSACTION").await.map_err(backend)?;

        let tx_id = uuid::Uuid::now_v7().to_string();
        Ok(Box::new(MysqlTxHandle {
            tx_id,
            mount_id: self.mount_id.clone(),
            tenant_id: self.tenant_id.clone(),
            conn: Mutex::new(Some(conn)),
        }))
    }

    async fn close(&self) -> DataPlaneResult<()> {
        // `mysql_async::Pool::disconnect` consumes the pool but Pool is a cheap
        // Arc so cloning is fine; outstanding connections drop independently.
        let pool = self.pool.clone();
        pool.disconnect().await.map_err(|e| DataPlaneError::Backend {
            message: format!("mysql pool disconnect failed: {e}"),
        })
    }

    async fn execute_raw(
        &self,
        statement: RawStatement,
        _identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let mut conn = self.pool.get_conn().await.map_err(backend)?;
        self.select_namespace(&mut conn).await?;
        let params: Vec<MysqlValue> = statement.params.iter().map(json_to_mysql_value).collect();
        if statement.expect_rows {
            let rows: Vec<Row> = conn
                .exec(statement.statement.as_str(), Params::Positional(params))
                .await
                .map_err(backend)?;
            let data: Vec<Value> = rows.into_iter().map(row_to_json).collect();
            let affected = data.len() as u64;
            Ok(DataResult {
                rows: data,
                affected_rows: affected,
                next_cursor: None,
            })
        } else {
            conn.exec_drop(statement.statement.as_str(), Params::Positional(params))
                .await
                .map_err(backend)?;
            Ok(DataResult {
                rows: vec![],
                affected_rows: conn.affected_rows(),
                next_cursor: None,
            })
        }
    }

    /// Apply a named migration, recording it in `_baas_migrations` so the same
    /// name is skipped on re-application. This makes the advertised `ddl: true`
    /// honest for the `/v1/admin/migrate` route (postgres already implements it).
    ///
    /// **Atomicity caveat:** MySQL performs an *implicit commit* on every DDL
    /// statement (CREATE/ALTER/DROP), so — unlike Postgres' transactional DDL —
    /// the statement batch is **not** all-or-nothing; each DDL self-commits. The
    /// marker row still guarantees idempotency (a re-run is `Skipped`), and DML-
    /// only migrations remain effectively atomic. We therefore do not wrap the
    /// batch in a transaction that DDL would silently break.
    ///
    /// **Security (H2) — `CREATE DATABASE` blast radius / credential split:**
    /// for `schema_per_tenant`, this path issues `CREATE DATABASE IF NOT EXISTS`
    /// (below), which needs a *server-wide* `CREATE` privilege. That is a much
    /// larger blast radius than the request path needs. This is acceptable ONLY
    /// because `apply_migration` is admin/control-plane gated (the route requires
    /// `service_role`/`admin`), but the migrate-time credential SHOULD be a
    /// SEPARATE, elevated credential from the request-path runtime credential,
    /// which needs only DML + `USE` on the already-provisioned tenant DB (never
    /// `CREATE DATABASE`). Provisioning the tenant DB ideally moves OUT of the
    /// data plane entirely into the Go control plane (G2), so the runtime data
    /// plane never holds a server-wide `CREATE` grant at all. Control-plane
    /// follow-up — do not widen the runtime credential to cover this.
    async fn apply_migration(
        &self,
        request: MigrationRequest,
        _identity: RequestIdentity,
    ) -> DataPlaneResult<MigrationResult> {
        let mut conn = self.pool.get_conn().await.map_err(backend)?;
        // schema_per_tenant: create + select the per-tenant database so the
        // marker table and every migration statement land there. `schema` is
        // pre-sanitized to `[a-z0-9_]`, so interpolation is injection-safe.
        // No-op for shared_rls / db_per_tenant (DSN-default db, parity).
        if let Some(schema) = self.namespace.as_deref() {
            conn.query_drop(format!("CREATE DATABASE IF NOT EXISTS `{schema}`"))
                .await
                .map_err(backend)?;
            conn.query_drop(format!("USE `{schema}`"))
                .await
                .map_err(backend)?;
        }
        conn.query_drop(
            "CREATE TABLE IF NOT EXISTS `_baas_migrations` (\
               name VARCHAR(255) PRIMARY KEY, \
               applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP)",
        )
        .await
        .map_err(backend)?;
        let already: Option<u8> = conn
            .exec_first(
                "SELECT 1 FROM `_baas_migrations` WHERE name = ?",
                (request.name.as_str(),),
            )
            .await
            .map_err(backend)?;
        if already.is_some() {
            return Ok(MigrationResult {
                name: request.name,
                status: MigrationStatus::Skipped,
                statements_run: 0,
            });
        }
        let mut run = 0u32;
        for stmt in &request.statements {
            conn.query_drop(stmt).await.map_err(backend)?;
            run += 1;
        }
        conn.exec_drop(
            "INSERT INTO `_baas_migrations` (name) VALUES (?)",
            (request.name.as_str(),),
        )
        .await
        .map_err(backend)?;
        Ok(MigrationResult {
            name: request.name,
            status: MigrationStatus::Applied,
            statements_run: run,
        })
    }
}

/// Pinned MySQL transaction. Holds the checked-out connection across
/// execute calls; releases it when commit/rollback consumes the handle.
///
/// `conn` is `Option<Conn>` inside the Mutex so commit/rollback can take
/// ownership and drop the Conn (the deadpool reclaim happens on drop).
pub struct MysqlTxHandle {
    tx_id: String,
    mount_id: String,
    tenant_id: String,
    conn: Mutex<Option<Conn>>,
}

#[async_trait]
impl TxHandle for MysqlTxHandle {
    fn tx_id(&self) -> &str {
        &self.tx_id
    }

    fn mount_id(&self) -> &str {
        &self.mount_id
    }

    async fn execute(
        &self,
        operation: DataOperation,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        if identity.tenant_id != self.tenant_id {
            return Err(DataPlaneError::Backend {
                message: "identity tenant does not match transaction tenant".into(),
            });
        }
        if !SUPPORTED_OPS.contains(&operation.op) {
            return Err(DataPlaneError::NotImplemented {
                feature: format!("mysql operation {:?}", operation.op),
            });
        }
        let mut guard = self.conn.lock().await;
        let conn = guard.as_mut().ok_or_else(|| DataPlaneError::Backend {
            message: "mysql tx already finalised".into(),
        })?;
        match operation.op {
            DataOperationKind::List => run_list(conn, &operation, &identity).await,
            DataOperationKind::Get => run_get(conn, &operation, &identity).await,
            DataOperationKind::Insert => run_insert(conn, &operation, &identity).await,
            DataOperationKind::Update => run_update(conn, &operation, &identity).await,
            DataOperationKind::Delete => run_delete(conn, &operation, &identity).await,
            DataOperationKind::Upsert => run_upsert(conn, &operation, &identity).await,
            DataOperationKind::Batch | DataOperationKind::Aggregate => {
                Err(DataPlaneError::NotImplemented {
                    feature: "mysql batch/aggregate operation (not implemented)".to_string(),
                })
            }
        }
    }

    async fn commit(&self) -> DataPlaneResult<()> {
        let mut guard = self.conn.lock().await;
        let mut conn = guard.take().ok_or_else(|| DataPlaneError::Backend {
            message: "mysql tx already finalised".into(),
        })?;
        conn.query_drop("COMMIT").await.map_err(backend)?;
        // Drop returns the Conn to the pool.
        drop(conn);
        Ok(())
    }

    async fn rollback(&self) -> DataPlaneResult<()> {
        let mut guard = self.conn.lock().await;
        if let Some(mut conn) = guard.take() {
            // Best-effort; if the connection is already aborted, ROLLBACK is
            // a no-op on the wire.
            let _ = conn.query_drop("ROLLBACK").await;
            drop(conn);
        }
        Ok(())
    }

    async fn prepare(&self) -> DataPlaneResult<()> {
        Err(DataPlaneError::NotImplemented {
            feature: "mysql XA PREPARE (2PC)".to_string(),
        })
    }
}

// ── operation implementations ───────────────────────────────────────────────

async fn run_list(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
) -> DataPlaneResult<DataResult> {
    let table = quote_mysql_ident(&op.resource)?;
    let (where_sql, params) = build_owner_filter(op.filter.as_ref(), identity)?;
    let order_sql = build_order_by(op.sort.as_ref())?;
    let limit = op.limit.unwrap_or(100).min(500);
    let offset = op.offset.unwrap_or(0);

    let sql = format!(
        "SELECT * FROM {table}{where_sql}{order_sql} LIMIT {limit} OFFSET {offset}"
    );
    let rows: Vec<Row> = q
        .exec(sql.as_str(), Params::Positional(params))
        .await
        .map_err(backend)?;

    let data: Vec<Value> = rows.into_iter().map(row_to_json).collect();
    let affected = data.len() as u64;
    Ok(DataResult {
        rows: data,
        affected_rows: affected,
        next_cursor: None,
    })
}

async fn run_get(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
) -> DataPlaneResult<DataResult> {
    let table = quote_mysql_ident(&op.resource)?;
    let (where_sql, params) = build_owner_filter(op.filter.as_ref(), identity)?;

    let sql = format!("SELECT * FROM {table}{where_sql} LIMIT 1");
    let row: Option<Row> = q
        .exec_first(sql.as_str(), Params::Positional(params))
        .await
        .map_err(backend)?;

    let (rows, affected) = match row {
        Some(r) => (vec![row_to_json(r)], 1),
        None => (vec![], 0),
    };
    Ok(DataResult {
        rows,
        affected_rows: affected,
        next_cursor: None,
    })
}

async fn run_insert(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
) -> DataPlaneResult<DataResult> {
    let table = quote_mysql_ident(&op.resource)?;
    let columns = build_owned_columns(op.data.as_ref(), identity)?;
    if columns.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "insert `data` must not be empty".to_string(),
        });
    }

    let frags = render_insert_columns(&columns)?;
    let sql = format!(
        "INSERT INTO {table} ({col_sql}) VALUES ({placeholders})",
        col_sql = frags.columns_sql,
        placeholders = frags.placeholders
    );
    let echo = frags.echo;
    // exec_iter so we can read affected_rows + last_insert_id off the
    // QueryResult — the Queryable trait doesn't surface those on `q`.
    let result = q
        .exec_iter(sql.as_str(), Params::Positional(frags.params))
        .await
        .map_err(backend)?;
    let last_id = result.last_insert_id();
    result.drop_result().await.map_err(backend)?;

    // Match the TS adapter: return the enriched payload plus the auto-id.
    let mut out = echo;
    if let Some(id) = last_id {
        out.insert("id".to_string(), Value::Number(id.into()));
    }
    Ok(DataResult {
        rows: vec![Value::Object(out)],
        affected_rows: 1,
        next_cursor: None,
    })
}

async fn run_update(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
) -> DataPlaneResult<DataResult> {
    let table = quote_mysql_ident(&op.resource)?;
    guard_constraining_filter(op.filter.as_ref())?;
    // Server-controlled fields must not be UPDATE-able from the client.
    let set_cols = build_safe_columns(op.data.as_ref())?;
    if set_cols.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "update `data` must not be empty".to_string(),
        });
    }

    let mut params: Vec<MysqlValue> = Vec::with_capacity(set_cols.len());
    let mut set_parts = Vec::with_capacity(set_cols.len());
    for (col, val) in &set_cols {
        let quoted = quote_mysql_ident(col)?;
        set_parts.push(format!("{quoted} = ?"));
        params.push(json_to_mysql_value(val));
    }

    let (where_sql, mut where_params) = build_owner_filter(op.filter.as_ref(), identity)?;
    params.append(&mut where_params);

    let sql = format!(
        "UPDATE {table} SET {set}{where_sql}",
        set = set_parts.join(", ")
    );
    let result = q
        .exec_iter(sql.as_str(), Params::Positional(params))
        .await
        .map_err(backend)?;
    let affected = result.affected_rows();
    result.drop_result().await.map_err(backend)?;
    Ok(DataResult {
        rows: vec![],
        affected_rows: affected,
        next_cursor: None,
    })
}

async fn run_delete(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
) -> DataPlaneResult<DataResult> {
    let table = quote_mysql_ident(&op.resource)?;
    guard_constraining_filter(op.filter.as_ref())?;
    let (where_sql, params) = build_owner_filter(op.filter.as_ref(), identity)?;

    let sql = format!("DELETE FROM {table}{where_sql}");
    let result = q
        .exec_iter(sql.as_str(), Params::Positional(params))
        .await
        .map_err(backend)?;
    let affected = result.affected_rows();
    result.drop_result().await.map_err(backend)?;
    Ok(DataResult {
        rows: vec![],
        affected_rows: affected,
        next_cursor: None,
    })
}

async fn run_upsert(
    q: &mut impl Queryable,
    op: &DataOperation,
    identity: &RequestIdentity,
) -> DataPlaneResult<DataResult> {
    let table = quote_mysql_ident(&op.resource)?;
    let columns = build_owned_columns(op.data.as_ref(), identity)?;
    if columns.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "upsert `data` must not be empty".to_string(),
        });
    }

    let frags = render_insert_columns(&columns)?;
    let mut update_parts = Vec::with_capacity(columns.len());
    for (col, _) in &columns {
        let quoted = quote_mysql_ident(col)?;
        update_parts.push(format!("{quoted} = VALUES({quoted})"));
    }
    let sql = format!(
        "INSERT INTO {table} ({col_sql}) VALUES ({placeholders}) \
         ON DUPLICATE KEY UPDATE {update_sql}",
        col_sql = frags.columns_sql,
        placeholders = frags.placeholders,
        update_sql = update_parts.join(", ")
    );
    let echo = frags.echo;
    let result = q
        .exec_iter(sql.as_str(), Params::Positional(frags.params))
        .await
        .map_err(backend)?;
    let affected = result.affected_rows();
    let last_id = result.last_insert_id();
    result.drop_result().await.map_err(backend)?;
    let mut out = echo;
    if let Some(id) = last_id {
        out.insert("id".to_string(), Value::Number(id.into()));
    }
    Ok(DataResult {
        rows: vec![Value::Object(out)],
        affected_rows: affected,
        next_cursor: None,
    })
}

// ── shared helpers ──────────────────────────────────────────────────────────

fn backend<E: std::fmt::Display>(e: E) -> DataPlaneError {
    let message = format!("mysql backend: {e}");
    // Best-effort integrity-violation detection from the server message (the
    // generic helper only has the Display text): 1062 "Duplicate entry", 1452
    // foreign-key failure → a client error (409 Conflict), not an engine 5xx.
    let lower = message.to_lowercase();
    if lower.contains("duplicate entry") || lower.contains("foreign key constraint fails") {
        return DataPlaneError::Conflict { message };
    }
    DataPlaneError::Backend { message }
}

fn owner_of(identity: &RequestIdentity) -> String {
    identity
        .user_id
        .clone()
        .unwrap_or_else(|| identity.tenant_id.clone())
}

/// Take the client filter, strip any attempt to override `owner_id`, then
/// intersect with the server-trusted owner. Always returns a `WHERE` clause
/// that includes `owner_id = ?` (the second line of defense against tenant
/// escape — defense in depth alongside per-mount DSN isolation).
fn build_owner_filter(
    filter: Option<&Value>,
    identity: &RequestIdentity,
) -> DataPlaneResult<(String, Vec<MysqlValue>)> {
    let mut params: Vec<MysqlValue> = Vec::new();
    let mut clauses: Vec<String> = Vec::new();

    if let Some(filter_value) = filter {
        // Drop any top-level reserved-column override (the trusted value is added
        // below) before parsing, matching the prior posture. The trusted
        // `owner_id` predicate also supersedes any nested client `owner_id`.
        let cleaned = strip_reserved_top_level(filter_value);
        let tree = Filter::parse(&cleaned)?;
        if let Some(sql) = lower_filter(&tree, &mut params)? {
            // Parenthesize the WHOLE client filter so the trusted `owner_id` AND
            // binds it as one unit. Without this, a top-level `$or` would parse
            // as `(a) OR (b AND owner_id)` — the `a` branch unscoped (cross-owner
            // leak), because SQL `AND` binds tighter than `OR`.
            clauses.push(format!("({sql})"));
        }
    }

    // Always inject the trusted owner predicate.
    params.push(MysqlValue::Bytes(owner_of(identity).into_bytes()));
    clauses.push("`owner_id` = ?".to_string());

    Ok((format!(" WHERE {}", clauses.join(" AND ")), params))
}

/// Refuses an update/delete whose filter constrains nothing — empty, or a
/// tautology like `{$not:{$or:[]}}` that folds to "always true" — since it would
/// affect every row the caller owns. Mirrors the Postgres empty-filter guard so
/// mutations behave the same on MySQL (which has no RLS backstop). Strips
/// reserved keys first so a filter of only `{owner_id: …}` is correctly seen as
/// empty (the trusted predicate is what actually scopes it).
fn guard_constraining_filter(filter: Option<&Value>) -> DataPlaneResult<()> {
    let folded = match filter {
        Some(v) => Filter::parse(&strip_reserved_top_level(v))?.fold(),
        None => Folded::AlwaysTrue,
    };
    if folded == Folded::AlwaysTrue {
        return Err(DataPlaneError::InvalidRequest {
            message: "update/delete requires a constraining filter (refusing full-table mutation)"
                .to_string(),
        });
    }
    Ok(())
}

/// Removes top-level reserved keys from a filter object so a client can't set
/// the trusted columns. Borrows the filter unchanged in the common case (no
/// reserved key present), only cloning when one must actually be stripped.
fn strip_reserved_top_level(filter: &Value) -> std::borrow::Cow<'_, Value> {
    if let Value::Object(map) = filter {
        if map.keys().any(|k| RESERVED_COLUMNS.contains(&k.as_str())) {
            let cleaned = map
                .iter()
                .filter(|(k, _)| !RESERVED_COLUMNS.contains(&k.as_str()))
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect();
            return std::borrow::Cow::Owned(Value::Object(cleaned));
        }
    }
    std::borrow::Cow::Borrowed(filter)
}

fn cmp_op_sql(op: CmpOp) -> &'static str {
    match op {
        CmpOp::Eq => "=",
        CmpOp::Ne => "<>",
        CmpOp::Lt => "<",
        CmpOp::Lte => "<=",
        CmpOp::Gt => ">",
        CmpOp::Gte => ">=",
    }
}

/// Lowers a validated [`Filter`] to a MySQL `WHERE` fragment (without `WHERE`),
/// binding every value as a positional `?` parameter. Returns `None` when the
/// filter constrains nothing (`And([])`). Mirrors the Postgres compiler's
/// grammar so the same wire filter behaves identically; MySQL has no `ILIKE`, so
/// `$ilike` lowers to `LOWER(col) LIKE LOWER(?)`. Identifiers via
/// `quote_mysql_ident`, operators → fixed SQL, values only bound.
fn lower_filter(filter: &Filter, params: &mut Vec<MysqlValue>) -> DataPlaneResult<Option<String>> {
    Ok(match filter {
        Filter::And(parts) => {
            let mut sqls = Vec::with_capacity(parts.len());
            for p in parts {
                if let Some(s) = lower_filter(p, params)? {
                    sqls.push(s);
                }
            }
            if sqls.is_empty() {
                None
            } else {
                Some(sqls.join(" AND "))
            }
        }
        Filter::Or(parts) => {
            let mut sqls = Vec::with_capacity(parts.len());
            for p in parts {
                if let Some(s) = lower_filter(p, params)? {
                    sqls.push(format!("({s})"));
                }
            }
            // An empty/all-unconstrained `$or` matches nothing.
            Some(if sqls.is_empty() {
                "0 = 1".to_string()
            } else {
                sqls.join(" OR ")
            })
        }
        Filter::Not(inner) => lower_filter(inner, params)?.map(|s| format!("NOT ({s})")),
        Filter::Cmp { field, op, value } => {
            let q = quote_mysql_ident(field)?;
            params.push(json_to_mysql_value(value));
            Some(format!("{q} {} ?", cmp_op_sql(*op)))
        }
        Filter::In { field, values } => {
            let q = quote_mysql_ident(field)?;
            if values.is_empty() {
                Some("0 = 1".to_string())
            } else {
                let mut ph = Vec::with_capacity(values.len());
                for v in values {
                    params.push(json_to_mysql_value(v));
                    ph.push("?");
                }
                Some(format!("{q} IN ({})", ph.join(", ")))
            }
        }
        Filter::Like {
            field,
            pattern,
            ci,
        } => {
            let q = quote_mysql_ident(field)?;
            params.push(json_to_mysql_value(pattern));
            Some(if *ci {
                format!("LOWER({q}) LIKE LOWER(?)")
            } else {
                format!("{q} LIKE ?")
            })
        }
        Filter::Between { field, low, high } => {
            let q = quote_mysql_ident(field)?;
            params.push(json_to_mysql_value(low));
            params.push(json_to_mysql_value(high));
            Some(format!("{q} BETWEEN ? AND ?"))
        }
        Filter::IsNull { field, negate } => {
            let q = quote_mysql_ident(field)?;
            Some(format!("{q} IS {}NULL", if *negate { "NOT " } else { "" }))
        }
    })
}

/// Strip reserved columns from client payload, then re-inject the trusted
/// `owner_id`. Returns the ordered list of (column, value) pairs and is the
/// shared core of `INSERT` and `UPSERT`.
fn build_owned_columns(
    data: Option<&Value>,
    identity: &RequestIdentity,
) -> DataPlaneResult<Vec<(String, Value)>> {
    let map = require_object(data, "data")?;
    let mut columns: Vec<(String, Value)> = Vec::with_capacity(map.len() + 1);
    for (col, val) in map {
        if RESERVED_COLUMNS.contains(&col.as_str()) {
            continue;
        }
        columns.push((col.clone(), val.clone()));
    }
    columns.push((
        "owner_id".to_string(),
        Value::String(owner_of(identity)),
    ));
    Ok(columns)
}

/// Same shape as `build_owned_columns` but for UPDATE — drops reserved
/// columns from the SET list without re-injecting (UPDATE doesn't need to
/// re-set `owner_id`; the WHERE clause already scopes the row).
fn build_safe_columns(data: Option<&Value>) -> DataPlaneResult<Vec<(String, Value)>> {
    let map = require_object(data, "data")?;
    let mut out: Vec<(String, Value)> = Vec::with_capacity(map.len());
    for (col, val) in map {
        if RESERVED_COLUMNS.contains(&col.as_str()) {
            continue;
        }
        out.push((col.clone(), val.clone()));
    }
    Ok(out)
}

fn require_object<'a>(
    data: Option<&'a Value>,
    what: &str,
) -> DataPlaneResult<&'a JsonMap<String, Value>> {
    match data {
        Some(Value::Object(map)) => Ok(map),
        Some(other) => Err(DataPlaneError::InvalidRequest {
            message: format!("{what} must be a JSON object, got {other:?}"),
        }),
        None => Err(DataPlaneError::InvalidRequest {
            message: format!("{what} is required"),
        }),
    }
}

/// Rendered SQL fragments + ordered bind parameters + the echo payload that
/// the adapter returns to the caller. Avoids a 4-tuple return that clippy
/// flags as `type_complexity`.
struct InsertSqlFragments {
    columns_sql: String,
    placeholders: String,
    params: Vec<MysqlValue>,
    echo: JsonMap<String, Value>,
}

fn render_insert_columns(columns: &[(String, Value)]) -> DataPlaneResult<InsertSqlFragments> {
    let mut col_sql: Vec<String> = Vec::with_capacity(columns.len());
    let mut placeholders: Vec<&'static str> = Vec::with_capacity(columns.len());
    let mut params: Vec<MysqlValue> = Vec::with_capacity(columns.len());
    let mut echo = JsonMap::with_capacity(columns.len());
    for (col, val) in columns {
        let quoted = quote_mysql_ident(col)?;
        col_sql.push(quoted);
        placeholders.push("?");
        params.push(json_to_mysql_value(val));
        echo.insert(col.clone(), val.clone());
    }
    Ok(InsertSqlFragments {
        columns_sql: col_sql.join(", "),
        placeholders: placeholders.join(", "),
        params,
        echo,
    })
}

fn build_order_by(sort: Option<&BTreeMap<String, String>>) -> DataPlaneResult<String> {
    let Some(map) = sort else {
        return Ok(String::new());
    };
    if map.is_empty() {
        return Ok(String::new());
    }
    let mut parts: Vec<String> = Vec::with_capacity(map.len());
    for (col, dir) in map {
        let quoted = quote_mysql_ident(col)?;
        let dir_sql = if dir.eq_ignore_ascii_case("desc") {
            "DESC"
        } else {
            "ASC"
        };
        parts.push(format!("{quoted} {dir_sql}"));
    }
    Ok(format!(" ORDER BY {}", parts.join(", ")))
}

fn json_to_mysql_value(v: &Value) -> MysqlValue {
    match v {
        Value::Null => MysqlValue::NULL,
        Value::Bool(b) => MysqlValue::Int(i64::from(*b)),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                MysqlValue::Int(i)
            } else if let Some(u) = n.as_u64() {
                MysqlValue::UInt(u)
            } else {
                MysqlValue::Double(n.as_f64().unwrap_or(0.0))
            }
        }
        Value::String(s) => MysqlValue::Bytes(s.clone().into_bytes()),
        // Arrays + objects become JSON strings — MySQL 5.7+ has a JSON type
        // that accepts string literals.
        other => MysqlValue::Bytes(serde_json::to_vec(other).unwrap_or_default()),
    }
}

fn mysql_value_to_json(v: MysqlValue) -> Value {
    match v {
        MysqlValue::NULL => Value::Null,
        MysqlValue::Int(i) => Value::Number(i.into()),
        MysqlValue::UInt(u) => Value::Number(u.into()),
        MysqlValue::Float(f) => json_number_from_f64(f64::from(f)),
        MysqlValue::Double(d) => json_number_from_f64(d),
        MysqlValue::Bytes(bytes) => match String::from_utf8(bytes) {
            Ok(s) => Value::String(s),
            // Non-UTF8 BLOB: surface as a JSON null rather than panic; the
            // adapter is JSON-shaped on purpose and binary columns should be
            // base64-encoded by the schema-service before they ever land here.
            Err(_) => Value::Null,
        },
        MysqlValue::Date(y, mo, d, h, mi, s, us) => Value::String(format!(
            "{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}.{us:06}Z"
        )),
        MysqlValue::Time(neg, days, h, mi, s, us) => {
            let sign = if neg { "-" } else { "" };
            let total_h = u64::from(days) * 24 + u64::from(h);
            Value::String(format!("{sign}{total_h:02}:{mi:02}:{s:02}.{us:06}"))
        }
    }
}

fn json_number_from_f64(f: f64) -> Value {
    serde_json::Number::from_f64(f)
        .map(Value::Number)
        .unwrap_or(Value::Null)
}

fn row_to_json(mut row: Row) -> Value {
    let columns: Vec<Column> = row.columns_ref().to_vec();
    let mut out = JsonMap::with_capacity(columns.len());
    for (idx, col) in columns.iter().enumerate() {
        let name = col.name_str().into_owned();
        let raw: MysqlValue = row.take(idx).unwrap_or(MysqlValue::NULL);
        out.insert(name, mysql_value_to_json(raw));
    }
    Value::Object(out)
}

// ── unit tests (security-critical bits) ─────────────────────────────────────
#[cfg(test)]
mod tests {
    use super::*;
    use data_plane_core::IdentitySource;
    use serde_json::json;

    fn identity_with(user: Option<&str>) -> RequestIdentity {
        RequestIdentity {
            tenant_id: "t-1".to_string(),
            project_id: None,
            app_id: None,
            user_id: user.map(str::to_string),
            roles: vec![],
            scopes: vec![],
            source: IdentitySource::Test,
        }
    }

    #[test]
    fn owner_filter_always_injects_owner_predicate() {
        let id = identity_with(Some("u-1"));
        let (sql, params) = build_owner_filter(None, &id).unwrap();
        assert_eq!(sql, " WHERE `owner_id` = ?");
        assert_eq!(params.len(), 1);
        assert!(matches!(&params[0], MysqlValue::Bytes(b) if b == b"u-1"));
    }

    #[test]
    fn owner_filter_lowers_operators_not_just_equality() {
        // THE bug fix: an operator object is now a real predicate, not silently
        // bound as a literal value (which matched zero rows).
        let id = identity_with(Some("u-1"));
        // The client filter is always parenthesized so the trusted `owner_id`
        // AND scopes the WHOLE predicate (the `$or` case is the security proof).
        let cases = [
            (json!({ "age": { "$gte": 18 } }), " WHERE (`age` >= ?) AND `owner_id` = ?"),
            (json!({ "status": { "$in": ["a", "b"] } }), " WHERE (`status` IN (?, ?)) AND `owner_id` = ?"),
            (json!({ "n": { "$between": [1, 9] } }), " WHERE (`n` BETWEEN ? AND ?) AND `owner_id` = ?"),
            (json!({ "x": { "$null": true } }), " WHERE (`x` IS NULL) AND `owner_id` = ?"),
            (json!({ "name": { "$ilike": "a%" } }), " WHERE (LOWER(`name`) LIKE LOWER(?)) AND `owner_id` = ?"),
            (json!({ "$or": [{ "a": 1 }, { "b": { "$lt": 5 } }] }), " WHERE ((`a` = ?) OR (`b` < ?)) AND `owner_id` = ?"),
            (json!({ "name": "x" }), " WHERE (`name` = ?) AND `owner_id` = ?"), // equality still works
        ];
        for (filter, expected) in cases {
            let (sql, _) = build_owner_filter(Some(&filter), &id).unwrap();
            assert_eq!(sql, expected, "filter {filter}");
        }
    }

    #[test]
    fn owner_filter_rejects_unknown_operator() {
        let id = identity_with(Some("u-1"));
        let err = build_owner_filter(Some(&json!({ "a": { "$drop": 1 } })), &id).unwrap_err();
        assert!(matches!(err, DataPlaneError::InvalidRequest { .. }), "{err:?}");
    }

    #[test]
    fn update_delete_refuse_unconstrained_filter() {
        // No empty/tautology full-table mutation (parity with the Postgres guard).
        let unconstrained = [
            None,
            Some(json!({})),
            Some(json!({ "$not": { "$or": [] } })),
            Some(json!({ "owner_id": "x" })), // only a reserved key → empty after strip
        ];
        for filter in unconstrained {
            let err = guard_constraining_filter(filter.as_ref()).unwrap_err();
            assert!(matches!(err, DataPlaneError::InvalidRequest { .. }), "{filter:?}: {err:?}");
        }
        assert!(guard_constraining_filter(Some(&json!({ "id": 1 }))).is_ok());
    }

    #[test]
    fn owner_filter_drops_client_owner_id_override() {
        let id = identity_with(Some("u-trusted"));
        let filter = json!({"owner_id": "u-attacker", "name": "needle"});
        let (sql, params) = build_owner_filter(Some(&filter), &id).unwrap();
        // Client `owner_id` is dropped, only the trusted one is appended at the end.
        assert!(sql.contains("`name` = ?"));
        assert!(sql.ends_with("`owner_id` = ?"));
        // Last param is always the trusted owner_id.
        assert!(matches!(params.last(), Some(MysqlValue::Bytes(b)) if b == b"u-trusted"));
    }

    #[test]
    fn owner_filter_falls_back_to_tenant_id() {
        let id = identity_with(None);
        let (_, params) = build_owner_filter(None, &id).unwrap();
        assert!(matches!(&params[0], MysqlValue::Bytes(b) if b == b"t-1"));
    }

    #[test]
    fn owner_filter_rejects_non_object_filter() {
        let id = identity_with(Some("u-1"));
        let bad = json!("just a string");
        let err = build_owner_filter(Some(&bad), &id).unwrap_err();
        assert!(matches!(err, DataPlaneError::InvalidRequest { .. }));
    }

    #[test]
    fn owner_filter_rejects_injection_via_column_name() {
        let id = identity_with(Some("u-1"));
        let bad = json!({"name; DROP TABLE users;--": "x"});
        let err = build_owner_filter(Some(&bad), &id).unwrap_err();
        assert!(matches!(err, DataPlaneError::InvalidIdentifier { .. }));
    }

    #[test]
    fn owned_columns_strips_client_owner_id_and_appends_trusted_one() {
        let id = identity_with(Some("u-trusted"));
        let data = json!({"owner_id": "u-attacker", "name": "ok"});
        let cols = build_owned_columns(Some(&data), &id).unwrap();
        let names: Vec<&str> = cols.iter().map(|(c, _)| c.as_str()).collect();
        assert!(!names.contains(&"owner_id") || names.last().copied() == Some("owner_id"));
        // owner_id must appear exactly once and be the trusted value.
        let owner_occurrences: Vec<&Value> = cols
            .iter()
            .filter(|(c, _)| c == "owner_id")
            .map(|(_, v)| v)
            .collect();
        assert_eq!(owner_occurrences.len(), 1);
        assert_eq!(owner_occurrences[0], &Value::String("u-trusted".to_string()));
    }

    #[test]
    fn owned_columns_rejects_missing_data() {
        let id = identity_with(Some("u-1"));
        let err = build_owned_columns(None, &id).unwrap_err();
        assert!(matches!(err, DataPlaneError::InvalidRequest { .. }));
    }

    #[test]
    fn safe_columns_strips_owner_id() {
        let data = json!({"owner_id": "u-attacker", "name": "ok"});
        let cols = build_safe_columns(Some(&data)).unwrap();
        for (c, _) in &cols {
            assert_ne!(c, "owner_id");
        }
        assert_eq!(cols.len(), 1);
    }

    #[test]
    fn order_by_quotes_identifiers_and_caps_direction() {
        let mut sort = BTreeMap::new();
        sort.insert("created_at".to_string(), "desc".to_string());
        sort.insert("name".to_string(), "asc".to_string());
        let sql = build_order_by(Some(&sort)).unwrap();
        assert!(sql.contains("`created_at` DESC"));
        assert!(sql.contains("`name` ASC"));
    }

    #[test]
    fn order_by_rejects_injection_via_column() {
        let mut sort = BTreeMap::new();
        sort.insert("name; DROP".to_string(), "asc".to_string());
        assert!(build_order_by(Some(&sort)).is_err());
    }

    #[test]
    fn json_to_mysql_value_handles_scalars() {
        assert!(matches!(json_to_mysql_value(&Value::Null), MysqlValue::NULL));
        assert!(matches!(
            json_to_mysql_value(&json!(42)),
            MysqlValue::Int(42)
        ));
        assert!(matches!(
            json_to_mysql_value(&json!(true)),
            MysqlValue::Int(1)
        ));
        assert!(matches!(
            json_to_mysql_value(&json!("hi")),
            MysqlValue::Bytes(b) if b == b"hi"
        ));
    }

    #[test]
    fn json_to_mysql_value_encodes_objects_as_json_string() {
        let v = json!({"k": 1});
        let MysqlValue::Bytes(bytes) = json_to_mysql_value(&v) else {
            panic!("expected Bytes");
        };
        let as_str = String::from_utf8(bytes).unwrap();
        assert_eq!(as_str, r#"{"k":1}"#);
    }

    #[test]
    fn mysql_value_to_json_roundtrips_int_string_null() {
        assert_eq!(mysql_value_to_json(MysqlValue::NULL), Value::Null);
        assert_eq!(
            mysql_value_to_json(MysqlValue::Int(7)),
            Value::Number(7i64.into())
        );
        assert_eq!(
            mysql_value_to_json(MysqlValue::Bytes(b"hello".to_vec())),
            Value::String("hello".to_string())
        );
    }

    #[test]
    fn resolve_namespace_only_for_schema_per_tenant() {
        // Parity with redis's resolve_namespace test: the per-tenant database is
        // selected ONLY for `schema_per_tenant`; every other strategy → None
        // (DSN-default db, byte-identical to before G5). The schema_per_tenant
        // name carries the collision-free `_<hash8>` suffix, so match the prefix.
        use data_plane_core::{CredentialRef, DatabaseMount, PoolPolicy};
        let mk = |iso: Option<&str>| DatabaseMount {
            id: "db1".into(),
            tenant_id: "t-1".into(),
            project_id: None,
            engine: "mysql".into(),
            name: "n".into(),
            credential_ref: CredentialRef {
                provider: "adapter-registry".into(),
                reference: "r".into(),
                version: "1".into(),
            },
            pool_policy: PoolPolicy::default(),
            capability_overrides: None,
            inline_dsn: None,
            isolation: iso.map(str::to_string),
        };
        assert_eq!(resolve_namespace(&mk(None)), None);
        assert_eq!(resolve_namespace(&mk(Some("shared_rls"))), None);
        assert_eq!(resolve_namespace(&mk(Some("db_per_tenant"))), None);
        let ns = resolve_namespace(&mk(Some("schema_per_tenant"))).unwrap();
        assert!(ns.starts_with("tenant_t_1_"), "{ns}");
    }
}
