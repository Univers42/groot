//! Phase 7d — outbox emission for the direct `/data/v1` front door.
//!
//! The outbox-relay → Redis Streams → realtime / webhooks / projections pipeline
//! reads `public.outbox_events` and never sees the producer. When a write goes
//! through the TS query-router, IT emits the event; when a write goes through
//! the Rust bypass, the query-router is no longer in the path, so the data plane
//! must emit the SAME row shape itself — or row-change fan-out silently stops
//! after cutover. This module does exactly that, matching the query-router's
//! `OutboxService.emitForQuery` column set + payload so downstream consumers are
//! oblivious to which plane produced the event.
//!
//! Disabled (no-op) unless `DATA_PLANE_OUTBOX_DSN` is set, so it ships dormant
//! alongside the bypass.

use deadpool_postgres::{Config as PgConfig, Pool, Runtime};
use serde_json::{json, Value};
use tokio_postgres::NoTls;

use data_plane_core::{DataOperationKind, DataResult, RequestIdentity};

/// Writes row-change events to `public.outbox_events`. Cloneable-cheap (the pool
/// is an Arc inside).
pub struct OutboxEmitter {
    pool: Pool,
}

impl OutboxEmitter {
    /// Build from `DATA_PLANE_OUTBOX_DSN`. Returns `None` (→ no-op emission) when
    /// the DSN is unset, so the bypass works without the outbox until it's wired.
    #[must_use]
    pub fn from_env() -> Option<Self> {
        let dsn = std::env::var("DATA_PLANE_OUTBOX_DSN")
            .ok()
            .filter(|s| !s.trim().is_empty())?;
        let mut cfg = PgConfig::new();
        cfg.url = Some(dsn);
        let pool = cfg.create_pool(Some(Runtime::Tokio1), NoTls).ok()?;
        Some(Self { pool })
    }

    /// Emit one row-change event for a successful MUTATION, mirroring the
    /// query-router's `emitForQuery`. Best-effort + fire-and-forget at the call
    /// site: a failed emit must never fail the (already-committed) write, it just
    /// logs — exactly the query-router's `.catch(warn)` posture.
    // Internal fan-out plumbing: a params struct would be pure ceremony here.
    #[allow(clippy::too_many_arguments)]
    pub async fn emit_mutation(
        &self,
        engine: &str,
        identity: &RequestIdentity,
        op: DataOperationKind,
        resource: &str,
        data: Option<&Value>,
        filter: Option<&Value>,
        result: &DataResult,
        idempotency_key: Option<&str>,
    ) -> Result<(), String> {
        // Never emit for the outbox table itself (would loop the relay).
        if resource == "outbox_events" {
            return Ok(());
        }
        let op_str = op_str(op);
        let aggregate_id = aggregate_id(result, data, filter);
        let event_type = format!("{resource}.{op_str}");
        // Match the query-router payload: a bounded row sample + counts so a
        // consumer can act without re-reading the row.
        let sample: Vec<Value> = result.rows.iter().take(10).cloned().collect();
        let payload = json!({
            "engine": engine,
            "resource": resource,
            "op": op_str,
            "data": data.cloned().unwrap_or(Value::Null),
            "filter": filter.cloned().unwrap_or(Value::Null),
            "rowCount": result.affected_rows,
            "rows": sample,
            // Provenance for parity diffing (additive, in-payload — no schema
            // change to the shared table).
            "emitted_by": "rust-data-plane",
        });
        // actor_id / request_id are uuid columns; the bypass principal is
        // `api-key:<uuid>` (not a bare uuid), which the query-router also nulls —
        // so both planes write NULL here (parity).
        let _ = identity;

        let client = self
            .pool
            .get()
            .await
            .map_err(|e| format!("outbox pool checkout: {e}"))?;
        // `payload` is bound as a serde_json::Value so tokio-postgres serializes
        // it natively as JSONB (the `with-serde_json-1` feature) — binding a
        // String here would make Postgres infer the param as jsonb and reject the
        // text encoding.
        client
            .execute(
                "INSERT INTO public.outbox_events \
                   (aggregate, aggregate_id, event_type, payload, op, idempotency_key) \
                 VALUES ($1, $2, $3, $4, $5, $6)",
                &[
                    &resource,
                    &aggregate_id,
                    &event_type,
                    &payload,
                    &op_str,
                    &idempotency_key,
                ],
            )
            .await
            .map_err(|e| format!("outbox insert: {e}"))?;
        Ok(())
    }
}

fn op_str(op: DataOperationKind) -> &'static str {
    match op {
        DataOperationKind::Insert => "insert",
        DataOperationKind::Update => "update",
        DataOperationKind::Delete => "delete",
        DataOperationKind::Upsert => "upsert",
        DataOperationKind::Batch => "batch",
        DataOperationKind::List => "list",
        DataOperationKind::Get => "get",
        DataOperationKind::Aggregate => "aggregate",
    }
}

/// The aggregate id, matching the query-router's precedence: the returned row's
/// `id`, else the write's `data.id`, else the `filter.id`, else "unknown".
fn aggregate_id(result: &DataResult, data: Option<&Value>, filter: Option<&Value>) -> String {
    let from_row = result
        .rows
        .first()
        .and_then(|r| r.get("id"))
        .and_then(value_to_id);
    let from_data = data.and_then(|d| d.get("id")).and_then(value_to_id);
    let from_filter = filter.and_then(|f| f.get("id")).and_then(value_to_id);
    from_row
        .or(from_data)
        .or(from_filter)
        .unwrap_or_else(|| "unknown".to_string())
}

fn value_to_id(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}
