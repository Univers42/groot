//! SQLite engine adapter (R-sqlite, Phase 3b).
//!
//! Embedded, file-per-mount engine on `rusqlite` (sync) driven through
//! `deadpool-sqlite`'s `interact()`, which runs each closure on a blocking
//! thread so the async runtime is never stalled. WAL is enabled at pool open
//! (1 writer + N concurrent readers) and `busy_timeout` smooths writer
//! contention. The DSN is a file path (`sqlite:///var/lib/mini-baas/<ref>.db`),
//! so a `db_per_tenant` mount is a distinct file; `shared_rls` mounts owner-scope
//! every read/write via an `owner_id` predicate exactly like the MySQL adapter
//! (SQLite has no RLS), and writes are owner-stamped so a forged body cannot
//! cross tenants.
//!
//! Honest descriptor (`EngineCapabilities::sqlite`): CRUD + upsert + ATOMIC
//! batch + aggregate + introspection. `transactions:false` — a connection-pinned
//! cross-request TxHandle is disproportionate under the `interact` model, so
//! `begin()` returns NotImplemented; a single batch is still atomic (one tx
//! inside one closure).

use crate::resolver::MountResolver;
use async_trait::async_trait;
use data_plane_core::{
    AggFunc, Aggregate, BatchItemOutcome, BatchItemStatus, BatchSummary, CmpOp, ColumnSchema,
    DataOperation, DataOperationKind, DataPlaneError, DataPlaneResult, DataResult, DatabaseMount,
    EngineAdapter, EngineCapabilities, EngineHealth, EnginePool, Filter, Folded, NormalizedType,
    RawStatement, RequestIdentity, SchemaDescriptor, TableSchema, TxBeginRequest, TxHandle,
};
use deadpool_sqlite::{Config as SqliteConfig, Pool, Runtime};
use rusqlite::types::Value as SqlValue;
use rusqlite::{params_from_iter, Connection};
use serde_json::{Map as JsonMap, Value};
use std::collections::BTreeMap;
use std::sync::Arc;

/// Server-controlled columns a client may never set/override.
const RESERVED_COLUMNS: &[&str] = &["owner_id", "tenant_id"];

/// The op kinds this adapter dispatches — single source of truth for the
/// descriptor (via `capability_honesty`) and the per-request gate.
pub(crate) const SUPPORTED_OPS: &[DataOperationKind] = &[
    DataOperationKind::List,
    DataOperationKind::Get,
    DataOperationKind::Insert,
    DataOperationKind::Update,
    DataOperationKind::Delete,
    DataOperationKind::Upsert,
    DataOperationKind::Aggregate,
    DataOperationKind::Batch,
];

pub struct SqliteEngineAdapter {
    resolver: Arc<dyn MountResolver>,
}

impl SqliteEngineAdapter {
    #[must_use]
    pub fn new(resolver: Arc<dyn MountResolver>) -> Self {
        Self { resolver }
    }
}

#[async_trait]
impl EngineAdapter for SqliteEngineAdapter {
    fn engine(&self) -> &str {
        "sqlite"
    }

    fn capabilities(&self) -> EngineCapabilities {
        EngineCapabilities::sqlite()
    }

    fn supported_ops(&self) -> &'static [DataOperationKind] {
        SUPPORTED_OPS
    }

    async fn open_pool(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>> {
        let dsn = self.resolver.resolve_dsn(&mount).await?;
        let path = sqlite_path(&dsn);
        let cfg = SqliteConfig::new(path);
        let pool = cfg
            .create_pool(Runtime::Tokio1)
            .map_err(|e| DataPlaneError::Backend {
                message: format!("sqlite pool create failed: {e}"),
            })?;

        // Enable WAL + a busy timeout once (WAL persists in the file; the timeout
        // is per-connection but harmless to set here on the first checkout).
        let obj = pool.get().await.map_err(|e| DataPlaneError::Backend {
            message: format!("sqlite checkout failed: {e}"),
        })?;
        obj.interact(|conn| {
            conn.pragma_update(None, "journal_mode", "WAL")?;
            conn.pragma_update(None, "busy_timeout", 5000)?;
            conn.pragma_update(None, "foreign_keys", "ON")
        })
        .await
        .map_err(|e| DataPlaneError::Backend {
            message: format!("sqlite pragma setup failed: {e}"),
        })?
        .map_err(backend)?;

        Ok(Box::new(SqlitePool {
            mount_id: mount.id.clone(),
            tenant_id: mount.tenant_id.clone(),
            owner_scoped: mount.isolation().owner_scoped(),
            pool,
        }))
    }

    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
        Ok(EngineHealth {
            engine: "sqlite".to_string(),
            mount_id: pool.mount_id().to_string(),
            status: "unknown".to_string(),
        })
    }
}

