//! MongoDB engine adapter — R3.
//!
//! Mirrors the design of [`crate::postgres`] but for the official `mongodb`
//! crate. The Rust driver already owns a connection pool per [`mongodb::Client`]
//! — we cache one Client per [`DatabaseMount::pool_key`] so the hot path never
//! pays the connect cost the legacy `MongodbEngine` TypeScript adapter does
//! on every request (`new MongoClient(uri).connect()` per call).
//!
//! Tenant isolation:
//!   * Every insert is decorated with `owner_id` and `tenant_id` from the
//!     verified [`RequestIdentity`] before reaching the wire — the document the
//!     client sent cannot override these fields.
//!   * Every read filter is intersected with the same fields, so a forged
//!     resource name still cannot leak cross-tenant rows.
//!
//! Pattern stack:
//!   * Adapter (GoF)       — implements [`EngineAdapter`].
//!   * Object Pool         — `mongodb::Client` is already a connection pool.
//!   * Strategy            — operation kind switches the executor branch.
//!   * Template Method     — `build_tenant_filter`/`build_owned_doc` shared
//!     across all read/write code paths.

use async_trait::async_trait;
use bson::{Bson, Document};
use data_plane_core::{
    DataOperation, DataOperationKind, DataPlaneError, DataPlaneResult, DataResult, DatabaseMount,
    EngineAdapter, EngineCapabilities, EngineHealth, EnginePool, RequestIdentity, ScopeDirective,
    TxBeginRequest, TxHandle,
};
use futures::TryStreamExt;
use mongodb::{
    options::{ClientOptions, FindOptions, UpdateOptions},
    Client, Collection,
};
use serde_json::Value;
use std::{sync::Arc, time::Duration};

use crate::ident::quote_ident;
use crate::resolver::MountResolver;

/// Fields the server controls — strip from any client payload before write,
/// re-inject from the verified identity. Prevents tenant escape via document
/// shape (the equivalent of SQL injection for document stores).
const RESERVED_FIELDS: [&str; 3] = ["_id", "owner_id", "tenant_id"];

/// MongoDB query operators that are safe to accept from an untrusted client
/// filter — comparison, logical, element and array operators only. This is a
/// **default-deny allowlist**: any `$`-prefixed key not in this set is rejected,
/// which closes the NoSQL-injection surface of the raw `bson::to_document`
/// passthrough — notably the evaluation operators `$where`/`$expr`/`$function`/
/// `$accumulator`/`$jsonSchema` that can execute server-side JavaScript or run
/// arbitrary expressions. (`$regex` is permitted as the standard pattern-search
/// operator; bounding its ReDoS cost is tracked with the shared-Filter follow-up.)
const SAFE_MONGO_OPERATORS: &[&str] = &[
    "$eq", "$ne", "$gt", "$gte", "$lt", "$lte", "$in", "$nin", "$and", "$or", "$nor", "$not",
    "$exists", "$type", "$regex", "$options", "$all", "$elemMatch", "$size", "$mod", "$bitsAllSet",
    "$bitsAnySet", "$bitsAllClear", "$bitsAnyClear",
];

/// Rejects a write `data` document whose top-level keys include a `$`-prefixed
/// name. Such names are never valid stored field names (Mongo rejects them under
/// `$set` with a server error), so this turns a would-be 502 into a clean 400 —
/// keeping the write path symmetric with the filter allowlist. Dotted
/// (nested-path) keys are intentionally allowed: they are legitimate nested
/// updates and cannot escape tenancy (the trust fields are re-injected at the
/// top level).
fn reject_top_level_operators(data: &Value) -> DataPlaneResult<()> {
    if let Value::Object(map) = data {
        for key in map.keys() {
            if key.starts_with('$') {
                return Err(DataPlaneError::InvalidRequest {
                    message: format!("write data must not contain operator key '{key}'"),
                });
            }
        }
    }
    Ok(())
}

