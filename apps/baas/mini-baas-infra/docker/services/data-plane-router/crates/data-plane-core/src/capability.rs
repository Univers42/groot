use crate::DataOperationKind;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum IsolationLevel {
    ReadCommitted,
    RepeatableRead,
    Serializable,
    Snapshot,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum LatencyClass {
    Native,
    Adapter,
    Fdw,
    Remote,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PatternSearchCapability {
    Native,
    Indexed,
    Limited,
    Scan,
    Remote,
    None,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum JoinCapability {
    Native,
    Limited,
    None,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CostCapabilities {
    pub latency_class: LatencyClass,
    pub pattern_search: PatternSearchCapability,
    pub joins: JoinCapability,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EngineCapabilities {
    pub read: bool,
    pub write: bool,
    pub upsert: bool,
    /// Whether the adapter implements the multi-row `Batch` operation. Distinct
    /// from `max_batch_size` (which only bounds the size *once* batch is
    /// supported). `#[serde(default)]` lets a partial descriptor payload omit
    /// this field and deserialise to `false` — the honest value for every
    /// adapter today — so adding the field is backward-compatible on the wire.
    #[serde(default)]
    pub batch: bool,
    /// Whether the adapter implements grouped `Aggregate` (count/sum/avg/min/max
    /// + group_by). `#[serde(default)]` for wire back-compat.
    #[serde(default)]
    pub aggregate: bool,
    pub stream: bool,
    pub ddl: bool,
    pub transactions: bool,
    pub savepoints: bool,
    pub isolation_levels: Vec<IsolationLevel>,
    pub two_phase_commit: bool,
    pub native_idempotency: bool,
    pub max_batch_size: u32,
    pub cost: CostCapabilities,
}

impl EngineCapabilities {
    /// Whether this engine serves the given operation kind, derived from the
    /// capability flags. This is the **single source of truth** the planner
    /// gates on, so a flag and the operation it governs can never disagree. Each
    /// adapter's `dispatch_op` must implement exactly the set for which this
    /// returns `true` — pinned by the capability-honesty test in
    /// `data-plane-pool`.
    #[must_use]
    pub fn supports_op(&self, kind: &DataOperationKind) -> bool {
        match kind {
            DataOperationKind::List | DataOperationKind::Get => self.read,
            DataOperationKind::Insert
            | DataOperationKind::Update
            | DataOperationKind::Delete => self.write,
            DataOperationKind::Upsert => self.upsert,
            DataOperationKind::Batch => self.batch,
            DataOperationKind::Aggregate => self.aggregate,
        }
    }

    #[must_use]
    pub fn postgresql() -> Self {
        Self {
            read: true,
            write: true,
            upsert: true,
            batch: false,
            aggregate: true,
            stream: true,
            ddl: true,
            transactions: true,
            savepoints: true,
            isolation_levels: vec![
                IsolationLevel::ReadCommitted,
                IsolationLevel::RepeatableRead,
                IsolationLevel::Serializable,
            ],
            two_phase_commit: false,
            native_idempotency: false,
            max_batch_size: 1000,
            cost: CostCapabilities {
                latency_class: LatencyClass::Native,
                pattern_search: PatternSearchCapability::Native,
                joins: JoinCapability::Native,
            },
        }
    }

    #[must_use]
    pub fn mongodb() -> Self {
        Self {
            read: true,
            write: true,
            upsert: true,
            batch: false,
            aggregate: false,
            stream: true,
            ddl: false,
            // mongo's `begin()` returns NotImplemented (session-threading
            // refactor pending), so advertising transactions would be a lie.
            transactions: false,
            savepoints: false,
            isolation_levels: vec![IsolationLevel::Snapshot],
            two_phase_commit: false,
            native_idempotency: false,
            max_batch_size: 1000,
            cost: CostCapabilities {
                latency_class: LatencyClass::Native,
                pattern_search: PatternSearchCapability::Indexed,
                joins: JoinCapability::Limited,
            },
        }
    }

    #[must_use]
    pub fn mysql() -> Self {
        Self {
            read: true,
            write: true,
            upsert: true,
            batch: false,
            aggregate: false,
            stream: false,
            ddl: true,
            transactions: true,
            savepoints: true,
            isolation_levels: vec![
                IsolationLevel::ReadCommitted,
                IsolationLevel::RepeatableRead,
                IsolationLevel::Serializable,
            ],
            two_phase_commit: false,
            native_idempotency: false,
            max_batch_size: 1000,
            cost: CostCapabilities {
                latency_class: LatencyClass::Native,
                pattern_search: PatternSearchCapability::Indexed,
                joins: JoinCapability::Native,
            },
        }
    }

    #[must_use]
    pub fn redis() -> Self {
        Self {
            read: true,
            write: true,
            upsert: true,
            batch: false,
            aggregate: false,
            stream: false,
            ddl: false,
            transactions: false,
            savepoints: false,
            isolation_levels: vec![],
            two_phase_commit: false,
            native_idempotency: false,
            max_batch_size: 100,
            cost: CostCapabilities {
                latency_class: LatencyClass::Native,
                pattern_search: PatternSearchCapability::Scan,
                joins: JoinCapability::None,
            },
        }
    }

    #[must_use]
    pub fn http() -> Self {
        Self {
            read: true,
            write: true,
            upsert: true,
            batch: false,
            aggregate: false,
            stream: false,
            ddl: false,
            transactions: false,
            savepoints: false,
            isolation_levels: vec![],
            two_phase_commit: false,
            native_idempotency: false,
            max_batch_size: 50,
            cost: CostCapabilities {
                latency_class: LatencyClass::Remote,
                pattern_search: PatternSearchCapability::Remote,
                joins: JoinCapability::None,
            },
        }
    }
}