pub struct SqlitePool {
    mount_id: String,
    tenant_id: String,
    /// `true` for `shared_rls` (the default) — every read/write is scoped to the
    /// caller's `owner_id`. `false` for `tenant_owned` (the whole file is one
    /// tenant's, scoped at mount resolution) — no per-row owner predicate.
    owner_scoped: bool,
    pool: Pool,
}

impl SqlitePool {
    fn check_tenant(&self, identity: &RequestIdentity) -> DataPlaneResult<()> {
        if identity.tenant_id != self.tenant_id {
            return Err(DataPlaneError::Backend {
                message: "identity tenant does not match pool tenant".into(),
            });
        }
        Ok(())
    }

    fn owner(&self, identity: &RequestIdentity) -> Option<String> {
        self.owner_scoped.then(|| owner_of(identity))
    }
}

#[async_trait]
impl EnginePool for SqlitePool {
    fn mount_id(&self) -> &str {
        &self.mount_id
    }

    async fn execute(
        &self,
        operation: DataOperation,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        self.check_tenant(&identity)?;
        if !SUPPORTED_OPS.contains(&operation.op) {
            return Err(DataPlaneError::NotImplemented {
                feature: format!("operation {:?} on sqlite", operation.op),
            });
        }
        let owner = self.owner(&identity);

        // Batch runs all sub-ops inside ONE blocking closure wrapped in a tx
        // (atomic): a poison item rolls the whole batch back.
        if operation.op == DataOperationKind::Batch {
            let items = operation
                .batch_items()
                .map_err(|message| DataPlaneError::InvalidRequest { message })?;
            let mut plans: Vec<(SqlPlan, String)> = Vec::with_capacity(items.len());
            for sub in &items {
                let plan = build_plan(sub, owner.as_deref())?;
                plans.push((plan, format!("{:?}", sub.op)));
            }
            let obj = self.checkout().await?;
            let summary = obj
                .interact(move |conn| run_batch(conn, plans))
                .await
                .map_err(|e| DataPlaneError::Backend {
                    message: format!("sqlite batch interact: {e}"),
                })??;
            return Ok(DataResult {
                rows: vec![],
                affected_rows: summary.items.iter().filter(|i| i.status == BatchItemStatus::Ok).count() as u64,
                next_cursor: None,
                batch: Some(summary),
            });
        }

        let plan = build_plan(&operation, owner.as_deref())?;
        let obj = self.checkout().await?;
        obj.interact(move |conn| run_plan(&*conn, &plan))
            .await
            .map_err(|e| DataPlaneError::Backend {
                message: format!("sqlite interact: {e}"),
            })?
    }

    async fn begin(&self, _request: TxBeginRequest) -> DataPlaneResult<Box<dyn TxHandle>> {
        // Honest with the descriptor (transactions:false): a connection-pinned
        // multi-statement transaction is not exposed on SQLite. A single batch
        // is still atomic via `execute`.
        Err(DataPlaneError::NotImplemented {
            feature: "multi-statement transactions on sqlite".to_string(),
        })
    }

    async fn close(&self) -> DataPlaneResult<()> {
        self.pool.close();
        Ok(())
    }

