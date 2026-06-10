//! Capability-honesty gate (product-plan 04/S1 — "descriptors must not lie").
//!
//! Each engine advertises an [`EngineCapabilities`] descriptor (served at
//! `/v1/capabilities`, and the planner gates every request on it). This module
//! pins that descriptor to the **operations the adapter's `dispatch_op` actually
//! implements**, so the platform can never advertise a capability it doesn't
//! deliver — the exact failure mode the product assessment flagged (Postgres
//! once advertised `upsert` it couldn't do; every engine still advertised a
//! `batch` it can't do; mongo advertised `transactions` its `begin()` rejects).
//!
//! [`dispatch_reality`] returns **the same `SUPPORTED_OPS` const each adapter's
//! `dispatch_op` gate uses** — not a parallel hand-copy — so the
//! descriptor↔`SUPPORTED_OPS` binding cannot drift. The remaining
//! `SUPPORTED_OPS`↔match-arms binding is enforced by the dispatch match being
//! **exhaustive by enumeration** (no wildcard): deleting a CRUD arm is a compile
//! error, so an op stays dispatchable iff it has a real handler.

use data_plane_core::{DataOperationKind, EngineCapabilities};

const ENGINES: [&str; 8] = [
    "postgresql", "cockroachdb", "mysql", "mariadb", "mongodb", "redis", "sqlite", "http",
];

/// The operation kinds each adapter's `dispatch_op` actually serves — read from
/// the very `SUPPORTED_OPS` const the dispatch gate uses, so this is the real
/// dispatch surface, not a mirror of it.
fn dispatch_reality(engine: &str) -> &'static [DataOperationKind] {
    match engine {
        "postgresql" | "cockroachdb" => crate::postgres::SUPPORTED_OPS,
        "mysql" | "mariadb" => crate::mysql::SUPPORTED_OPS,
        "mongodb" => crate::mongo::SUPPORTED_OPS,
        "redis" => crate::redis::SUPPORTED_OPS,
        "sqlite" => crate::sqlite::SUPPORTED_OPS,
        "http" => crate::http::SUPPORTED_OPS,
        _ => &[],
    }
}

/// The descriptor each adapter's `capabilities()` returns.
fn descriptor(engine: &str) -> EngineCapabilities {
    match engine {
        "postgresql" => EngineCapabilities::postgresql(),
        "cockroachdb" => EngineCapabilities::cockroachdb(),
        "mysql" => EngineCapabilities::mysql(),
        "mariadb" => EngineCapabilities::mariadb(),
        "mongodb" => EngineCapabilities::mongodb(),
        "redis" => EngineCapabilities::redis(),
        "sqlite" => EngineCapabilities::sqlite(),
        "http" => EngineCapabilities::http(),
        other => panic!("unknown engine {other}"),
    }
}

#[test]
fn descriptor_advertises_exactly_what_dispatch_implements() {
    for engine in ENGINES {
        let caps = descriptor(engine);
        let real = dispatch_reality(engine);
        for kind in &DataOperationKind::ALL {
            let advertised = caps.supports_op(kind);
            let implemented = real.contains(kind);
            assert_eq!(
                advertised, implemented,
                "{engine}: descriptor.supports_op({kind:?})={advertised} but dispatch \
                 implements={implemented} — the capability descriptor must not lie",
            );
        }
    }
}

#[test]
fn batch_is_advertised_exactly_where_implemented() {
    // pg/mysql: atomic (per-request tx); mongo/redis: ordered, non-atomic.
    // http stays false: a remote REST passthrough cannot give batch
    // semantics — honesty over uniformity.
    for engine in ["postgresql", "mysql", "mongodb", "redis"] {
        assert!(descriptor(engine).batch, "{engine} implements run_batch");
    }
    assert!(!descriptor("http").batch, "http has no batch semantics");
}

#[test]
fn transaction_flag_matches_begin_implementation() {
    // postgres/mysql `begin()` return a real TxHandle; mongo/redis/http return
    // NotImplemented — the `transactions` flag must agree with that reality.
    assert!(descriptor("postgresql").transactions, "postgres begin() is implemented");
    assert!(descriptor("mysql").transactions, "mysql begin() is implemented");
    assert!(!descriptor("mongodb").transactions, "mongo begin() returns NotImplemented");
    assert!(!descriptor("redis").transactions, "redis begin() returns NotImplemented");
    assert!(!descriptor("http").transactions, "http begin() returns NotImplemented");
}
