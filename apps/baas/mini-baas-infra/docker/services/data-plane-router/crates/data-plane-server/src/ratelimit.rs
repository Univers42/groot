//! Per-tenant token-bucket rate limiting (Phase 4 tiering).
//!
//! The tenant's package tier sets `rps` (sustained refill rate) + `burst`
//! (bucket capacity); these arrive per request inside the mount's
//! `capability_overrides` (the tier mask the query-router stamps from the
//! key-verify response). The limiter therefore keys on the tenant in the
//! TRUSTED envelope, not on anything Kong or the proxy compute — so it survives
//! the Phase-7 TS bypass unchanged, and Kong's coarse per-IP limit stays as the
//! outer shell.
//!
//! A tenant with no limit (no mask, or `rps == 0`) is UNLIMITED — the parity
//! path for untiered tenants, so this is a no-op until packages are assigned.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::Value;

struct Bucket {
    tokens: f64,
    last: Instant,
}

/// In-process token-bucket store keyed by `tenant_id`. Cheap: one `f64` +
/// `Instant` per active tenant, refilled lazily on access (no background timer
/// per tenant). The map is bounded by [`TenantRateLimiter::evict_idle`], called
/// from the same periodic task as the pool reaper.
#[derive(Default)]
pub struct TenantRateLimiter {
    buckets: Mutex<HashMap<String, Bucket>>,
}

impl TenantRateLimiter {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Try to admit one request for `tenant`. `rps` is the sustained refill rate
    /// (tokens/second), `burst` the bucket capacity. Returns `true` to admit,
    /// `false` to reject (→ 429). `rps == 0` means unlimited (parity).
    pub fn allow(&self, tenant: &str, rps: u32, burst: u32) -> bool {
        if rps == 0 {
            return true;
        }
        let cap = f64::from(burst.max(1));
        let now = Instant::now();
        let mut map = self.buckets.lock().expect("rate limiter poisoned");
        let bucket = map
            .entry(tenant.to_string())
            .or_insert_with(|| Bucket { tokens: cap, last: now });
        // Lazy refill: add tokens for the elapsed time, capped at the burst size.
        let elapsed = now.duration_since(bucket.last).as_secs_f64();
        bucket.tokens = (bucket.tokens + elapsed * f64::from(rps)).min(cap);
        bucket.last = now;
        if bucket.tokens >= 1.0 {
            bucket.tokens -= 1.0;
            true
        } else {
            false
        }
    }

    /// Best-effort eviction of buckets untouched for longer than `idle`. Bounds
    /// the map under N-tenant fan-out. A full, idle bucket loses nothing by being
    /// dropped (it re-creates full on next access).
    pub fn evict_idle(&self, idle: Duration) {
        let now = Instant::now();
        let mut map = self.buckets.lock().expect("rate limiter poisoned");
        map.retain(|_, b| now.duration_since(b.last) < idle);
    }

    #[cfg(test)]
    fn tracked(&self) -> usize {
        self.buckets.lock().unwrap().len()
    }
}

/// Extract `(rps, burst)` from a mount's tier mask (`capability_overrides`).
/// `burst` defaults to `2 × rps` when the mask omits it. Returns `None` (→
/// unlimited) when there is no mask or no `rps` key — the parity path.
#[must_use]
pub fn tier_rate(overrides: Option<&Value>) -> Option<(u32, u32)> {
    let obj = overrides?.as_object()?;
    let rps = u32::try_from(obj.get("rps")?.as_u64()?).ok()?;
    if rps == 0 {
        return None;
    }
    let burst = obj
        .get("burst")
        .and_then(Value::as_u64)
        .and_then(|b| u32::try_from(b).ok())
        .unwrap_or(rps.saturating_mul(2));
    Some((rps, burst))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn unlimited_when_rps_zero() {
        let rl = TenantRateLimiter::new();
        for _ in 0..1000 {
            assert!(rl.allow("t1", 0, 0), "rps=0 is unlimited");
        }
    }

    #[test]
    fn burst_then_deny_then_refill() {
        let rl = TenantRateLimiter::new();
        // burst capacity = 5 → first 5 admit immediately, 6th denied.
        for i in 0..5 {
            assert!(rl.allow("t1", 100, 5), "burst token {i} should admit");
        }
        assert!(!rl.allow("t1", 100, 5), "6th request exceeds burst → deny");
        // After ~20ms at 100rps, ~2 tokens refill → admits again.
        std::thread::sleep(Duration::from_millis(30));
        assert!(rl.allow("t1", 100, 5), "refilled bucket admits after wait");
    }

    #[test]
    fn tenants_are_isolated() {
        let rl = TenantRateLimiter::new();
        for _ in 0..3 {
            assert!(rl.allow("a", 100, 3));
        }
        assert!(!rl.allow("a", 100, 3), "tenant a exhausted");
        // tenant b has its own bucket, unaffected.
        assert!(rl.allow("b", 100, 3), "tenant b independent");
    }

    #[test]
    fn evict_idle_drops_stale_buckets() {
        let rl = TenantRateLimiter::new();
        assert!(rl.allow("a", 100, 3));
        assert_eq!(rl.tracked(), 1);
        std::thread::sleep(Duration::from_millis(5));
        rl.evict_idle(Duration::from_millis(1));
        assert_eq!(rl.tracked(), 0, "stale bucket evicted");
    }

    #[test]
    fn tier_rate_parsing() {
        assert_eq!(tier_rate(None), None);
        assert_eq!(tier_rate(Some(&json!({ "aggregate": false }))), None, "no rps → unlimited");
        assert_eq!(tier_rate(Some(&json!({ "rps": 0 }))), None, "rps 0 → unlimited");
        assert_eq!(tier_rate(Some(&json!({ "rps": 20 }))), Some((20, 40)), "burst defaults 2x");
        assert_eq!(tier_rate(Some(&json!({ "rps": 200, "burst": 250 }))), Some((200, 250)));
    }
}