    /// Admin raw-SQL surface (route-gated on `service_role`). Used for DDL and
    /// anything outside the safe CRUD shape. `expect_rows` selects query vs
    /// execute; params bind positionally.
    async fn execute_raw(
        &self,
        statement: RawStatement,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        self.check_tenant(&identity)?;
        let RawStatement { statement: sql, params, expect_rows } = statement;
        let sql_params: Vec<SqlValue> = params.iter().map(json_to_sql).collect();
        let obj = self.checkout().await?;
        obj.interact(move |conn| {
            if expect_rows {
                let rows = query_rows(&*conn, &sql, &sql_params)?;
                let affected = rows.len() as u64;
                Ok(DataResult { rows, affected_rows: affected, next_cursor: None, batch: None })
            } else {
                let affected = exec_write(&*conn, &sql, &sql_params)?;
                Ok(DataResult { rows: vec![], affected_rows: affected, next_cursor: None, batch: None })
            }
        })
        .await
        .map_err(|e| DataPlaneError::Backend {
            message: format!("sqlite raw interact: {e}"),
        })?
    }

    async fn describe_schema(&self, identity: RequestIdentity) -> DataPlaneResult<SchemaDescriptor> {
        self.check_tenant(&identity)?;
        let obj = self.checkout().await?;
        obj.interact(|conn| describe_schema_blocking(&*conn))
            .await
            .map_err(|e| DataPlaneError::Backend {
                message: format!("sqlite introspect interact: {e}"),
            })?
    }
}

impl SqlitePool {
    async fn checkout(&self) -> DataPlaneResult<deadpool_sqlite::Object> {
        self.pool.get().await.map_err(|e| DataPlaneError::Backend {
            message: format!("sqlite checkout failed: {e}"),
        })
    }
}

// ── plan: pure (sql, params) building, no DB access ─────────────────────────

/// A built statement: its SQL, positional params, and whether it returns rows.
struct SqlPlan {
    sql: String,
    params: Vec<SqlValue>,
    returns_rows: bool,
}

fn build_plan(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    match op.op {
        DataOperationKind::List => build_list(op, owner),
        DataOperationKind::Get => build_get(op, owner),
        DataOperationKind::Insert => build_insert(op, owner),
        DataOperationKind::Update => build_update(op, owner),
        DataOperationKind::Delete => build_delete(op, owner),
        DataOperationKind::Upsert => build_upsert(op, owner),
        DataOperationKind::Aggregate => build_aggregate(op, owner),
        DataOperationKind::Batch => Err(DataPlaneError::InvalidRequest {
            message: "nested batch is not allowed".into(),
        }),
    }
}

fn build_list(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    let table = quote_ident(&op.resource)?;
    let (where_sql, params) = build_owner_filter(op.filter.as_ref(), owner)?;
    let order_sql = build_order_by(op.sort.as_ref())?;
    let limit = op.limit.unwrap_or(100).min(500);
    let offset = op.offset.unwrap_or(0);
    Ok(SqlPlan {
        sql: format!("SELECT * FROM {table}{where_sql}{order_sql} LIMIT {limit} OFFSET {offset}"),
        params,
        returns_rows: true,
    })
}

fn build_get(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    let table = quote_ident(&op.resource)?;
    let (where_sql, params) = build_owner_filter(op.filter.as_ref(), owner)?;
    Ok(SqlPlan {
        sql: format!("SELECT * FROM {table}{where_sql} LIMIT 1"),
        params,
        returns_rows: true,
    })
}

fn build_insert(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    let table = quote_ident(&op.resource)?;
    let columns = build_owned_columns(op.data.as_ref(), owner)?;
    if columns.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "insert `data` must not be empty".to_string(),
        });
    }
    let (col_sql, ph, params) = render_columns(&columns)?;
    Ok(SqlPlan {
        sql: format!("INSERT INTO {table} ({col_sql}) VALUES ({ph})"),
        params,
        returns_rows: false,
    })
}

