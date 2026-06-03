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
}
