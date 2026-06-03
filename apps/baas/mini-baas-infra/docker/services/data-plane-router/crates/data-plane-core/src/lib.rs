pub mod capability;
pub mod error;
pub mod filter;
pub mod identity;
pub mod isolation;
pub mod mount;
pub mod operation;
pub mod plan;
pub mod planner;
pub mod ports;
pub mod transaction;

pub use capability::{CostCapabilities, EngineCapabilities, IsolationLevel};
pub use error::{DataPlaneError, DataPlaneResult};
pub use filter::{CmpOp, Filter, Folded};
pub use plan::{plan, OpShape, Plan, PlanDecision, WorkloadContext};
pub use planner::{required_capability, validate_operation};
pub use identity::{IdentitySource, RequestIdentity};
pub use isolation::{safe_schema, Isolation, ScopeDirective};
pub use mount::{CredentialRef, DatabaseMount, PoolPolicy};
pub use operation::{
    AggFunc, Aggregate, AggregateSpec, DataOperation, DataOperationKind, DataResult, ReturningMode,
};
pub use ports::{
    EngineAdapter, EngineHealth, EnginePool, MigrationRequest, MigrationResult, MigrationStatus,
    PoolRegistry, PoolStats, RawStatement, TxHandle,
};
pub use transaction::{TxBeginRequest, TxSession, TxState};
