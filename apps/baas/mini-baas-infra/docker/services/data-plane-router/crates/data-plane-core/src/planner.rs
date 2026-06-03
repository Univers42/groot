//! Capability-aware pre-flight validation (wiki/04-data-plane.md §2, gap G6).
//!
//! The router advertises an [`EngineCapabilities`] descriptor per engine at
//! `/v1/capabilities`, and the SDK is typed against it at compile time. This
//! module makes the **runtime** agree: it rejects an impossible `(engine,
//! operation)` pair with a precise [`DataPlaneError::UnsupportedCapability`]
//! (→ HTTP 400) *before* a connection pool is opened, instead of letting the
//! request fail deep inside an adapter.
//!
//! It is intentionally conservative. Every engine mounted in the Rust router
//! today advertises `read = write = upsert = true`, so this rejects nothing
//! that previously succeeded — it only turns genuinely impossible combinations
//! (e.g. an `upsert` against an engine that advertises `upsert: false`, or a
//! `batch` larger than the engine's `max_batch_size`) into a clean contract
//! error. That keeps the change additive and parity-safe.

use crate::{DataOperation, DataOperationKind, DataPlaneError, DataPlaneResult, EngineCapabilities};
use serde_json::Value;

/// The name of the capability flag an operation requires — used only for the
/// error message; the actual gate is [`EngineCapabilities::supports_op`], which
/// is the single source of truth shared with the descriptor.
#[must_use]
pub fn required_capability(kind: &DataOperationKind) -> &'static str {
    match kind {
        DataOperationKind::List | DataOperationKind::Get => "read",
        DataOperationKind::Insert | DataOperationKind::Update | DataOperationKind::Delete => {
            "write"
        }
        DataOperationKind::Upsert => "upsert",
        DataOperationKind::Batch => "batch",
        DataOperationKind::Aggregate => "aggregate",
    }
}

