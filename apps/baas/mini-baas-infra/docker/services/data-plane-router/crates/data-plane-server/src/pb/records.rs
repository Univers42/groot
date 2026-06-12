//! PB records API: `/api/collections/{collection}/records[...]`.
//!
//! List/view/create/update/delete in PB envelopes over the native engine.
//! Row shaping is TYPE-AWARE: SQLite hands back 0/1 for bools and TEXT for
//! json/multi-value fields — the facade renders what PB renders (real
//! booleans, parsed json, arrays for multi-select/file/relation, zero values
//! for NULL: `""`/`0`/`false`/`[]`).
//!
//! Access model at this phase: a NULL rule = superuser-only and `""` =
//! public — exactly PB's lock semantics. Non-empty rule STRINGS (the filter
//! expressions) are enforced by the Phase K rules engine; until it lands
//! they fail CLOSED (treated as locked) rather than silently allowing.

use axum::extract::{Path, Query, State};
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use data_plane_core::{DataOperation, DataOperationKind};
use serde_json::{json, Map as JsonMap, Value};
use std::collections::HashMap;

use super::collections::Collection;
use super::{exec, pb_auth, pb_err, pb_id, pb_now, pb_of, PbAuth};
use crate::routes::AppState;

// ─── access rules (J-phase subset; K replaces with the full engine) ─────────

enum Rule<'a> {
    Locked,
    Public,
    /// The rule expression — evaluated by the Phase K rules engine; until
    /// then `Expr` fails closed (see `allowed`).
    #[allow(dead_code)]
    Expr(&'a str),
}

fn rule_of(raw: Option<&String>) -> Rule<'_> {
    match raw {
        None => Rule::Locked,
        Some(s) if s.trim().is_empty() => Rule::Public,
        Some(s) => Rule::Expr(s),
    }
}

/// Resolve the caller + their auth record once per request (rule context).
async fn caller(
    state: &AppState,
    headers: &header::HeaderMap,
) -> (PbAuth, super::rules::RuleCtx) {
    let auth = pb_auth(state, headers);
    let record = super::auth::auth_record_of(state, &auth).await;
    let ctx = super::rules::RuleCtx::from_auth(&auth, record);
    (auth, ctx)
}

/// Apply a lowered rule to a query op. Returns Err(response) for Deny;
/// Ok(true) = proceed, Ok(false) = rule can never match (caller handles).
fn apply_rule(
    op: &mut DataOperation,
    lowered: super::rules::Lowered,
) -> Result<bool, axum::response::Response> {
    use super::rules::Lowered::*;
    match lowered {
        Open => Ok(true),
        Constrain(extra) => {
            op.filter = Some(super::rules::and_filters(op.filter.take(), extra));
            Ok(true)
        }
        Never => Ok(false),
        Deny => Err(pb_err(
            StatusCode::FORBIDDEN,
            "Only superusers can perform this action.",
        )),
    }
}

// ─── type-aware row shaping ──────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq)]
enum FieldKind {
    Text,
    Number,
    Bool,
    Json,
    Multi, // select/file/relation with maxSelect > 1 → JSON array in TEXT
    Single,
    Autodate, // server-stamped datetime; renders as text
    Password, // argon2id hash column; write-only
}

fn field_kinds(col: &Collection) -> HashMap<String, FieldKind> {
    let mut map = HashMap::new();
    if let Some(fields) = col.fields.as_array() {
        for f in fields {
            let name = f.get("name").and_then(|v| v.as_str()).unwrap_or_default();
            let ftype = f.get("type").and_then(|v| v.as_str()).unwrap_or_default();
            let max_select = f.get("maxSelect").and_then(Value::as_i64).unwrap_or(1);
            let kind = match ftype {
                "number" => FieldKind::Number,
                "bool" => FieldKind::Bool,
                "json" | "geoPoint" => FieldKind::Json,
                "select" | "file" | "relation" if max_select > 1 => FieldKind::Multi,
                "select" | "file" | "relation" => FieldKind::Single,
                "autodate" => FieldKind::Autodate,
                "password" => FieldKind::Password,
                _ => FieldKind::Text,
            };
            map.insert(name.to_string(), kind);
        }
    }
    map
}