fn build_update(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    let table = quote_ident(&op.resource)?;
    guard_constraining_filter(op.filter.as_ref())?;
    let set_cols = build_safe_columns(op.data.as_ref())?;
    if set_cols.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "update `data` must not be empty".to_string(),
        });
    }
    let mut params: Vec<SqlValue> = Vec::with_capacity(set_cols.len());
    let mut set_parts = Vec::with_capacity(set_cols.len());
    for (col, val) in &set_cols {
        set_parts.push(format!("{} = ?", quote_ident(col)?));
        params.push(json_to_sql(val));
    }
    let (where_sql, mut where_params) = build_owner_filter(op.filter.as_ref(), owner)?;
    params.append(&mut where_params);
    Ok(SqlPlan {
        sql: format!("UPDATE {table} SET {}{where_sql}", set_parts.join(", ")),
        params,
        returns_rows: false,
    })
}

fn build_delete(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    let table = quote_ident(&op.resource)?;
    guard_constraining_filter(op.filter.as_ref())?;
    let (where_sql, params) = build_owner_filter(op.filter.as_ref(), owner)?;
    Ok(SqlPlan {
        sql: format!("DELETE FROM {table}{where_sql}"),
        params,
        returns_rows: false,
    })
}

fn build_upsert(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    let table = quote_ident(&op.resource)?;
    let data = require_object(op.data.as_ref(), "data")?;
    let filter = require_object(op.filter.as_ref(), "filter")?;
    let columns = build_owned_columns(op.data.as_ref(), owner)?;
    if columns.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "upsert `data` must not be empty".to_string(),
        });
    }
    // Conflict target = owner_id (when owner-scoped) + the sorted filter keys.
    // SQLite arbitrates ON CONFLICT at the matching UNIQUE index, BELOW any RLS:
    // a foreign owner's id collision hits the id PRIMARY KEY (an unhandled
    // target) and errors rather than overwriting — the cross-owner guard.
    let mut conflict_cols: Vec<String> = Vec::new();
    if owner.is_some() {
        conflict_cols.push(quote_ident("owner_id")?);
    }
    let mut keys: Vec<&str> = filter
        .keys()
        .map(String::as_str)
        .filter(|k| *k != "owner_id")
        .collect();
    keys.sort_unstable();
    if keys.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "upsert `filter` (conflict key) must not be empty".to_string(),
        });
    }
    for k in &keys {
        conflict_cols.push(quote_ident(k)?);
    }
    let conflict_set: std::collections::BTreeSet<&str> =
        keys.iter().copied().chain(std::iter::once("owner_id")).collect();

    let (col_sql, ph, params) = render_columns(&columns)?;
    // Update every owned column that is NOT part of the conflict target.
    let mut update_parts: Vec<String> = Vec::new();
    for (col, _) in &columns {
        if conflict_set.contains(col.as_str()) {
            continue;
        }
        let q = quote_ident(col)?;
        update_parts.push(format!("{q} = excluded.{q}"));
    }
    let do_clause = if update_parts.is_empty() {
        // Only the key/owner columns were supplied → idempotent no-op on conflict.
        "DO NOTHING".to_string()
    } else {
        format!("DO UPDATE SET {}", update_parts.join(", "))
    };
    let _ = data; // require_object validated shape; columns already built
    Ok(SqlPlan {
        sql: format!(
            "INSERT INTO {table} ({col_sql}) VALUES ({ph}) ON CONFLICT ({}) {do_clause}",
            conflict_cols.join(", ")
        ),
        params,
        returns_rows: false,
    })
}

