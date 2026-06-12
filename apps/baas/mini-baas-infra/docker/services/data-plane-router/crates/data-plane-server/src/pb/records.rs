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

fn allowed(state: &AppState, headers: &header::HeaderMap, raw: Option<&String>) -> bool {
    match rule_of(raw) {
        Rule::Public => true,
        Rule::Locked => matches!(pb_auth(state, headers), PbAuth::Superuser),
        // Fail closed until the Phase K rules engine evaluates expressions.
        Rule::Expr(_) => matches!(pb_auth(state, headers), PbAuth::Superuser),
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
        if *kind == FieldKind::Autodate {
            continue; // server-stamped, never client-set (PB ignores them too)
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

fn filter_to_wire(f: &data_plane_core::Filter) -> Value {
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
    if !allowed(&state, &headers, col.list_rule.as_ref()) {
        return pb_err(StatusCode::FORBIDDEN, "Only superusers can perform this action.");
    }
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
    let filter_for_count = op.filter.clone();
    let result = match exec(&state, op).await {
        Ok(r) => r,
        Err(r) => return r,
    };
    let items: Vec<Value> = result
        .rows
        .iter()
        .map(|r| shape_record(&col, &kinds, r))
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
    if !allowed(&state, &headers, col.view_rule.as_ref()) {
        return pb_err(StatusCode::FORBIDDEN, "Only superusers can perform this action.");
    }
    match fetch_by_id(&state, &col, &kinds, &rid).await {
        Ok(Some(rec)) => (StatusCode::OK, Json(rec)).into_response(),
        Ok(None) => pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found."),
        Err(r) => r,
    }
}

/// POST /api/collections/{c}/records
async fn create(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path(cname): Path<String>,
    Json(body): Json<Value>,
) -> axum::response::Response {
    let (col, kinds) = match load_collection(&state, &cname) {
        Ok(v) => v,
        Err(r) => return r,
    };
    if !allowed(&state, &headers, col.create_rule.as_ref()) {
        return pb_err(StatusCode::FORBIDDEN, "Only superusers can perform this action.");
    }
    let mut data = match lower_body(&kinds, &body) {
        Ok(d) => d,
        Err(m) => return pb_err(StatusCode::BAD_REQUEST, &m),
    };
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

    let mut op = base_op(DataOperationKind::Insert, &col.name);
    op.data = Some(Value::Object(data));
    if let Err(r) = exec(&state, op).await {
        return r;
    }
    match fetch_by_id(&state, &col, &kinds, &id).await {
        Ok(Some(rec)) => (StatusCode::OK, Json(rec)).into_response(),
        Ok(None) => pb_err(StatusCode::INTERNAL_SERVER_ERROR, "record vanished after insert"),
        Err(r) => r,
    }
}

/// PATCH /api/collections/{c}/records/{id}
async fn update(
    State(state): State<AppState>,
    headers: header::HeaderMap,
    Path((cname, rid)): Path<(String, String)>,
    Json(body): Json<Value>,
) -> axum::response::Response {
    let (col, kinds) = match load_collection(&state, &cname) {
        Ok(v) => v,
        Err(r) => return r,
    };
    if !allowed(&state, &headers, col.update_rule.as_ref()) {
        return pb_err(StatusCode::FORBIDDEN, "Only superusers can perform this action.");
    }
    let mut data = match lower_body(&kinds, &body) {
        Ok(d) => d,
        Err(m) => return pb_err(StatusCode::BAD_REQUEST, &m),
    };
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
    let mut op = base_op(DataOperationKind::Update, &col.name);
    op.data = Some(Value::Object(data));
    op.filter = Some(json!({ "id": rid }));
    let result = match exec(&state, op).await {
        Ok(r) => r,
        Err(r) => return r,
    };
    if result.affected_rows == 0 {
        return pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found.");
    }
    match fetch_by_id(&state, &col, &kinds, &rid).await {
        Ok(Some(rec)) => (StatusCode::OK, Json(rec)).into_response(),
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
    let (col, _kinds) = match load_collection(&state, &cname) {
        Ok(v) => v,
        Err(r) => return r,
    };
    if !allowed(&state, &headers, col.delete_rule.as_ref()) {
        return pb_err(StatusCode::FORBIDDEN, "Only superusers can perform this action.");
    }
    let mut op = base_op(DataOperationKind::Delete, &col.name);
    op.filter = Some(json!({ "id": rid }));
    let result = match exec(&state, op).await {
        Ok(r) => r,
        Err(r) => return r,
    };
    if result.affected_rows == 0 {
        return pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found.");
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
