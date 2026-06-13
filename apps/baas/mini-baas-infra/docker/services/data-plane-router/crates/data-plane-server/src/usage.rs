//! Track-B metering (B1a) — per-tenant usage counters in the data plane.
//!
//! The rate limiter caps *how fast* a tenant may go; metering records *how much*
//! it actually did, so the same per-tenant dimension the tier already caps
//! (`rps`/`max_rows`/`write`) gets its measured count. This is the **count** to
//! the limit's **cap** — the missing other half of each tier knob.
//!
//! ## Shape (mirrors `ratelimit.rs` + `outbox.rs`)
//!
//! - **Aggregate:** an in-process `Mutex<HashMap<(tenant, metric), u64>>` — the
//!   SAME concurrency shape the per-tenant token bucket uses (`ratelimit.rs`), so
//!   it adds no new dependency. [`UsageAggregate::record`] is a cheap, non-
//!   blocking `+=` taken on the request path only when metering is ON; at parity
//!   (flag OFF) the call site short-circuits before `record` is ever reached.
//! - **Flush:** a background task on a `tokio::time::interval` (the `outbox.rs`
//!   `into_background` precedent) drains the non-zero entries every `flush_ms`
//!   and emits ONE structured `usage` tracing event per `(tenant, metric)`
//!   window — then resets that entry to zero. Draining-and-resetting bounds the
//!   map and makes each event a discrete window total (not a running sum).
//!
//! ## Sink (B1a vs B1b)
//!
//! The B1a SINK is the structured `tracing::info!(target: "usage", …)` event —
//! routable by the existing tracing/promtail pipeline exactly like the `audit`
//! target. The Redis-Streams `usage.*` XADD that the design's §(c) describes is
//! the **B1b** ingest boundary; B1a deliberately stops at the structured event
//! (see the plan's "Emit mechanism" — B1d uses the same `tracing` sink). This is
//! a deviation-by-design noted in the Report: B1a emits the event, B1b wires the
//! stream/store. Keeping B1a to the in-process aggregate + tracing sink is the
//! smallest safe slice (no new infra, no cross-repo).
//!
//! ## Parity (flag OFF)
//!
//! With metering OFF the request path never calls `record`, so the map stays
//! empty and the flusher (if spawned) finds nothing to drain → zero events. The
//! server only spawns the flusher when `metering` is ON, so OFF adds not even an
//! idle timer — observably byte-parity with today.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::Mutex;
use std::time::Duration;

/// In-process usage aggregate keyed `(tenant_id, metric)` → summed `qty`. Cheap:
/// one `u64` per active `(tenant, metric)` pair, bounded by the flusher draining
/// (and removing) zeroed entries each window. Same `Mutex<HashMap>` shape as the
/// rate limiter's bucket store — no new dependency.
#[derive(Default)]
pub struct UsageAggregate {
    counters: Mutex<HashMap<(String, String), u64>>,
}

impl UsageAggregate {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Record `qty` of `metric` for `tenant`. Cheap, non-blocking `+=` under a
    /// short critical section (no I/O, no await). Saturating so a runaway count
    /// can never panic the request path. Call sites guard on the metering flag
    /// BEFORE invoking this, so at parity it is never reached.
    pub fn record(&self, tenant: &str, metric: &str, qty: u64) {
        if qty == 0 {
            return;
        }
        let mut map = self.counters.lock().expect("usage aggregate poisoned");
        let entry = map
            .entry((tenant.to_string(), metric.to_string()))
            .or_insert(0);
        *entry = entry.saturating_add(qty);
    }

    /// Drain every non-zero `(tenant, metric)` entry, returning its window total
    /// and REMOVING it from the map (reset to zero for the next window, and bound
    /// the map so idle pairs don't accumulate). Returned order is unspecified.
    #[must_use]
    pub fn drain(&self) -> Vec<(String, String, u64)> {
        let mut map = self.counters.lock().expect("usage aggregate poisoned");
        if map.is_empty() {
            return Vec::new();
        }
        // Replace with an empty map: this both reads every entry AND resets, in
        // one critical section, so a concurrent `record` either lands in the old
        // (drained) map before the swap or the fresh one after — never lost mid-
        // swap. The old map is moved out and iterated outside the lock.
        let taken = std::mem::take(&mut *map);
        drop(map);
        taken
            .into_iter()
            .filter(|(_, qty)| *qty > 0)
            .map(|((t, m), qty)| (t, m, qty))
            .collect()
    }

    /// Number of `(tenant, metric)` pairs currently tracked — the gauge a gate
    /// or `/metrics` scrape can read to prove OFF == 0 entries.
    #[must_use]
    pub fn tracked(&self) -> usize {
        self.counters.lock().expect("usage aggregate poisoned").len()
    }
}

/// The metering handle wired into `AppState` (like the rate limiter / metrics).
/// Holds the shared aggregate; the request path calls [`Usage::record`], the
/// background flusher (spawned by [`Usage::spawn_flusher`]) drains + emits.
#[derive(Clone)]
pub struct Usage {
    aggregate: Arc<UsageAggregate>,
}

impl Default for Usage {
    fn default() -> Self {
        Self::new()
    }
}