fn build_aggregate(op: &DataOperation, owner: Option<&str>) -> DataPlaneResult<SqlPlan> {
    let table = quote_ident(&op.resource)?;
    let spec = op.aggregate.as_ref().ok_or_else(|| DataPlaneError::InvalidRequest {
        message: "aggregate requires an `aggregate` spec".to_string(),
    })?;
    if spec.aggregates.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "aggregate requires at least one aggregate function".to_string(),
        });
    }
    let mut seen: std::collections::BTreeSet<&str> = std::collections::BTreeSet::new();
    for name in spec
        .group_by
        .iter()
        .map(String::as_str)
        .chain(spec.aggregates.iter().map(|a| a.alias.as_str()))
    {
        if !seen.insert(name) {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("duplicate aggregate output column '{name}'"),
            });
        }
    }
    let mut select_cols: Vec<String> = Vec::new();
    let mut group_cols: Vec<String> = Vec::new();
    for col in &spec.group_by {
        let ident = quote_ident(col)?;
        select_cols.push(ident.clone());
        group_cols.push(ident);
    }
    for agg in &spec.aggregates {
        select_cols.push(build_aggregate_expr(agg)?);
    }
    let (where_sql, params) = build_owner_filter(op.filter.as_ref(), owner)?;
    let group_sql = if group_cols.is_empty() {
        String::new()
    } else {
        format!(" GROUP BY {}", group_cols.join(", "))
    };
    let order_sql = build_order_by(op.sort.as_ref())?;
    let limit = op.limit.unwrap_or(1000).min(10_000);
    Ok(SqlPlan {
        sql: format!(
            "SELECT {} FROM {table}{where_sql}{group_sql}{order_sql} LIMIT {limit}",
            select_cols.join(", ")
        ),
        params,
        returns_rows: true,
    })
}

fn build_aggregate_expr(agg: &Aggregate) -> DataPlaneResult<String> {
    let alias = quote_ident(&agg.alias)?;
    let func = match agg.func {
        AggFunc::Count => "COUNT",
        AggFunc::Sum => "SUM",
        AggFunc::Avg => "AVG",
        AggFunc::Min => "MIN",
        AggFunc::Max => "MAX",
    };
    let arg = match (&agg.field, agg.func) {
        (Some(field), _) => quote_ident(field)?,
        (None, AggFunc::Count) if !agg.distinct => "*".to_string(),
        (None, _) => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("aggregate '{func}' requires a `field`"),
            })
        }
    };
    if agg.distinct {
        Ok(format!("{func}(DISTINCT {arg}) AS {alias}"))
    } else {
        Ok(format!("{func}({arg}) AS {alias}"))
    }
}

// ── blocking executors (run inside interact, sync rusqlite) ──────────────────

fn run_plan(conn: &Connection, plan: &SqlPlan) -> DataPlaneResult<DataResult> {
    if plan.returns_rows {
        let rows = query_rows(conn, &plan.sql, &plan.params)?;
        let affected = rows.len() as u64;
        Ok(DataResult {
            rows,
            affected_rows: affected,
            next_cursor: None,
            batch: None,
        })
    } else {
        let affected = exec_write(conn, &plan.sql, &plan.params)?;
        Ok(DataResult {
            rows: vec![],
            affected_rows: affected,
            next_cursor: None,
            batch: None,
        })
    }
}

fn run_batch(conn: &mut Connection, plans: Vec<(SqlPlan, String)>) -> DataPlaneResult<BatchSummary> {
    let tx = conn.transaction().map_err(backend)?;
    let mut items: Vec<BatchItemOutcome> = Vec::with_capacity(plans.len());
    for (idx, (plan, _kind)) in plans.iter().enumerate() {
        let res = if plan.returns_rows {
            query_rows(&tx, &plan.sql, &plan.params).map(|_| 0u64)
        } else {
            exec_write(&tx, &plan.sql, &plan.params)
        };
        match res {
            Ok(affected) => items.push(BatchItemOutcome {
                index: idx as u32,
                status: BatchItemStatus::Ok,
                affected_rows: affected,
                error: None,
            }),
            // Atomic contract: the first failure aborts the whole batch. We drop
            // the tx (implicit rollback) and surface the error so `execute`
            // returns Err — nothing in the batch persisted.
            Err(e) => {
                return Err(DataPlaneError::prefix_message(
                    &format!("batch item {idx}: "),
                    e,
                ))
            }
        }
    }
    tx.commit().map_err(backend)?;
    Ok(BatchSummary {
        atomic: true,
        items,
    })
}

