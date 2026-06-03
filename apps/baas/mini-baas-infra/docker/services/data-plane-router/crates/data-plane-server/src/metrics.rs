//! Dependency-free Prometheus metrics for the data plane (wiki/04 §6, gap G7).
//!
//! Kept consistent with the Go control plane's `baas_*` exposition and without
//! pulling the `prometheus` crate: the router only needs request counts, uptime
//! and per-mount pool saturation, which std atomics + the existing
//! `PoolRegistry::stats()` already provide.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

/// Process-wide request counters. Lives in `AppState` behind an `Arc`.
pub struct Metrics {
    start: Instant,
    total: AtomicU64,
    c2xx: AtomicU64,
    c4xx: AtomicU64,
    c5xx: AtomicU64,
}

impl Default for Metrics {
    fn default() -> Self {
        Self {
            start: Instant::now(),
            total: AtomicU64::new(0),
            c2xx: AtomicU64::new(0),
            c4xx: AtomicU64::new(0),
            c5xx: AtomicU64::new(0),
        }
    }
}

impl Metrics {
    /// Record one finished request, bucketed by HTTP status class.
    pub fn record(&self, status: u16) {
        self.total.fetch_add(1, Ordering::Relaxed);
        let bucket = match status / 100 {
            2 => &self.c2xx,
            4 => &self.c4xx,
            5 => &self.c5xx,
            _ => return,
        };
        bucket.fetch_add(1, Ordering::Relaxed);
    }

    #[must_use]
    pub fn uptime_secs(&self) -> u64 {
        self.start.elapsed().as_secs()
    }

    /// (total, 2xx, 4xx, 5xx)
    #[must_use]
    pub fn snapshot(&self) -> (u64, u64, u64, u64) {
        (
            self.total.load(Ordering::Relaxed),
            self.c2xx.load(Ordering::Relaxed),
            self.c4xx.load(Ordering::Relaxed),
            self.c5xx.load(Ordering::Relaxed),
        )
    }
}

/// Escape a Prometheus label value (`\`, `"`, newline).
#[must_use]
pub fn escape_label(v: &str) -> String {
    v.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_buckets_by_status_class() {
        let m = Metrics::default();
        m.record(200);
        m.record(201);
        m.record(404);
        m.record(503);
        m.record(101); // 1xx ignored by the class buckets but counted in total
        let (total, c2, c4, c5) = m.snapshot();
        assert_eq!(total, 5);
        assert_eq!(c2, 2);
        assert_eq!(c4, 1);
        assert_eq!(c5, 1);
    }

    #[test]
    fn escape_label_handles_specials() {
        assert_eq!(escape_label(r#"a"b\c"#), r#"a\"b\\c"#);
        assert_eq!(escape_label("tenant/proj/db/pg/1"), "tenant/proj/db/pg/1");
    }
}