impl Usage {
    #[must_use]
    pub fn new() -> Self {
        Self { aggregate: Arc::new(UsageAggregate::new()) }
    }

    /// Record one metering event. A thin pass-through to the aggregate so call
    /// sites depend only on this handle. Cheap + non-blocking.
    pub fn record(&self, tenant: &str, metric: &str, qty: u64) {
        self.aggregate.record(tenant, metric, qty);
    }

    /// Pairs currently tracked (test/observability).
    #[must_use]
    pub fn tracked(&self) -> usize {
        self.aggregate.tracked()
    }

    /// Spawn the background flusher (the `outbox.rs::into_background` precedent):
    /// every `flush_ms`, drain non-zero `(tenant, metric)` aggregates and emit
    /// ONE structured `usage` tracing event per entry (the B1a sink). Only
    /// spawned when metering is ON, so OFF adds not even an idle timer (parity).
    /// `flush_ms` is clamped to ≥1 so a misconfigured `0` can't busy-spin.
    pub fn spawn_flusher(&self, flush_ms: u64) {
        let aggregate = self.aggregate.clone();
        let period = Duration::from_millis(flush_ms.max(1));
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(period);
            // Skip missed ticks instead of bursting if a flush ran long.
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                ticker.tick().await;
                emit_window(&aggregate, flush_ms);
            }
        });
    }

    /// Flush-on-shutdown (cheap): drain + emit any pending window synchronously.
    /// Called from the graceful-shutdown path so the last partial window isn't
    /// silently lost. No-op when the map is empty (parity / metering OFF).
    pub fn flush_now(&self, flush_ms: u64) {
        emit_window(&self.aggregate, flush_ms);
    }
}

/// Drain the aggregate and emit one structured `usage` event per non-zero
/// `(tenant, metric)` window. The B1a sink: a `tracing` event on the `usage`
/// target (sibling to the `audit` target), carrying the frozen envelope fields
/// `(tenant, metric, qty)` plus the `window_ms` cadence so B1b can attribute the
/// rollup to a window. No-op when nothing was recorded (the empty-map fast path
/// in `drain` keeps a quiet flusher allocation-free).
fn emit_window(aggregate: &UsageAggregate, flush_ms: u64) {
    for (tenant, metric, qty) in aggregate.drain() {
        tracing::info!(
            target: "usage",
            tenant = %tenant,
            metric = %metric,
            qty = qty,
            window_ms = flush_ms,
            "usage window"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // The core contract the gate pins: record sums per (tenant, metric), drain
    // returns the window totals AND resets to zero, and a second drain is empty.
    #[test]
    fn record_drain_reset() {
        let agg = UsageAggregate::new();
        // Two metrics for one tenant + one for another.
        agg.record("t1", "query.count", 1);
        agg.record("t1", "query.count", 1); // sums to 2
        agg.record("t1", "query.rows", 50);
        agg.record("t2", "write.rows", 3);
        assert_eq!(agg.tracked(), 3, "three distinct (tenant, metric) pairs");

        let mut drained = agg.drain();
        drained.sort();
        assert_eq!(
            drained,
            vec![
                ("t1".to_string(), "query.count".to_string(), 2),
                ("t1".to_string(), "query.rows".to_string(), 50),
                ("t2".to_string(), "write.rows".to_string(), 3),
            ],
            "drain returns per-pair window totals"
        );

        // Reset: the map is empty after a drain, and a second drain yields none.
        assert_eq!(agg.tracked(), 0, "drain reset the aggregate to empty");
        assert!(agg.drain().is_empty(), "second drain is empty (no double-count)");
    }

    // qty == 0 is a no-op (parity: a zero-row read at the limit clamp must not
    // create an entry or emit a window).
    #[test]
    fn zero_qty_records_nothing() {
        let agg = UsageAggregate::new();
        agg.record("t1", "query.rows", 0);
        assert_eq!(agg.tracked(), 0, "zero qty creates no entry");
        assert!(agg.drain().is_empty());
    }

    // Tenants are isolated — one tenant's count never bleeds into another's, the
    // same isolation property the rate limiter pins.
    #[test]
    fn tenants_are_isolated() {
        let agg = UsageAggregate::new();
        agg.record("a", "query.count", 5);
        agg.record("b", "query.count", 1);
        let mut drained = agg.drain();
        drained.sort();
        assert_eq!(
            drained,
            vec![
                ("a".to_string(), "query.count".to_string(), 5),
                ("b".to_string(), "query.count".to_string(), 1),
            ]
        );
    }

    // The Usage handle is the wired surface: record → tracked → drain via the
    // shared aggregate, and flush_now on an empty handle is a harmless no-op.
    #[test]
    fn handle_records_and_flush_now_is_noop_when_empty() {
        let usage = Usage::new();
        assert_eq!(usage.tracked(), 0);
        usage.flush_now(60000); // empty → no-op, must not panic
        usage.record("t1", "write.rows", 7);
        assert_eq!(usage.tracked(), 1);
        // Draining via the shared aggregate clone proves the handle shares state.
        assert_eq!(usage.aggregate.drain(), vec![("t1".to_string(), "write.rows".to_string(), 7)]);
        assert_eq!(usage.tracked(), 0);
    }
}