fn query_rows(conn: &Connection, sql: &str, params: &[SqlValue]) -> DataPlaneResult<Vec<Value>> {
    let mut stmt = conn.prepare(sql).map_err(backend)?;
    let col_names: Vec<String> = stmt.column_names().into_iter().map(String::from).collect();
    let mapped = stmt
        .query_map(params_from_iter(params.iter()), move |row| {
            let mut obj = JsonMap::with_capacity(col_names.len());
            for (i, name) in col_names.iter().enumerate() {
                obj.insert(name.clone(), sql_to_json(row.get::<_, SqlValue>(i)?));
            }
            Ok(Value::Object(obj))
        })
        .map_err(backend)?;
    let mut out = Vec::new();
    for r in mapped {
        out.push(r.map_err(backend)?);
    }
    Ok(out)
}

fn exec_write(conn: &Connection, sql: &str, params: &[SqlValue]) -> DataPlaneResult<u64> {
    let n = conn
        .execute(sql, params_from_iter(params.iter()))
        .map_err(backend)?;
    Ok(n as u64)
}

fn describe_schema_blocking(conn: &Connection) -> DataPlaneResult<SchemaDescriptor> {
    let mut tables: Vec<TableSchema> = Vec::new();
    let table_names: Vec<String> = {
        let mut stmt = conn
            .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            .map_err(backend)?;
        let names = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(backend)?;
        names.filter_map(Result::ok).collect()
    };
    for table in table_names {
        let mut columns: Vec<ColumnSchema> = Vec::new();
        let mut primary_key: Vec<(i64, String)> = Vec::new();
        let mut stmt = conn
            .prepare(&format!("PRAGMA table_info({})", quote_ident(&table)?))
            .map_err(backend)?;
        let rows = stmt
            .query_map([], |row| {
                let name: String = row.get(1)?;
                let native: String = row.get(2)?;
                let notnull: i64 = row.get(3)?;
                let dflt: Option<String> = row.get(4)?;
                let pk: i64 = row.get(5)?; // 0 = not pk, else 1-based position
                Ok((name, native, notnull == 0, dflt, pk))
            })
            .map_err(backend)?;
        for r in rows {
            let (name, native, nullable, default, pk) = r.map_err(backend)?;
            if pk > 0 {
                primary_key.push((pk, name.clone()));
            }
            let normalized = normalize_sqlite_type(&native);
            columns.push(ColumnSchema {
                name,
                native_type: native,
                normalized_type: normalized,
                nullable,
                default,
                enum_values: None,
                references: None,
                inferred: false,
            });
        }
        primary_key.sort_by_key(|(rank, _)| *rank);
        tables.push(TableSchema {
            name: table,
            primary_key: primary_key.into_iter().map(|(_, n)| n).collect(),
            columns,
        });
    }
    Ok(SchemaDescriptor {
        engine: "sqlite".to_string(),
        tables,
    })
}

fn normalize_sqlite_type(native: &str) -> NormalizedType {
    let t = native.to_ascii_lowercase();
    if t.contains("int") {
        NormalizedType::Integer
    } else if t.contains("char") || t.contains("clob") || t.contains("text") {
        NormalizedType::Text
    } else if t.contains("real") || t.contains("floa") || t.contains("doub") {
        NormalizedType::Float
    } else if t.contains("num") || t.contains("dec") {
        NormalizedType::Decimal
    } else if t.contains("bool") {
        NormalizedType::Boolean
    } else if t.contains("blob") {
        NormalizedType::Unknown
    } else if t.contains("date") || t.contains("time") {
        NormalizedType::Datetime
    } else {
        NormalizedType::Unknown
    }
}

// ── pure helpers (owner scope, filter lowering, columns) ─────────────────────

fn owner_of(identity: &RequestIdentity) -> String {
    identity
        .user_id
        .clone()
        .unwrap_or_else(|| identity.tenant_id.clone())
}

