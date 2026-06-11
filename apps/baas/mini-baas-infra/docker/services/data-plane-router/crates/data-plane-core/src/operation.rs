use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DataOperationKind {
    List,
    Get,
    Insert,
    Update,
    Delete,
    Upsert,
    Batch,
    /// Grouped aggregation (count/sum/avg/min/max + `group_by`) — the carried
    /// [`AggregateSpec`] lives in [`DataOperation::aggregate`].
    Aggregate,
}

impl DataOperationKind {
    /// Every operation kind, for exhaustive iteration (the capability-honesty
    /// gate, the planner, tests). One canonical list so the "all ops" array
    /// isn't hand-copied across the codebase.
    pub const ALL: [DataOperationKind; 8] = [
        Self::List,
        Self::Get,
        Self::Insert,
        Self::Update,
        Self::Delete,
        Self::Upsert,
        Self::Batch,
        Self::Aggregate,
    ];

    /// The wire name (`insert`/`update`/…) — the snake_case serde tag as a
    /// `&'static str`, for audit events, automation trigger matching and
    /// realtime payloads without a serde round-trip.
    #[must_use]
    pub fn wire_name(&self) -> &'static str {
        match self {
            Self::List => "list",
            Self::Get => "get",
            Self::Insert => "insert",
            Self::Update => "update",
            Self::Delete => "delete",
            Self::Upsert => "upsert",
            Self::Batch => "batch",
            Self::Aggregate => "aggregate",
        }
    }
}

/// A SQL aggregate function — an allowlist, so the function name is never
/// taken from client text.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AggFunc {
    Count,
    Sum,
    Avg,
    Min,
    Max,
}

/// One aggregate output column: `func(field) AS alias`. `field` is omitted for
/// `count` (→ `COUNT(*)`); required for the others.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Aggregate {
    pub func: AggFunc,
    #[serde(default)]
    pub field: Option<String>,
    /// `func(DISTINCT field)` — requires a `field` (so `count` distinct is
    /// `count(DISTINCT field)`, never `count(DISTINCT *)`).
    #[serde(default)]
    pub distinct: bool,
    pub alias: String,
}

/// The aggregation request: the `aggregates` (output columns) and the optional
/// `group_by` columns. `filter` (on [`DataOperation`]) scopes the rows before
/// grouping.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct AggregateSpec {
    #[serde(default)]
    pub group_by: Vec<String>,
    pub aggregates: Vec<Aggregate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ReturningMode {
    None,
    Changed,
    Full,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DataOperation {
    pub op: DataOperationKind,
    pub resource: String,
    pub data: Option<Value>,
    pub filter: Option<Value>,
    pub sort: Option<BTreeMap<String, String>>,
    pub limit: Option<u32>,
    pub offset: Option<u32>,
    pub idempotency_key: Option<String>,
    pub expected_version: Option<Value>,
    pub returning: Option<ReturningMode>,
    /// Aggregation request — present (and required) only for `op = Aggregate`.
    #[serde(default)]
    pub aggregate: Option<AggregateSpec>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DataResult {
    #[serde(default)]
    pub rows: Vec<Value>,
    pub affected_rows: u64,
    pub next_cursor: Option<String>,
    /// Per-item outcomes — present only for `op = Batch`. Absent on every
    /// other operation so the wire shape of existing responses is unchanged.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub batch: Option<BatchSummary>,
}

/// The result envelope of a batch: whether the engine executed it atomically
/// (SQL engines wrap the items in one transaction; document/KV engines run
/// them *ordered*, stopping at the first error) and one outcome per item.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BatchSummary {
    /// `true` → all-or-nothing (a failed item rolled the whole batch back);
    /// `false` → ordered execution, items before a failure are persisted.
    pub atomic: bool,
    pub items: Vec<BatchItemOutcome>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BatchItemOutcome {
    pub index: u32,
    pub status: BatchItemStatus,
    pub affected_rows: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum BatchItemStatus {
    Ok,
    Error,
    /// Not executed because an earlier item failed (non-atomic engines only).
    Skipped,
}

impl DataOperation {
    /// Parses and validates the batch payload: `data` must be a non-empty JSON
    /// array of sub-operations, none of which may itself be a batch. The
    /// per-engine size ceiling is the planner's job (`max_batch_size`); this
    /// guards shape only, so every adapter shares one wire contract.
    pub fn batch_items(&self) -> Result<Vec<DataOperation>, String> {
        let Some(Value::Array(raw)) = self.data.as_ref() else {
            return Err("batch requires `data` to be a JSON array of sub-operations".to_string());
        };
        if raw.is_empty() {
            return Err("batch requires at least one sub-operation".to_string());
        }
        let mut items = Vec::with_capacity(raw.len());
        for (idx, item) in raw.iter().enumerate() {
            let sub: DataOperation = serde_json::from_value(item.clone())
                .map_err(|e| format!("batch item {idx} is not a valid operation: {e}"))?;
            if sub.op == DataOperationKind::Batch {
                return Err(format!("batch item {idx}: nested batches are not allowed"));
            }
            if sub.resource.trim().is_empty() {
                return Err(format!("batch item {idx}: `resource` is required"));
            }
            items.push(sub);
        }
        Ok(items)
    }
}