/// Declared autodate fields → (name, onCreate, onUpdate). PB stamps these
/// server-side; clients can never set them.
fn autodates(col: &Collection) -> Vec<(String, bool, bool)> {
    col.fields
        .as_array()
        .map(|fields| {
            fields
                .iter()
                .filter(|f| f.get("type").and_then(|v| v.as_str()) == Some("autodate"))
                .filter_map(|f| {
                    let name = f.get("name").and_then(|v| v.as_str())?;
                    let on_create = f.get("onCreate").and_then(Value::as_bool).unwrap_or(true);
                    let on_update = f.get("onUpdate").and_then(Value::as_bool).unwrap_or(false);
                    Some((name.to_string(), on_create, on_update))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Engine row → PB record (typed values, zero defaults, collection stamps).
fn shape_record(col: &Collection, kinds: &HashMap<String, FieldKind>, row: &Value) -> Value {
    let mut out = JsonMap::new();
    out.insert("collectionId".into(), json!(col.id));
    out.insert("collectionName".into(), json!(col.name));
    let empty = JsonMap::new();
    let row_map = row.as_object().unwrap_or(&empty);
    for (name, kind) in kinds {
        let stored = row_map.get(name).cloned().unwrap_or(Value::Null);
        let shaped = match kind {
            FieldKind::Number => match stored {
                Value::Number(n) => Value::Number(n),
                Value::Null => json!(0),
                other => other,
            },
            FieldKind::Bool => match stored {
                Value::Number(n) => Value::Bool(n.as_i64().unwrap_or(0) != 0),
                Value::Bool(b) => Value::Bool(b),
                _ => Value::Bool(false),
            },
            FieldKind::Json => match &stored {
                Value::String(s) => serde_json::from_str(s).unwrap_or(Value::Null),
                Value::Null => Value::Null,
                other => other.clone(),
            },
            FieldKind::Multi => match &stored {
                Value::String(s) => serde_json::from_str(s).unwrap_or_else(|_| json!([])),
                Value::Null => json!([]),
                other => other.clone(),
            },
            FieldKind::Single | FieldKind::Text | FieldKind::Autodate => match stored {
                Value::Null => json!(""),
                other => other,
            },
            FieldKind::Password => continue, // write-only, never serialized
        };
        out.insert(name.clone(), shaped);
    }
    Value::Object(out)
}

/// Request body → engine data: keep only declared fields, lower typed values
/// to their storage form (bool→0/1 handled by the driver; json/multi →
/// canonical TEXT). Unknown keys are ignored, like PB.
fn lower_body(
    kinds: &HashMap<String, FieldKind>,
    body: &Value,
) -> Result<JsonMap<String, Value>, String> {
    let mut out = JsonMap::new();
    let Some(map) = body.as_object() else {
        return Err("body must be a JSON object".into());
    };
    for (k, v) in map {
        let Some(kind) = kinds.get(k.as_str()) else {
            continue;
        };
        if matches!(kind, FieldKind::Autodate | FieldKind::Password) {
            continue; // server-managed (stamped / hashed), never raw client input
        }
        let lowered = match kind {
            FieldKind::Json | FieldKind::Multi => match v {
                Value::Null => Value::Null,
                other => Value::String(other.to_string()),
            },
            _ => v.clone(),
        };
        out.insert(k.clone(), lowered);
    }
    Ok(out)
}

// ─── query params ────────────────────────────────────────────────────────────

/// `?sort=-created,name` → ordered (column, direction) pairs. `@random` and
/// `@rowid` are PB specials; `@random` has no stable PB-faithful lowering in
/// the shared op (and PB documents it as random) — lowered to rowid for now.
fn parse_sort(raw: &str, kinds: &HashMap<String, FieldKind>) -> Result<Vec<(String, String)>, String> {
    let mut out = Vec::new();
    for part in raw.split(',').map(str::trim).filter(|p| !p.is_empty()) {
        let (dir, name) = match part.strip_prefix('-') {
            Some(rest) => ("desc", rest),
            None => ("asc", part.strip_prefix('+').unwrap_or(part)),
        };
        let column = match name {
            "@rowid" | "@random" => "rowid".to_string(),
            "id" => name.to_string(),
            other if kinds.contains_key(other) => other.to_string(),
            other => return Err(format!("unknown sort field '{other}'")),
        };
        out.push((column, dir.to_string()));
    }
    Ok(out)
}

/// Public alias for sibling modules (auth) that build raw ops.
pub(crate) fn base_op_pub(kind: DataOperationKind, resource: &str) -> DataOperation {
    base_op(kind, resource)
}

fn base_op(kind: DataOperationKind, resource: &str) -> DataOperation {
    DataOperation {
        op: kind,
        resource: resource.to_string(),
        data: None,
        filter: None,
        sort: None,
        limit: None,
        offset: None,
        idempotency_key: None,
        expected_version: None,
        returning: None,
        aggregate: None,
        fields: None,
        sort_order: None,
    }
}

/// Translate `?filter=` via the PB DSL parser into the engine filter wire
/// shape (the engine re-validates; this just bridges grammars).
fn filter_wire(raw: &str) -> Result<Option<Value>, String> {
    if raw.trim().is_empty() {
        return Ok(None);
    }
    let ast = super::filter::parse_pb_filter(raw)?;
    Ok(Some(filter_to_wire(&ast)))
}

pub(crate) fn filter_to_wire(f: &data_plane_core::Filter) -> Value {
    use data_plane_core::{CmpOp, Filter};
    match f {
        Filter::And(parts) => json!({ "$and": parts.iter().map(filter_to_wire).collect::<Vec<_>>() }),
        Filter::Or(parts) => json!({ "$or": parts.iter().map(filter_to_wire).collect::<Vec<_>>() }),
        Filter::Not(inner) => json!({ "$not": filter_to_wire(inner) }),
        Filter::Cmp { field, op, value } => {
            let key = match op {
                CmpOp::Eq => "$eq",
                CmpOp::Ne => "$ne",
                CmpOp::Lt => "$lt",
                CmpOp::Lte => "$lte",
                CmpOp::Gt => "$gt",
                CmpOp::Gte => "$gte",
            };
            json!({ field: { key: value } })
        }
        Filter::In { field, values } => json!({ field: { "$in": values } }),
        Filter::Like { field, pattern, ci } => {
            let key = if *ci { "$ilike" } else { "$like" };
            json!({ field: { key: pattern } })
        }
        Filter::Between { field, low, high } => json!({ field: { "$between": [low, high] } }),
        Filter::IsNull { field, negate } => json!({ field: { "$null": !negate } }),
    }
}

// ─── batch bridge (used by pb::batch) ───────────────────────────────────────

/// One planned batch sub-request: the lowered native op + what to re-fetch.
pub(crate) struct BatchPlan {
    pub op: DataOperation,
    pub collection: String,
    pub record_id: String,
}

/// Parse a PB batch sub-request (`method` + `/api/collections/{c}/records
/// [/{id}]` + body) into a ready native operation, enforcing the same rules
/// and lowering as the live handlers.
pub(crate) fn record_for_batch(
    pb: &super::PbState,
    _state: &AppState,
    _headers: &header::HeaderMap,
    superuser: bool,
    method: &str,
    url: &str,
    body: &Value,
) -> Result<BatchPlan, String> {
    let path = url.split('?').next().unwrap_or(url);
    let parts: Vec<&str> = path.trim_matches('/').split('/').collect();
    // api / collections / {c} / records [ / {id} ]
    if parts.len() < 4 || parts[0] != "api" || parts[1] != "collections" || parts[3] != "records" {
        return Err(format!("unsupported batch url '{url}'"));
    }
    let cname = parts[2];
    let rid = parts.get(4).map(|s| s.to_string());
    let Some(col) = pb.col_get(cname) else {
        return Err(format!("collection '{cname}' not found"));
    };
    let kinds = field_kinds(&col);
    // Batch v1 honors public/locked; expression rules in batch arrive with
    // the Phase L hardening pass (documented limitation, fails CLOSED).
    let pass = |raw: &Option<String>| match rule_of(raw.as_ref()) {
        Rule::Public => true,
        _ => superuser,
    };
    let now = pb_now();
    match (method.to_ascii_uppercase().as_str(), rid) {
        ("POST", None) => {
            if !pass(&col.create_rule) {
                return Err("not allowed to create here".into());
            }
            let mut data = lower_body(&kinds, body)?;
            let id = body
                .get("id")
                .and_then(|v| v.as_str())
                .filter(|s| s.len() == 15)
                .map(String::from)
                .unwrap_or_else(super::pb_id);
            data.insert("id".into(), json!(id));
            for (name, on_create, _) in autodates(&col) {
                if on_create {
                    data.insert(name, json!(now));
                }
            }
            let mut op = base_op(DataOperationKind::Insert, &col.name);
            op.data = Some(Value::Object(data));
            Ok(BatchPlan { op, collection: col.name.clone(), record_id: id })
        }
        ("PATCH", Some(id)) => {
            if !pass(&col.update_rule) {
                return Err("not allowed to update here".into());
            }
            let mut data = lower_body(&kinds, body)?;
            for (name, _, on_update) in autodates(&col) {
                if on_update {
                    data.insert(name, json!(now.clone()));
                }
            }
            if data.is_empty() {
                return Err("empty update body".into());
            }
            let mut op = base_op(DataOperationKind::Update, &col.name);
            op.data = Some(Value::Object(data));
            op.filter = Some(json!({ "id": id }));
            Ok(BatchPlan { op, collection: col.name.clone(), record_id: id })
        }
        ("DELETE", Some(id)) => {
            if !pass(&col.delete_rule) {
                return Err("not allowed to delete here".into());
            }
            let mut op = base_op(DataOperationKind::Delete, &col.name);
            op.filter = Some(json!({ "id": id }));
            Ok(BatchPlan { op, collection: col.name.clone(), record_id: id })
        }
        (m, r) => Err(format!("unsupported batch op {m} (id: {r:?})")),
    }
}

/// Shaped record by collection NAME + id (post-commit re-fetch for batch).
pub(crate) async fn fetch_shaped(
    state: &AppState,
    collection: &str,
    id: &str,
) -> Result<Option<Value>, axum::response::Response> {
    let pb = pb_of(state)?;
    let Some(col) = pb.col_get(collection) else {
        return Ok(None);
    };
    let kinds = field_kinds(&col);
    fetch_by_id(state, &col, &kinds, id).await
}

/// Fan a record event to PB realtime subscribers. `public` mirrors the
/// collection's view rule at this phase.
fn publish_event(state: &AppState, col: &Collection, action: &str, record: &Value) {
    let Ok(pb) = pb_of(state) else { return };
    let rid = record
        .get("id")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    let public = matches!(rule_of(col.view_rule.as_ref()), Rule::Public);
    pb.realtime
        .publish(&[col.name.as_str(), col.id.as_str()], &rid, action, record, public);
}


// ─── request-body extraction (JSON or multipart) ─────────────────────────────

/// Buffered upload: (file-field name, original filename, bytes).
type PendingFiles = Vec<(String, String, Vec<u8>)>;

/// Read a record payload from either JSON or multipart/form-data (the shape
/// the official SDK sends when a body contains File/Blob values). Multipart
/// text fields are coerced by their declared field kind (number/bool/json);
/// repeated keys accumulate (multi-select). File parts are buffered and
/// persisted by the caller once the record id is settled.
async fn extract_body(
    kinds: &HashMap<String, FieldKind>,
    headers: &header::HeaderMap,
    request: axum::extract::Request,
    state: &AppState,
) -> Result<(Value, PendingFiles), axum::response::Response> {
    let content_type = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
        .to_string();
    if content_type.starts_with("multipart/form-data") {
        use axum::extract::FromRequest;
        let mut multipart = axum::extract::Multipart::from_request(request, state)
            .await
            .map_err(|_| pb_err(StatusCode::BAD_REQUEST, "malformed multipart body"))?;
        let mut map = JsonMap::new();
        let mut files: PendingFiles = Vec::new();
        let mut total: usize = 0;
        while let Ok(Some(field)) = multipart.next_field().await {
            let name = field.name().unwrap_or_default().to_string();
            if name == "@jsonPayload" {
                if let Ok(text) = field.text().await {
                    if let Ok(Value::Object(extra)) = serde_json::from_str::<Value>(&text) {
                        for (k, v) in extra {
                            map.insert(k, v);
                        }
                    }
                }
                continue;
            }
            let is_file = field.file_name().is_some();
            if is_file {
                let original = field.file_name().unwrap_or("file").to_string();
                let bytes = field
                    .bytes()
                    .await
                    .map_err(|_| pb_err(StatusCode::BAD_REQUEST, "unreadable file part"))?;
                total += bytes.len();
                if total > 64 * 1024 * 1024 {
                    return Err(pb_err(StatusCode::PAYLOAD_TOO_LARGE, "upload too large"));
                }
                files.push((name, original, bytes.to_vec()));
                continue;
            }
            let text = field.text().await.unwrap_or_default();
            let coerced = match kinds.get(name.as_str()) {
                Some(FieldKind::Number) => text
                    .parse::<f64>()
                    .ok()
                    .and_then(serde_json::Number::from_f64)
                    .map(Value::Number)
                    .unwrap_or(Value::Null),
                Some(FieldKind::Bool) => {
                    Value::Bool(matches!(text.as_str(), "true" | "1" | "on"))
                }
                Some(FieldKind::Json) => {
                    serde_json::from_str(&text).unwrap_or(Value::String(text))
                }
                _ => Value::String(text),
            };
            match map.get_mut(&name) {
                Some(Value::Array(arr)) => arr.push(coerced),
                Some(prev) => {
                    let first = prev.clone();
                    map.insert(name, Value::Array(vec![first, coerced]));
                }
                None => {
                    map.insert(name, coerced);
                }
            }
        }
        Ok((Value::Object(map), files))
    } else {
        let bytes = axum::body::to_bytes(request.into_body(), 16 * 1024 * 1024)
            .await
            .map_err(|_| pb_err(StatusCode::BAD_REQUEST, "unreadable body"))?;
        let v = if bytes.is_empty() {
            json!({})
        } else {
            serde_json::from_slice(&bytes)
                .map_err(|_| pb_err(StatusCode::BAD_REQUEST, "invalid JSON body"))?
        };
        Ok((v, Vec::new()))
    }
}

/// Write buffered uploads under `{storage}/{col id}/{record id}/` and fold
/// the stored names into `data` (single file field = string, multi = array).
async fn persist_files(
    pb: &super::PbState,
    kinds: &HashMap<String, FieldKind>,
    col_id: &str,
    record_id: &str,
    files: PendingFiles,
    data: &mut JsonMap<String, Value>,
) -> Result<(), axum::response::Response> {
    if files.is_empty() {
        return Ok(());
    }
    let dir = pb.storage_root.join(col_id).join(record_id);
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|_| pb_err(StatusCode::INTERNAL_SERVER_ERROR, "storage unavailable"))?;
    for (field, original, bytes) in files {
        if !matches!(kinds.get(field.as_str()), Some(FieldKind::Single | FieldKind::Multi)) {
            continue; // not a declared file-capable field — ignored like unknown keys
        }
        let stored = super::files::stored_name(&original);
        tokio::fs::write(dir.join(&stored), &bytes)
            .await
            .map_err(|_| pb_err(StatusCode::INTERNAL_SERVER_ERROR, "could not persist the file"))?;
        match kinds.get(field.as_str()) {
            Some(FieldKind::Multi) => match data.get_mut(&field) {
                Some(Value::String(prev)) if prev.starts_with('[') => {
                    let mut arr: Vec<Value> =
                        serde_json::from_str(prev).unwrap_or_default();
                    arr.push(json!(stored));
                    data.insert(field, Value::String(Value::Array(arr).to_string()));
                }
                _ => {
                    data.insert(field, Value::String(json!([stored]).to_string()));
                }
            },
            _ => {
                data.insert(field, Value::String(stored));
            }
        }
    }
    Ok(())
}

// ─── handlers ────────────────────────────────────────────────────────────────

fn load_collection(
    state: &AppState,
    name: &str,
) -> Result<(Collection, HashMap<String, FieldKind>), axum::response::Response> {
    let pb = pb_of(state)?;
    let Some(col) = pb.col_get(name) else {
        return Err(pb_err(StatusCode::NOT_FOUND, "collection not found"));
    };
    let kinds = field_kinds(&col);
    Ok((col, kinds))
}

/// GET /api/collections/{c}/records — PB list envelope.
async fn list(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path(cname): Path<String>,
    Query(q): Query<HashMap<String, String>>,
) -> axum::response::Response {
    let (col, kinds) = match load_collection(&state, &cname) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let (_auth, ctx) = caller(&state, &headers).await;
    let lowered = super::rules::lower_rule(col.list_rule.as_ref(), &ctx);
    let page: u32 = q.get("page").and_then(|v| v.parse().ok()).unwrap_or(1).max(1);
    let per_page: u32 = q
        .get("perPage")
        .and_then(|v| v.parse().ok())
        .unwrap_or(30)
        .clamp(1, 1000);
    let skip_total = matches!(q.get("skipTotal").map(String::as_str), Some("1" | "true"));

    let mut op = base_op(DataOperationKind::List, &col.name);
    op.limit = Some(per_page);
    op.offset = Some((page - 1) * per_page);
    if let Some(raw) = q.get("filter") {
        match filter_wire(raw) {
            Ok(f) => op.filter = f,
            Err(m) => return pb_err(StatusCode::BAD_REQUEST, &m),
        }
    }
    if let Some(raw) = q.get("sort") {
        match parse_sort(raw, &kinds) {
            Ok(s) if !s.is_empty() => op.sort_order = Some(s),
            Ok(_) => {}
            Err(m) => return pb_err(StatusCode::BAD_REQUEST, &m),
        }
    }
    let matchable = match apply_rule(&mut op, lowered) {
        Ok(m) => m,
        Err(r) => return r,
    };
    if !matchable {
        return (
            StatusCode::OK,
            Json(json!({ "page": page, "perPage": per_page, "totalItems": 0,
                          "totalPages": 0, "items": [] })),
        )
            .into_response();
    }
    let filter_for_count = op.filter.clone();
    let result = match exec(&state, op).await {
        Ok(r) => r,
        Err(r) => return r,
    };
    let su = ctx.superuser;
    let self_id = ctx
        .auth
        .as_ref()
        .and_then(|a| a.get("id"))
        .and_then(Value::as_str)
        .map(String::from);
    let items: Vec<Value> = result
        .rows
        .iter()
        .map(|r| {
            let mut rec = shape_record(&col, &kinds, r);
            if col.kind == "auth" {
                let is_self = self_id.as_deref()
                    == rec.get("id").and_then(Value::as_str);
                super::auth::scrub_auth_record(&mut rec, su || is_self);
            }
            rec
        })
        .collect();

    let (total_items, total_pages) = if skip_total {
        (-1i64, -1i64)
    } else {
        let mut count_op = base_op(DataOperationKind::Aggregate, &col.name);
        count_op.filter = filter_for_count;
        count_op.aggregate = Some(data_plane_core::AggregateSpec {
            group_by: vec![],
            aggregates: vec![data_plane_core::Aggregate {
                func: data_plane_core::AggFunc::Count,
                field: None,
                distinct: false,
                alias: "n".to_string(),
            }],
        });
        match exec(&state, count_op).await {
            Ok(r) => {
                let n = r
                    .rows
                    .first()
                    .and_then(|row| row.get("n"))
                    .and_then(Value::as_i64)
                    .unwrap_or(0);
                (n, (n + per_page as i64 - 1) / per_page as i64)
            }
            Err(r) => return r,
        }
    };

    (
        StatusCode::OK,
        Json(json!({
            "page": page,
            "perPage": per_page,
            "totalItems": total_items,
            "totalPages": total_pages,
            "items": items,
        })),
    )
        .into_response()
}

async fn fetch_by_id(
    state: &AppState,
    col: &Collection,
    kinds: &HashMap<String, FieldKind>,
    id: &str,
) -> Result<Option<Value>, axum::response::Response> {
    let mut op = base_op(DataOperationKind::Get, &col.name);
    op.filter = Some(json!({ "id": id }));
    let result = exec(state, op).await?;
    Ok(result.rows.first().map(|r| shape_record(col, kinds, r)))
}

/// GET /api/collections/{c}/records/{id}
async fn view(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path((cname, rid)): Path<(String, String)>,
) -> axum::response::Response {
    let (col, kinds) = match load_collection(&state, &cname) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let (_auth, ctx) = caller(&state, &headers).await;
    let mut op = base_op(DataOperationKind::Get, &col.name);
    op.filter = Some(json!({ "id": rid }));
    match apply_rule(&mut op, super::rules::lower_rule(col.view_rule.as_ref(), &ctx)) {
        Ok(true) => {}
        Ok(false) => return pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found."),
        Err(r) => return r,
    }
    match exec(&state, op).await.map(|r| r.rows.first().map(|row| shape_record(&col, &kinds, row))) {
        Ok(Some(mut rec)) => {
            if col.kind == "auth" {
                let su = ctx.superuser;
                let is_self = ctx
                    .auth
                    .as_ref()
                    .and_then(|a| a.get("id"))
                    .and_then(Value::as_str)
                    == rec.get("id").and_then(Value::as_str);
                super::auth::scrub_auth_record(&mut rec, su || is_self);
            }
            (StatusCode::OK, Json(rec)).into_response()
        }
        Ok(None) => pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found."),
        Err(r) => r,
    }
}

/// POST /api/collections/{c}/records
async fn create(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path(cname): Path<String>,
    request: axum::extract::Request,
) -> axum::response::Response {
    let (col, kinds) = match load_collection(&state, &cname) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let (_auth, ctx) = caller(&state, &headers).await;
    let create_rule = super::rules::lower_rule(col.create_rule.as_ref(), &ctx);
    if matches!(create_rule, super::rules::Lowered::Deny) {
        return pb_err(StatusCode::FORBIDDEN, "Only superusers can perform this action.");
    }
    if matches!(create_rule, super::rules::Lowered::Never) {
        return pb_err(StatusCode::BAD_REQUEST, "Failed to create record.");
    }
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let (body, pending) = match extract_body(&kinds, &headers, request, &state).await {
        Ok(v) => v,
        Err(r) => return r,
    };
    let mut data = match lower_body(&kinds, &body) {
        Ok(d) => d,
        Err(m) => return pb_err(StatusCode::BAD_REQUEST, &m),
    };
    // Auth collections: validate + hash the password server-side.
    if col.kind == "auth" {
        let password = body.get("password").and_then(|v| v.as_str()).unwrap_or_default();
        let confirm = body.get("passwordConfirm").and_then(|v| v.as_str()).unwrap_or_default();
        if password.len() < 8 || password != confirm {
            return pb_err(StatusCode::BAD_REQUEST, "invalid or unconfirmed password");
        }
        let email = body.get("email").and_then(|v| v.as_str()).unwrap_or_default().trim().to_lowercase();
        if email.is_empty() || !email.contains('@') {
            return pb_err(StatusCode::BAD_REQUEST, "invalid email");
        }
        let pw = password.to_string();
        let hash = match crate::one::kdf_blocking(move || crate::one::hash_password(&pw)).await {
            Some(Ok(h)) => h,
            _ => return pb_err(StatusCode::INTERNAL_SERVER_ERROR, "password hashing failed"),
        };
        data.insert("email".into(), json!(email));
        data.insert("password".into(), json!(hash));
    }
    let id = body
        .get("id")
        .and_then(|v| v.as_str())
        .filter(|s| s.len() == 15 && s.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()))
        .map(String::from)
        .unwrap_or_else(pb_id);
    let now = pb_now();
    data.insert("id".into(), json!(id));
    for (name, on_create, _) in autodates(&col) {
        if on_create {
            data.insert(name, json!(now));
        }
    }

    // JS hooks: onRecordCreateRequest may mutate the record or reject.
    #[cfg(feature = "hooks")]
    if let Some(hooks) = state.hooks.clone() {
        if hooks.active_for(super::hooks::ACT_CREATE) {
            match hooks
                .fire_record("create", &col.name, &Value::Object(data.clone()))
                .await
            {
                Ok(Some(Value::Object(mutated))) => data = mutated,
                Ok(_) => {}
                Err(m) => return pb_err(StatusCode::BAD_REQUEST, &m),
            }
        }
    }
    if let super::rules::Lowered::Constrain(wire) = &create_rule {
        // createRule constrains the WOULD-BE record: evaluate in memory.
        let ok = data_plane_core::Filter::parse(wire)
            .map(|ast| super::rules::eval(&ast, &Value::Object(data.clone())))
            .unwrap_or(false);
        if !ok {
            return pb_err(StatusCode::BAD_REQUEST, "Failed to create record.");
        }
    }
    if let Err(r) = persist_files(&pb, &kinds, &col.id, &id, pending, &mut data).await {
        return r;
    }
    let mut op = base_op(DataOperationKind::Insert, &col.name);
    op.data = Some(Value::Object(data));
    if let Err(r) = exec(&state, op).await {
        return r;
    }
    match fetch_by_id(&state, &col, &kinds, &id).await {
        Ok(Some(mut rec)) => {
            publish_event(&state, &col, "create", &rec);
            if col.kind == "auth" {
                super::auth::scrub_auth_record(&mut rec, true);
            }
            (StatusCode::OK, Json(rec)).into_response()
        }
        Ok(None) => pb_err(StatusCode::INTERNAL_SERVER_ERROR, "record vanished after insert"),
        Err(r) => r,
    }
}

/// PATCH /api/collections/{c}/records/{id}
async fn update(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path((cname, rid)): Path<(String, String)>,
    request: axum::extract::Request,
) -> axum::response::Response {
    let (col, kinds) = match load_collection(&state, &cname) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let (_auth, ctx) = caller(&state, &headers).await;
    let lowered = super::rules::lower_rule(col.update_rule.as_ref(), &ctx);
    if matches!(lowered, super::rules::Lowered::Deny) {
        return pb_err(StatusCode::FORBIDDEN, "Only superusers can perform this action.");
    }
    if matches!(lowered, super::rules::Lowered::Never) {
        return pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found.");
    }
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let (body, pending) = match extract_body(&kinds, &headers, request, &state).await {
        Ok(v) => v,
        Err(r) => return r,
    };
    let mut data = match lower_body(&kinds, &body) {
        Ok(d) => d,
        Err(m) => return pb_err(StatusCode::BAD_REQUEST, &m),
    };
    if let Err(r) = persist_files(&pb, &kinds, &col.id, &rid, pending, &mut data).await {
        return r;
    }
    let now = pb_now();
    for (name, _, on_update) in autodates(&col) {
        if on_update {
            data.insert(name, json!(now));
        }
    }
    if data.is_empty() {
        // Nothing settable and no autodate to bump — PB answers with the
        // unchanged record rather than erroring.
        return match fetch_by_id(&state, &col, &kinds, &rid).await {
            Ok(Some(rec)) => (StatusCode::OK, Json(rec)).into_response(),
            Ok(None) => pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found."),
            Err(r) => r,
        };
    }
    #[cfg(feature = "hooks")]
    if let Some(hooks) = state.hooks.clone() {
        if hooks.active_for(super::hooks::ACT_UPDATE) {
            match hooks
                .fire_record("update", &col.name, &Value::Object(data.clone()))
                .await
            {
                Ok(Some(Value::Object(mutated))) => data = mutated,
                Ok(_) => {}
                Err(m) => return pb_err(StatusCode::BAD_REQUEST, &m),
            }
        }
    }
    let mut op = base_op(DataOperationKind::Update, &col.name);
    op.data = Some(Value::Object(data));
    op.filter = Some(json!({ "id": rid }));
    if let Err(r) = apply_rule(&mut op, lowered) {
        return r;
    }
    let result = match exec(&state, op).await {
        Ok(r) => r,
        Err(r) => return r,
    };
    if result.affected_rows == 0 {
        return pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found.");
    }
    match fetch_by_id(&state, &col, &kinds, &rid).await {
        Ok(Some(rec)) => {
            publish_event(&state, &col, "update", &rec);
            (StatusCode::OK, Json(rec)).into_response()
        }
        Ok(None) => pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found."),
        Err(r) => r,
    }
}

/// DELETE /api/collections/{c}/records/{id}
async fn remove(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path((cname, rid)): Path<(String, String)>,
) -> axum::response::Response {
    let (col, kinds) = match load_collection(&state, &cname) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let (_auth, ctx) = caller(&state, &headers).await;
    let lowered = super::rules::lower_rule(col.delete_rule.as_ref(), &ctx);
    if matches!(lowered, super::rules::Lowered::Deny) {
        return pb_err(StatusCode::FORBIDDEN, "Only superusers can perform this action.");
    }
    if matches!(lowered, super::rules::Lowered::Never) {
        return pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found.");
    }
    // Pre-image for the realtime event (PB sends the deleted record's last
    // known state).
    let pre = fetch_by_id(&state, &col, &kinds, &rid).await.ok().flatten();
    #[cfg(feature = "hooks")]
    if let Some(hooks) = state.hooks.clone() {
        if hooks.active_for(super::hooks::ACT_DELETE) {
            let payload = pre.clone().unwrap_or_else(|| json!({ "id": rid }));
            if let Err(m) = hooks.fire_record("delete", &col.name, &payload).await {
                return pb_err(StatusCode::BAD_REQUEST, &m);
            }
        }
    }
    let mut op = base_op(DataOperationKind::Delete, &col.name);
    op.filter = Some(json!({ "id": rid }));
    if let Err(r) = apply_rule(&mut op, lowered) {
        return r;
    }
    let result = match exec(&state, op).await {
        Ok(r) => r,
        Err(r) => return r,
    };
    if result.affected_rows == 0 {
        return pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found.");
    }
    if let Some(rec) = pre {
        publish_event(&state, &col, "delete", &rec);
    }
    if let Ok(pb) = pb_of(&state) {
        super::files::remove_record_files(&pb, &col.id, &rid).await;
    }
    StatusCode::NO_CONTENT.into_response()
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/collections/:collection/records", get(list).post(create))
        .route(
            "/api/collections/:collection/records/:id",
            get(view).patch(update).delete(remove),
        )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn col_with(fields: Value) -> Collection {
        Collection {
            id: "pbc_x".into(),
            name: "t".into(),
            kind: "base".into(),
            fields,
            options: json!({}),
            list_rule: Some(String::new()),
            view_rule: Some(String::new()),
            create_rule: Some(String::new()),
            update_rule: Some(String::new()),
            delete_rule: Some(String::new()),
            indexes: json!([]),
            created: String::new(),
            updated: String::new(),
        }
    }

    #[test]
    fn shapes_typed_values_and_zero_defaults() {
        let col = col_with(json!([
            {"name": "id", "type": "text", "system": true},
            {"name": "title", "type": "text"},
            {"name": "n", "type": "number"},
            {"name": "ok", "type": "bool"},
            {"name": "meta", "type": "json"},
            {"name": "tags", "type": "select", "maxSelect": 5},
        ]));
        let kinds = field_kinds(&col);
        let row = json!({"id": "abc", "title": null, "n": null, "ok": 1,
                         "meta": "{\"a\":1}", "tags": "[\"x\",\"y\"]"});
        let rec = shape_record(&col, &kinds, &row);
        assert_eq!(rec["title"], json!(""), "NULL text renders as empty string");
        assert_eq!(rec["n"], json!(0), "NULL number renders as 0");
        assert_eq!(rec["ok"], json!(true), "INTEGER 1 renders as true");
        assert_eq!(rec["meta"], json!({"a": 1}), "json TEXT parses");
        assert_eq!(rec["tags"], json!(["x", "y"]), "multi-select parses to array");
        assert_eq!(rec["collectionName"], json!("t"));
    }

    #[test]
    fn lower_body_keeps_declared_fields_and_stringifies_json() {
        let col = col_with(json!([
            {"name": "title", "type": "text"},
            {"name": "meta", "type": "json"},
        ]));
        let kinds = field_kinds(&col);
        let body = json!({"title": "x", "meta": {"a": 1}, "evil": "ignored"});
        let out = lower_body(&kinds, &body).unwrap();
        assert_eq!(out.get("title"), Some(&json!("x")));
        assert_eq!(out.get("meta"), Some(&json!("{\"a\":1}")), "json lowered to TEXT");
        assert!(!out.contains_key("evil"), "unknown keys ignored like PB");
    }

    #[test]
    fn sort_parses_ordered_and_rejects_unknown() {
        let col = col_with(json!([{"name": "b", "type": "text"}, {"name": "a", "type": "text"}]));
        let kinds = field_kinds(&col);
        let s = parse_sort("-b,a,+id", &kinds).unwrap();
        assert_eq!(s, vec![
            ("b".to_string(), "desc".to_string()),
            ("a".to_string(), "asc".to_string()),
            ("id".to_string(), "asc".to_string()),
        ], "declaration order preserved — the reason sort_order exists");
        assert!(parse_sort("created", &kinds).is_err(), "created only when declared");
        assert!(parse_sort("nope", &kinds).is_err());
    }

    #[test]
    fn autodate_fields_are_server_owned() {
        let col = col_with(json!([
            {"name": "title", "type": "text"},
            {"name": "created", "type": "autodate", "onCreate": true, "onUpdate": false},
            {"name": "updated", "type": "autodate", "onCreate": true, "onUpdate": true},
        ]));
        let kinds = field_kinds(&col);
        let out = lower_body(&kinds, &json!({"title": "x", "created": "spoof"})).unwrap();
        assert!(!out.contains_key("created"), "client can never set an autodate");
        let ad = autodates(&col);
        assert_eq!(ad, vec![
            ("created".to_string(), true, false),
            ("updated".to_string(), true, true),
        ]);
    }

    #[test]
    fn pb_ids_are_15_lowercase_alnum() {
        for _ in 0..50 {
            let id = super::super::pb_id();
            assert_eq!(id.len(), 15);
            assert!(id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()), "{id}");
        }
    }

    #[test]
    fn filter_wire_round_trips_through_engine_grammar() {
        let wire = filter_wire("status = 'active' && n > 3").unwrap().unwrap();
        // must parse under the ENGINE's validating grammar
        assert!(data_plane_core::Filter::parse(&wire).is_ok());
        assert!(filter_wire("").unwrap().is_none());
        assert!(filter_wire("bad ===").is_err());
    }
}