/// Recursively rejects any `$`-prefixed key in a client filter that is not in
/// [`SAFE_MONGO_OPERATORS`]. Walked before the filter is handed to
/// `bson::to_document`, so a `$where`/`$expr`/`$function` injection never reaches
/// the driver. Field names (non-`$` keys) are unrestricted — the danger is the
/// operators, and the trust fields are re-injected after this check.
fn reject_unsafe_operators(value: &Value) -> DataPlaneResult<()> {
    match value {
        Value::Object(map) => {
            for (key, val) in map {
                if key.starts_with('$') && !SAFE_MONGO_OPERATORS.contains(&key.as_str()) {
                    return Err(DataPlaneError::InvalidRequest {
                        message: format!("filter operator '{key}' is not permitted"),
                    });
                }
                reject_unsafe_operators(val)?;
            }
            Ok(())
        }
        Value::Array(items) => {
            for item in items {
                reject_unsafe_operators(item)?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

/// Adapter that knows how to construct [`MongoPool`] instances from a
/// [`DatabaseMount`]. Held as `Arc<dyn EngineAdapter>` inside the registry.
pub struct MongoEngineAdapter {
    resolver: Arc<dyn MountResolver>,
}

impl MongoEngineAdapter {
    #[must_use]
    pub fn new(resolver: Arc<dyn MountResolver>) -> Self {
        Self { resolver }
    }
}

/// The operation kinds the Mongo adapter dispatches — the single source of
/// truth shared by `execute`'s gate, the capability descriptor, and the
/// honesty test.
pub(crate) const SUPPORTED_OPS: &[DataOperationKind] = &[
    DataOperationKind::List,
    DataOperationKind::Get,
    DataOperationKind::Insert,
    DataOperationKind::Update,
    DataOperationKind::Delete,
    DataOperationKind::Upsert,
];

#[async_trait]
impl EngineAdapter for MongoEngineAdapter {
    fn engine(&self) -> &str {
        "mongodb"
    }

    fn capabilities(&self) -> EngineCapabilities {
        EngineCapabilities::mongodb()
    }

    fn supported_ops(&self) -> &'static [DataOperationKind] {
        SUPPORTED_OPS
    }

    async fn open_pool(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>> {
        let dsn = self.resolver.resolve_dsn(&mount).await?;
        let mut options = ClientOptions::parse(&dsn).await.map_err(|e| {
            DataPlaneError::Backend {
                message: format!("invalid mongo URI: {e}"),
            }
        })?;
        // Bound concurrent connections per mount via pool policy; the
        // driver already enforces this efficiently.
        options.max_pool_size = Some(mount.pool_policy.max);
        options.min_pool_size = Some(mount.pool_policy.min);
        options.server_selection_timeout = Some(Duration::from_millis(
            mount.pool_policy.idle_ttl_ms.max(5_000),
        ));
        options.app_name = Some(format!("mini-baas/{}", mount.id));

        let client = Client::with_options(options).map_err(|e| DataPlaneError::Backend {
            message: format!("mongo client init failed: {e}"),
        })?;

        // Database name resolution mirrors the TypeScript adapter: take the
        // URI path component, fall back to "test" so misconfigured mounts
        // surface a backend error, not a panic.
        //
        // schema_per_tenant: the engine-neutral scope directive selects a
        // per-tenant database (`tenant_<id>`) instead of the DSN-default db.
        // The namespace is derived from the mount's tenant_id (identity-
        // independent), so it's stable for the pool's lifetime and resolved
        // once here. For shared_rls / db_per_tenant the directive is `None` →
        // the DSN-default db, byte-identical to before G5.
        let db_name = resolve_namespace(&mount).unwrap_or_else(|| parse_db_name(&dsn));

        Ok(Box::new(MongoPool {
            mount_id: mount.id.clone(),
            tenant_id: mount.tenant_id.clone(),
            client,
            db_name,
        }))
    }

    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
        Ok(EngineHealth {
            engine: "mongodb".to_string(),
            mount_id: pool.mount_id().to_string(),
            status: "unknown".to_string(),
        })
    }
}

/// Single mount, single Mongo Client (which itself owns the connection pool).
pub struct MongoPool {
    mount_id: String,
    tenant_id: String,
    client: Client,
    db_name: String,
}

impl MongoPool {
    fn collection(&self, name: &str) -> DataPlaneResult<Collection<Document>> {
        // `quote_ident` rejects names with `$`, `.`, control chars etc.
        let safe = quote_ident(name)?;
        // quote_ident wraps in `"..."` for SQL; strip them for Mongo.
        let trimmed = safe.trim_matches('"').to_string();
        Ok(self.client.database(&self.db_name).collection(&trimmed))
    }

    fn owner(identity: &RequestIdentity) -> String {
        identity
            .user_id
            .clone()
            .unwrap_or_else(|| identity.tenant_id.clone())
    }
}

#[async_trait]
impl EnginePool for MongoPool {
    fn mount_id(&self) -> &str {
        &self.mount_id
    }

    async fn execute(
        &self,
        operation: DataOperation,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        // Fail-closed cross-check: the dispatcher should already have rejected
        // identity/mount mismatches, but the pool is the second line of defense.
        if identity.tenant_id != self.tenant_id {
            return Err(DataPlaneError::Backend {
                message: "identity tenant does not match pool tenant".into(),
            });
        }

        if !SUPPORTED_OPS.contains(&operation.op) {
            return Err(DataPlaneError::NotImplemented {
                feature: format!("mongo operation {:?}", operation.op),
            });
        }
        let col = self.collection(&operation.resource)?;
        match operation.op {
            DataOperationKind::List => self.run_list(&col, &operation, &identity).await,
            DataOperationKind::Get => self.run_get(&col, &operation, &identity).await,
            DataOperationKind::Insert => self.run_insert(&col, &operation, &identity).await,
            DataOperationKind::Update => self.run_update(&col, &operation, &identity).await,
            DataOperationKind::Delete => self.run_delete(&col, &operation, &identity).await,
            DataOperationKind::Upsert => self.run_upsert(&col, &operation, &identity).await,
            DataOperationKind::Batch | DataOperationKind::Aggregate => {
                Err(DataPlaneError::NotImplemented {
                    feature: "mongo batch/aggregate operation (not implemented)".to_string(),
                })
            }
        }
    }

    async fn begin(&self, _request: TxBeginRequest) -> DataPlaneResult<Box<dyn TxHandle>> {
        // Mongo multi-statement transactions require threading a
        // `ClientSession` through every operation (the mongodb 2.x driver's
        // `*_with_session` variants), and per-tx pinning of a primary on a
        // replica set. That's a wider refactor than the PG/MySQL case and
        // is intentionally deferred. Single-document writes remain atomic.
        // Per-request grouping via the auto-commit `execute()` path is the
        // current parity guarantee.
        Err(DataPlaneError::NotImplemented {
            feature: "mongo multi-statement transactions (session-threading refactor pending)"
                .to_string(),
        })
    }

    async fn close(&self) -> DataPlaneResult<()> {
        // mongodb::Client closes its connections when dropped — no explicit
        // shutdown handshake required.
        Ok(())
    }
}

impl MongoPool {
    async fn run_list(
        &self,
        col: &Collection<Document>,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let filter = build_tenant_filter(op.filter.as_ref(), identity, &self.tenant_id)?;
        let limit = op.limit.unwrap_or(100).min(1_000) as i64;
        let skip = op.offset.unwrap_or(0) as u64;
        let find_opts = FindOptions::builder()
            .limit(Some(limit))
            .skip(Some(skip))
            .sort(build_sort(op.sort.as_ref()))
            .build();

        let cursor = col.find(filter, find_opts).await.map_err(mongo_err)?;
        let docs: Vec<Document> = cursor.try_collect().await.map_err(mongo_err)?;
        let rows: Vec<Value> = docs.into_iter().map(normalize_doc).collect();
        let affected = rows.len() as u64;
        Ok(DataResult {
            rows,
            affected_rows: affected,
            next_cursor: None,
        })
    }

    async fn run_get(
        &self,
        col: &Collection<Document>,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let filter = build_tenant_filter(op.filter.as_ref(), identity, &self.tenant_id)?;
        let doc = col.find_one(filter, None).await.map_err(mongo_err)?;
        match doc {
            Some(d) => Ok(DataResult {
                rows: vec![normalize_doc(d)],
                affected_rows: 1,
                next_cursor: None,
            }),
            None => Ok(DataResult {
                rows: vec![],
                affected_rows: 0,
                next_cursor: None,
            }),
        }
    }

    async fn run_insert(
        &self,
        col: &Collection<Document>,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let data = op.data.as_ref().ok_or_else(|| DataPlaneError::InvalidRequest {
            message: "insert requires operation.data".to_string(),
        })?;
        let doc = build_owned_doc(data, identity, &self.tenant_id)?;
        let result = col.insert_one(doc.clone(), None).await.map_err(mongo_err)?;
        let mut out = doc;
        out.insert("_id", result.inserted_id);
        Ok(DataResult {
            rows: vec![normalize_doc(out)],
            affected_rows: 1,
            next_cursor: None,
        })
    }

    async fn run_update(
        &self,
        col: &Collection<Document>,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let filter = build_tenant_filter(op.filter.as_ref(), identity, &self.tenant_id)?;
        let data = op.data.as_ref().ok_or_else(|| DataPlaneError::InvalidRequest {
            message: "update requires operation.data".to_string(),
        })?;
        reject_top_level_operators(data)?;
        let set_doc = json_to_doc(data)?;
        let update = bson::doc! { "$set": set_doc };
        let result = col.update_many(filter, update, None).await.map_err(mongo_err)?;
        Ok(DataResult {
            rows: vec![],
            affected_rows: result.modified_count,
            next_cursor: None,
        })
    }

    async fn run_delete(
        &self,
        col: &Collection<Document>,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let filter = build_tenant_filter(op.filter.as_ref(), identity, &self.tenant_id)?;
        let result = col.delete_many(filter, None).await.map_err(mongo_err)?;
        Ok(DataResult {
            rows: vec![],
            affected_rows: result.deleted_count,
            next_cursor: None,
        })
    }

    async fn run_upsert(
        &self,
        col: &Collection<Document>,
        op: &DataOperation,
        identity: &RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        let data = op.data.as_ref().ok_or_else(|| DataPlaneError::InvalidRequest {
            message: "upsert requires operation.data".to_string(),
        })?;
        let Value::Object(obj) = data else {
            return Err(DataPlaneError::InvalidRequest {
                message: "upsert requires data to be a JSON object".to_string(),
            });
        };
        // Upsert needs an identifier — `id` or `_id` from the client. It must be
        // a scalar: an upsert targets one specific document, and accepting an
        // object here would let a client inject query operators (`{$gt:""}`) into
        // the `_id` filter (the upsert path doesn't run `build_tenant_filter`).
        let mut filter = bson::doc! {};
        if let Some(id_val) = obj.get("id").or_else(|| obj.get("_id")) {
            if !matches!(id_val, Value::String(_) | Value::Number(_) | Value::Bool(_)) {
                return Err(DataPlaneError::InvalidRequest {
                    message: "upsert `id`/`_id` must be a scalar value".to_string(),
                });
            }
            filter.insert("_id", value_to_bson(id_val)?);
        }
        // Always enforce tenant scope on the filter side too.
        filter.insert("owner_id", MongoPool::owner(identity));
        filter.insert("tenant_id", identity.tenant_id.clone());

        let set_doc = build_owned_doc(data, identity, &self.tenant_id)?;
        let update = bson::doc! { "$set": set_doc };
        let update_opts = UpdateOptions::builder().upsert(true).build();
        let result = col
            .update_one(filter, update, update_opts)
            .await
            .map_err(mongo_err)?;
        Ok(DataResult {
            rows: vec![],
            affected_rows: result.modified_count + u64::from(result.upserted_id.is_some()),
            next_cursor: None,
        })
    }
}

fn mongo_err(e: mongodb::error::Error) -> DataPlaneError {
    DataPlaneError::Backend {
        message: format!("mongo backend: {e}"),
    }
}

/// The per-tenant database name for a `schema_per_tenant` mount, or `None`
/// for any other strategy (→ caller keeps the DSN-default db, parity). Built by
/// consuming the engine-neutral [`ScopeDirective`] so the isolation policy
/// stays defined in one place (`data-plane-core`). The namespace is derived
/// from the mount's `tenant_id`, which we feed in as the scoping identity since
/// Mongo's namespace selection is per-mount, not per-request.
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

fn parse_db_name(dsn: &str) -> String {
    // Strict-enough URI parsing: split off the path component after the host.
    if let Some(after_scheme) = dsn.split("://").nth(1) {
        if let Some((_, after_host)) = after_scheme.split_once('/') {
            let name = after_host.split('?').next().unwrap_or("");
            if !name.is_empty() {
                return name.to_string();
            }
        }
    }
    "test".to_string()
}

fn json_to_doc(value: &Value) -> DataPlaneResult<Document> {
    match value {
        Value::Object(_) => bson::to_document(value).map_err(|e| DataPlaneError::Backend {
            message: format!("json→bson document: {e}"),
        }),
        _ => Err(DataPlaneError::InvalidRequest {
            message: "expected JSON object".to_string(),
        }),
    }
}

fn value_to_bson(value: &Value) -> DataPlaneResult<Bson> {
    bson::to_bson(value).map_err(|e| DataPlaneError::Backend {
        message: format!("json→bson: {e}"),
    })
}

/// Strip server-controlled fields from a client payload, then re-inject the
/// trusted values so the wire document is always tenant-scoped.
fn build_owned_doc(
    data: &Value,
    identity: &RequestIdentity,
    tenant_id: &str,
) -> DataPlaneResult<Document> {
    reject_top_level_operators(data)?;
    let mut doc = json_to_doc(data)?;
    for field in RESERVED_FIELDS {
        doc.remove(field);
    }
    doc.insert("owner_id", MongoPool::owner(identity));
    doc.insert("tenant_id", tenant_id.to_string());
    Ok(doc)
}

/// Take the client filter (if any) and intersect it with the server-side
/// tenant scope so an attacker cannot drop the predicate.
fn build_tenant_filter(
    filter: Option<&Value>,
    identity: &RequestIdentity,
    tenant_id: &str,
) -> DataPlaneResult<Document> {
    let mut doc = match filter {
        Some(v @ Value::Object(_)) => {
            // Default-deny operator allowlist BEFORE conversion → no `$where`/
            // `$expr`/`$function` injection reaches the driver.
            reject_unsafe_operators(v)?;
            json_to_doc(v)?
        }
        Some(other) => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("filter must be a JSON object, got {other:?}"),
            });
        }
        None => Document::new(),
    };
    // Strip any client-provided override of the trust fields.
    for field in RESERVED_FIELDS {
        doc.remove(field);
    }
    doc.insert("owner_id", MongoPool::owner(identity));
    doc.insert("tenant_id", tenant_id.to_string());
    Ok(doc)
}