/// `WHERE` clause that intersects the (reserved-stripped) client filter with the
/// trusted `owner_id` predicate. `owner: None` (tenant_owned) emits the client
/// filter only — but still requires a `WHERE` to avoid an unscoped statement
/// when a filter is present; an absent filter yields an empty clause (caller
/// guards mass mutations separately).
fn build_owner_filter(
    filter: Option<&Value>,
    owner: Option<&str>,
) -> DataPlaneResult<(String, Vec<SqlValue>)> {
    let mut params: Vec<SqlValue> = Vec::new();
    let mut clauses: Vec<String> = Vec::new();
    if let Some(filter_value) = filter {
        let cleaned = strip_reserved_top_level(filter_value);
        let tree = Filter::parse(&cleaned)?;
        if let Some(sql) = lower_filter(&tree, &mut params)? {
            clauses.push(format!("({sql})"));
        }
    }
    if let Some(owner) = owner {
        params.push(SqlValue::Text(owner.to_string()));
        clauses.push("\"owner_id\" = ?".to_string());
    }
    if clauses.is_empty() {
        Ok((String::new(), params))
    } else {
        Ok((format!(" WHERE {}", clauses.join(" AND ")), params))
    }
}

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

fn lower_filter(filter: &Filter, params: &mut Vec<SqlValue>) -> DataPlaneResult<Option<String>> {
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
            Some(if sqls.is_empty() {
                "0 = 1".to_string()
            } else {
                sqls.join(" OR ")
            })
        }
        Filter::Not(inner) => lower_filter(inner, params)?.map(|s| format!("NOT ({s})")),
        Filter::Cmp { field, op, value } => {
            let q = quote_ident(field)?;
            params.push(json_to_sql(value));
            Some(format!("{q} {} ?", cmp_op_sql(*op)))
        }
        Filter::In { field, values } => {
            let q = quote_ident(field)?;
            if values.is_empty() {
                Some("0 = 1".to_string())
            } else {
                let mut ph = Vec::with_capacity(values.len());
                for v in values {
                    params.push(json_to_sql(v));
                    ph.push("?");
                }
                Some(format!("{q} IN ({})", ph.join(", ")))
            }
        }
        Filter::Like { field, pattern, ci } => {
            let q = quote_ident(field)?;
            params.push(json_to_sql(pattern));
            // SQLite LIKE is case-insensitive for ASCII by default; force the
            // case-sensitive form with LOWER() when the client asked for ci.
            Some(if *ci {
                format!("LOWER({q}) LIKE LOWER(?)")
            } else {
                format!("{q} LIKE ?")
            })
        }
        Filter::Between { field, low, high } => {
            let q = quote_ident(field)?;
            params.push(json_to_sql(low));
            params.push(json_to_sql(high));
            Some(format!("{q} BETWEEN ? AND ?"))
        }
        Filter::IsNull { field, negate } => {
            let q = quote_ident(field)?;
            Some(format!("{q} IS {}NULL", if *negate { "NOT " } else { "" }))
        }
    })
}

/// INSERT/UPSERT column set: strip reserved client columns, re-inject the
/// trusted `owner_id` when owner-scoped.
fn build_owned_columns(
    data: Option<&Value>,
    owner: Option<&str>,
) -> DataPlaneResult<Vec<(String, Value)>> {
    let map = require_object(data, "data")?;
    let mut columns: Vec<(String, Value)> = Vec::with_capacity(map.len() + 1);
    for (col, val) in map {
        if RESERVED_COLUMNS.contains(&col.as_str()) {
            continue;
        }
        columns.push((col.clone(), val.clone()));
    }
    if let Some(owner) = owner {
        columns.push(("owner_id".to_string(), Value::String(owner.to_string())));
    }
    Ok(columns)
}

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

/// Render `(col, col, …)`, `(?, ?, …)` and the matching param vector.
fn render_columns(
    columns: &[(String, Value)],
) -> DataPlaneResult<(String, String, Vec<SqlValue>)> {
    let mut col_sql = Vec::with_capacity(columns.len());
    let mut ph = Vec::with_capacity(columns.len());
    let mut params = Vec::with_capacity(columns.len());
    for (col, val) in columns {
        col_sql.push(quote_ident(col)?);
        ph.push("?".to_string());
        params.push(json_to_sql(val));
    }
    Ok((col_sql.join(", "), ph.join(", "), params))
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
        let dir_sql = if dir.eq_ignore_ascii_case("desc") { "DESC" } else { "ASC" };
        parts.push(format!("{} {dir_sql}", quote_ident(col)?));
    }
    Ok(format!(" ORDER BY {}", parts.join(", ")))
}

