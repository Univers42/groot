//! Quota enforcement honor side (Track-B B2). The control-plane QuotaGuard
//! periodically evaluates each tenant's current-period usage (from the B1
//! `public.tenant_usage` store) against its tier quota (packages.json) and
//! publishes the SET of over-quota tenant ids to Redis (`quota:over`). This
//! module is the data plane's CHEAP honor of that decision:
//!
//!   * an in-memory snapshot ([`QuotaSet`]) of the over-quota tenant ids,
//!   * refreshed from Redis on the SAME periodic reaper tick the pool/limiter
//!     use (one `SMEMBERS` per refresh — NOT per request),
//!   * read on the hot path as a single `HashSet::contains` (no I/O).
//!
//! So an over-quota tenant is rejected with **402 Payment Required** without the
//! request path ever doing a synchronous DB or Redis read.
//!
//! **Flag-gated OFF = byte-parity.** When `DATA_PLANE_QUOTA_ENFORCEMENT` is off
//! (the default) the snapshot is never built, the refresh is never scheduled, and
//! the hot-path check is skipped entirely (`Option::is_none` short-circuit before
//! any field access) — the request path takes ZERO extra branches.
//!
//! **Fail-OPEN.** If Redis is unreachable the snapshot stays at its last value
//! (or empty at boot) and the refresh logs + retries next tick — quota
//! enforcement must never become an availability single-point-of-failure for the
//! data path, the same posture as the rate limiter's Redis backend.

use std::collections::HashSet;
use std::sync::RwLock;

/// The Redis SET key the control-plane QuotaGuard publishes over-quota tenant
/// ids to. FROZEN contract shared with `internal/metering/quotaguard.go`.
pub const QUOTA_OVER_SET: &str = "quota:over";

/// In-memory snapshot of the over-quota tenant ids. `contains` is the hot-path
/// check (a read-locked `HashSet` lookup, no I/O); `replace` swaps in a freshly
/// fetched set on the refresh tick. An empty set means "no tenant is over quota"
/// (the fail-open default — also what an absent Redis key yields).
#[derive(Default)]
pub struct QuotaSet {
    over: RwLock<HashSet<String>>,
}

impl QuotaSet {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Hot-path check: is this tenant currently over its quota? A read lock + a
    /// hash lookup, no allocation, no I/O. False for any tenant when the set is
    /// empty (fail-open / parity).
    #[must_use]
    pub fn is_over(&self, tenant: &str) -> bool {
        self.over
            .read()
            .map(|s| s.contains(tenant))
            .unwrap_or(false)
    }

    /// Swap in a freshly fetched over-quota set (called on the refresh tick).
    pub fn replace(&self, next: HashSet<String>) {
        if let Ok(mut s) = self.over.write() {
            *s = next;
        }
    }

    /// Number of over-quota tenants currently tracked — the `/metrics` gauge the
    /// enforcement story can watch.
    #[must_use]
    pub fn tracked(&self) -> usize {
        self.over.read().map(|s| s.len()).unwrap_or(0)
    }
}

/// The refresher: a lazily-connected Redis client that `SMEMBERS quota:over` on
/// each tick and swaps the result into the shared [`QuotaSet`]. Reuses the
/// `redis-rl` crate the rate limiter already compiles (only present under the
/// `ratelimit-redis` feature). On a build WITHOUT that feature the refresher is a
/// no-op shell, so quota enforcement is simply unavailable there (nano/one),
/// never a compile break.
pub struct QuotaRefresher {
    #[cfg(feature = "ratelimit-redis")]
    url: String,
    #[cfg(feature = "ratelimit-redis")]
    conn: tokio::sync::OnceCell<redis_rl::aio::ConnectionManager>,
}

impl QuotaRefresher {
    /// Build a refresher for the given Redis URL. An empty URL yields a refresher
    /// that never connects (it logs once and leaves the set empty = fail-open).
    #[must_use]
    pub fn new(_url: String) -> Self {
        Self {
            #[cfg(feature = "ratelimit-redis")]
            url: _url,
            #[cfg(feature = "ratelimit-redis")]
            conn: tokio::sync::OnceCell::new(),
        }
    }

    /// Fetch `SMEMBERS quota:over` and swap it into `set`. Fail-OPEN: on any Redis
    /// error the previous snapshot is kept (the set is left unchanged) and a warn
    /// is logged — enforcement never becomes an availability SPOF.
    #[cfg(feature = "ratelimit-redis")]
    pub async fn refresh(&self, set: &QuotaSet) {
        if self.url.trim().is_empty() {
            return;
        }
        let mgr = self
            .conn
            .get_or_try_init(|| async {
                let client = redis_rl::Client::open(self.url.as_str())?;
                redis_rl::aio::ConnectionManager::new(client).await
            })
            .await;
        let Ok(mgr) = mgr else {
            tracing::warn!("quota refresh: redis connect failed — keeping prior snapshot (fail-open)");
            return;
        };
        let mut conn = mgr.clone();
        let res: redis_rl::RedisResult<Vec<String>> = redis_rl::cmd("SMEMBERS")
            .arg(QUOTA_OVER_SET)
            .query_async(&mut conn)
            .await;
        match res {
            Ok(members) => {
                let next: HashSet<String> = members.into_iter().collect();
                let n = next.len();
                set.replace(next);
                tracing::debug!(over_quota_tenants = n, "quota snapshot refreshed");
            }
            Err(e) => {
                tracing::warn!("quota refresh: SMEMBERS failed — keeping prior snapshot (fail-open): {e}");
            }
        }
    }

    /// No-op refresh on builds without the `ratelimit-redis` feature (nano/one):
    /// quota enforcement is unavailable there, the set stays empty (parity).
    #[cfg(not(feature = "ratelimit-redis"))]
    pub async fn refresh(&self, _set: &QuotaSet) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_set_is_never_over() {
        let q = QuotaSet::new();
        assert!(!q.is_over("anyone"), "empty set → no tenant over quota (fail-open/parity)");
        assert_eq!(q.tracked(), 0);
    }

    #[test]
    fn replace_then_membership() {
        let q = QuotaSet::new();
        let mut next = HashSet::new();
        next.insert("over-tenant".to_string());
        q.replace(next);
        assert!(q.is_over("over-tenant"), "tenant in the published set is over quota");
        assert!(!q.is_over("under-tenant"), "tenant absent from the set is under quota");
        assert_eq!(q.tracked(), 1);
    }

    #[test]
    fn replace_swaps_the_whole_set() {
        let q = QuotaSet::new();
        q.replace(["a".to_string()].into_iter().collect());
        assert!(q.is_over("a"));
        // A later publish that no longer lists "a" must clear it (under quota
        // again, e.g. period rollover) — replace is a SWAP, not a merge.
        q.replace(["b".to_string()].into_iter().collect());
        assert!(!q.is_over("a"), "prior over-quota tenant cleared by a new snapshot");
        assert!(q.is_over("b"));
    }
}