fn build_sort(sort: Option<&std::collections::BTreeMap<String, String>>) -> Option<Document> {
    let map = sort?;
    if map.is_empty() {
        return None;
    }
    let mut out = Document::new();
    for (k, dir) in map {
        let value: i32 = if dir.eq_ignore_ascii_case("desc") { -1 } else { 1 };
        out.insert(k, value);
    }
    Some(out)
}

fn normalize_doc(mut doc: Document) -> Value {
    // Map Mongo's `_id` → `id` so downstream contracts (SDK, dashboard, the graph)
    // see a uniform `id`. But NEVER clobber a client-supplied logical `id`: the
    // graph addresses a node by its logical id (the NodeId pk) and edges reference
    // that same id — overwriting it with the auto-generated ObjectId would
    // disconnect the node from its edges in `/graph/overview`. Only synthesize
    // `id` from `_id` when the document has no logical `id` of its own.
    let had_logical_id = doc.contains_key("id");
    if let Some(id) = doc.remove("_id") {
        if !had_logical_id {
            let id_str = match id {
                Bson::ObjectId(o) => o.to_hex(),
                Bson::String(s) => s,
                other => other.to_string(),
            };
            doc.insert("id", id_str);
        }
    }
    Bson::Document(doc).into_relaxed_extjson()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn rejects_javascript_and_expression_operators() {
        // The NoSQL-injection fix: code/expression operators are refused, at any
        // nesting depth, with a client error (400).
        for bad in [
            json!({ "$where": "this.x == 1" }),
            json!({ "$expr": { "$eq": ["$a", "$b"] } }),
            json!({ "name": { "$function": { "body": "f", "args": [], "lang": "js" } } }),
            json!({ "$or": [{ "x": 1 }, { "$where": "true" }] }), // nested under $or
            json!({ "a": { "b": { "$accumulator": {} } } }),       // deeply nested
        ] {
            let err = reject_unsafe_operators(&bad).unwrap_err();
            assert!(matches!(err, DataPlaneError::InvalidRequest { .. }), "{bad}: {err:?}");
        }
    }

    #[test]
    fn allows_standard_query_operators() {
        for ok in [
            json!({ "age": { "$gte": 18 } }),
            json!({ "status": { "$in": ["a", "b"], "$nin": ["c"] } }),
            json!({ "$or": [{ "a": 1 }, { "b": { "$lt": 5 } }], "$nor": [{ "z": 9 }] }),
            json!({ "name": { "$regex": "^a", "$options": "i" } }),
            json!({ "tags": { "$elemMatch": { "$eq": "x" } } }),
            json!({ "plain": "equality", "n": 3 }),
        ] {
            assert!(reject_unsafe_operators(&ok).is_ok(), "{ok}");
        }
    }

    #[test]
    fn allowlist_is_exact_and_case_sensitive() {
        // `$jsonSchema` (eval) is denied; a case variant of a safe op is not a
        // real operator and is denied too (exact match) — both fail closed.
        assert!(reject_unsafe_operators(&json!({ "$jsonSchema": {} })).is_err());
        assert!(reject_unsafe_operators(&json!({ "a": { "$GTE": 1 } })).is_err());
        // a safe operator nested under an unsafe one is still rejected (key
        // checked before recursing).
        assert!(reject_unsafe_operators(&json!({ "$where": { "$eq": 1 } })).is_err());
    }

    #[test]
    fn write_data_rejects_top_level_operator_keys() {
        // The write-path symmetry fix: a `$`-prefixed top-level key in write data
        // is a clean 400, not a 502 from the driver.
        for bad in [json!({ "$rename": { "a": "b" } }), json!({ "$set": { "x": 1 } })] {
            assert!(
                matches!(
                    reject_top_level_operators(&bad).unwrap_err(),
                    DataPlaneError::InvalidRequest { .. }
                ),
                "{bad}"
            );
        }
        // ordinary and dotted (nested-path) keys are allowed.
        assert!(reject_top_level_operators(&json!({ "name": "x", "profile.age": 3 })).is_ok());
    }
}