fn require_object<'a>(data: Option<&'a Value>, what: &str) -> DataPlaneResult<&'a JsonMap<String, Value>> {
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

/// SQLite identifier quoting (`"col"`). Rejects identifiers containing a double
/// quote, NUL, or control chars so a crafted field name can't break out.
fn quote_ident(ident: &str) -> DataPlaneResult<String> {
    if ident.is_empty()
        || ident.len() > 128
        || ident.contains('"')
        || ident.contains('\0')
        || ident.chars().any(char::is_control)
    {
        return Err(DataPlaneError::InvalidIdentifier {
            value: ident.to_string(),
        });
    }
    Ok(format!("\"{ident}\""))
}

fn json_to_sql(value: &Value) -> SqlValue {
    match value {
        Value::Null => SqlValue::Null,
        Value::Bool(b) => SqlValue::Integer(i64::from(*b)),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                SqlValue::Integer(i)
            } else if let Some(f) = n.as_f64() {
                SqlValue::Real(f)
            } else {
                SqlValue::Null
            }
        }
        Value::String(s) => SqlValue::Text(s.clone()),
        // Arrays / objects are stored as their JSON text (SQLite has no native
        // composite types); reads return them as a string.
        other => SqlValue::Text(other.to_string()),
    }
}

fn sql_to_json(value: SqlValue) -> Value {
    match value {
        SqlValue::Null => Value::Null,
        SqlValue::Integer(i) => Value::Number(i.into()),
        SqlValue::Real(f) => serde_json::Number::from_f64(f).map_or(Value::Null, Value::Number),
        SqlValue::Text(s) => Value::String(s),
        SqlValue::Blob(b) => Value::String(format!("blob:{} bytes", b.len())),
    }
}

/// Classify a rusqlite error into the right client/server bucket: a constraint
/// violation (UNIQUE/PK/FK/NOT NULL/CHECK) is a 409 Conflict; everything else a
/// 502 Backend.
fn backend(e: rusqlite::Error) -> DataPlaneError {
    let msg = e.to_string();
    let lower = msg.to_ascii_lowercase();
    if lower.contains("unique constraint")
        || lower.contains("constraint failed")
        || lower.contains("not null")
        || lower.contains("foreign key")
    {
        DataPlaneError::Conflict {
            message: format!("sqlite constraint: {msg}"),
        }
    } else {
        DataPlaneError::Backend {
            message: format!("sqlite backend: {msg}"),
        }
    }
}

/// Parse a `sqlite:` DSN to a file path (or `:memory:`).
fn sqlite_path(dsn: &str) -> String {
    let s = dsn
        .strip_prefix("sqlite://")
        .or_else(|| dsn.strip_prefix("sqlite:"))
        .unwrap_or(dsn);
    if s.is_empty() || s == ":memory:" {
        ":memory:".to_string()
    } else {
        s.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dsn_parsing() {
        assert_eq!(sqlite_path("sqlite:///var/lib/x.db"), "/var/lib/x.db");
        assert_eq!(sqlite_path("sqlite::memory:"), ":memory:");
        assert_eq!(sqlite_path("sqlite://"), ":memory:");
        assert_eq!(sqlite_path("/abs/path.db"), "/abs/path.db");
    }

    #[test]
    fn ident_quoting_rejects_injection() {
        assert_eq!(quote_ident("name").unwrap(), "\"name\"");
        assert!(quote_ident("a\"; DROP TABLE x; --").is_err());
        assert!(quote_ident("").is_err());
    }

    #[test]
    fn owner_filter_always_scopes_when_owner_present() {
        let (sql, params) = build_owner_filter(Some(&serde_json::json!({"id": "x"})), Some("u1")).unwrap();
        assert!(sql.contains("\"owner_id\" = ?"), "{sql}");
        assert_eq!(params.len(), 2);
    }
}