/// Validate an operation against an engine's advertised capabilities.
///
/// Returns `Ok(())` when the engine can serve the operation, or
/// [`DataPlaneError::UnsupportedCapability`] (mapped to HTTP 400 by the server)
/// when it cannot. Pure and side-effect free, so it is cheap to unit-test
/// exhaustively (op × engine) and safe to call on the hot path before dispatch.
pub fn validate_operation(
    op: &DataOperation,
    engine: &str,
    caps: &EngineCapabilities,
) -> DataPlaneResult<()> {
    if !caps.supports_op(&op.op) {
        return Err(DataPlaneError::UnsupportedCapability {
            engine: engine.to_string(),
            capability: required_capability(&op.op).to_string(),
        });
    }

    // A batch must fit the engine's advertised ceiling. We only inspect the
    // payload when it is a JSON array (the batch wire shape); anything else is
    // left for the adapter to interpret.
    if op.op == DataOperationKind::Batch {
        if let Some(Value::Array(items)) = op.data.as_ref() {
            if items.len() as u64 > u64::from(caps.max_batch_size) {
                return Err(DataPlaneError::UnsupportedCapability {
                    engine: engine.to_string(),
                    capability: format!("max_batch_size={}", caps.max_batch_size),
                });
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::operation::DataOperationKind::{
        Aggregate, Batch, Delete, Get, Insert, List, Update, Upsert,
    };
    use serde_json::json;

    fn op(kind: DataOperationKind, data: Option<Value>) -> DataOperation {
        DataOperation {
            op: kind,
            resource: "things".to_string(),
            data,
            filter: None,
            sort: None,
            limit: None,
            offset: None,
            idempotency_key: None,
            expected_version: None,
            returning: None,
            aggregate: None,
        }
    }

    #[test]
    fn required_capability_mapping_is_stable() {
        assert_eq!(required_capability(&List), "read");
        assert_eq!(required_capability(&Get), "read");
        assert_eq!(required_capability(&Insert), "write");
        assert_eq!(required_capability(&Update), "write");
        assert_eq!(required_capability(&Delete), "write");
        assert_eq!(required_capability(&Batch), "batch");
        assert_eq!(required_capability(&Upsert), "upsert");
        assert_eq!(required_capability(&Aggregate), "aggregate");
    }

    #[test]
    fn aggregate_gated_by_capability() {
        // Postgres advertises aggregate; the others don't → clean 400, not 501.
        assert!(validate_operation(&op(Aggregate, None), "postgresql", &EngineCapabilities::postgresql()).is_ok());
        for (name, caps) in [
            ("mysql", EngineCapabilities::mysql()),
            ("mongodb", EngineCapabilities::mongodb()),
            ("redis", EngineCapabilities::redis()),
            ("http", EngineCapabilities::http()),
        ] {
            let err = validate_operation(&op(Aggregate, None), name, &caps).unwrap_err();
            match err {
                DataPlaneError::UnsupportedCapability { capability, .. } => {
                    assert_eq!(capability, "aggregate", "{name}");
                }
                other => panic!("{name}: expected UnsupportedCapability, got {other:?}"),
            }
        }
    }

    #[test]
    fn batch_is_rejected_when_engine_lacks_batch_capability() {
        // No adapter implements Batch today (batch:false everywhere), so the
        // planner must reject it cleanly (400) rather than let it die as a 501
        // inside the adapter. This is the honesty fix.
        for (name, caps) in [
            ("postgresql", EngineCapabilities::postgresql()),
            ("mongodb", EngineCapabilities::mongodb()),
            ("mysql", EngineCapabilities::mysql()),
            ("redis", EngineCapabilities::redis()),
            ("http", EngineCapabilities::http()),
        ] {
            assert!(!caps.batch, "{name} must not advertise batch yet");
            let err = validate_operation(&op(Batch, None), name, &caps).unwrap_err();
            match err {
                DataPlaneError::UnsupportedCapability { capability, .. } => {
                    assert_eq!(capability, "batch", "{name}");
                }
                other => panic!("{name}: expected UnsupportedCapability, got {other:?}"),
            }
        }
    }

    #[test]
    fn every_live_engine_serves_full_crud_and_upsert() {
        // The engines actually mounted today all advertise read+write+upsert,
        // so the gate must be a no-op for them (parity invariant).
        let engines = [
            ("postgresql", EngineCapabilities::postgresql()),
            ("mongodb", EngineCapabilities::mongodb()),
            ("mysql", EngineCapabilities::mysql()),
            ("redis", EngineCapabilities::redis()),
            ("http", EngineCapabilities::http()),
        ];
        for (name, caps) in &engines {
            for kind in [List, Get, Insert, Update, Delete, Upsert] {
                let serves = validate_operation(&op(kind.clone(), None), name, caps).is_ok();
                assert!(serves, "{name} should serve {kind:?}");
            }
        }
    }

    #[test]
    fn missing_write_capability_is_rejected() {
        let mut caps = EngineCapabilities::redis();
        caps.write = false;
        let err = validate_operation(&op(Insert, None), "redis", &caps).unwrap_err();
        match err {
            DataPlaneError::UnsupportedCapability { capability, .. } => {
                assert_eq!(capability, "write");
            }
            other => panic!("expected UnsupportedCapability, got {other:?}"),
        }
    }

    #[test]
    fn missing_upsert_capability_is_rejected() {
        let mut caps = EngineCapabilities::postgresql();
        caps.upsert = false;
        let err = validate_operation(&op(Upsert, None), "postgresql", &caps).unwrap_err();
        assert!(matches!(err, DataPlaneError::UnsupportedCapability { .. }));
    }

    #[test]
    fn batch_within_ceiling_is_allowed_over_ceiling_is_rejected() {
        // The ceiling check only applies once an engine actually supports batch.
        let mut caps = EngineCapabilities::redis(); // max_batch_size = 100
        caps.batch = true;
        let within: Vec<Value> = (0..100).map(|i| json!({ "i": i })).collect();
        assert!(validate_operation(&op(Batch, Some(json!(within))), "redis", &caps).is_ok());

        let over: Vec<Value> = (0..101).map(|i| json!({ "i": i })).collect();
        let err = validate_operation(&op(Batch, Some(json!(over))), "redis", &caps).unwrap_err();
        match err {
            DataPlaneError::UnsupportedCapability { capability, .. } => {
                assert!(capability.contains("max_batch_size"));
            }
            other => panic!("expected UnsupportedCapability, got {other:?}"),
        }
    }

    #[test]
    fn non_array_batch_payload_is_left_to_the_adapter() {
        let mut caps = EngineCapabilities::http(); // max_batch_size = 50
        caps.batch = true; // pretend http supports batch, to reach the size check
        // An object (not an array) is not the batch wire shape; don't reject here.
        assert!(validate_operation(&op(Batch, Some(json!({ "a": 1 }))), "http", &caps).is_ok());
        assert!(validate_operation(&op(Batch, None), "http", &caps).is_ok());
    }
}
