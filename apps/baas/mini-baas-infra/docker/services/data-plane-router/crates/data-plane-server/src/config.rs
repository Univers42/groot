#[derive(Clone)]
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
    pub product_mode: String,
    pub adapter_registry_url: String,
    pub permission_bundle_url: String,
    /// Inline JSON policy bundle. When set, the in-Rust ABAC evaluator
    /// answers `/v1/permissions/decide` locally; the permission-engine HTTP
    /// roundtrip becomes optional.
    pub permission_bundle_inline: String,
    /// `abac` (default) or `rbac`. Reported via /v1/capabilities.
    pub permission_mode: String,
    /// Max simultaneously-open connection pools the registry keeps (LRU-evicted
    /// beyond this). Bounds memory under N-tenant fan-out (db_per_tenant /
    /// schema_per_tenant). Default 256; from `DATA_PLANE_MAX_POOLS`.
    pub max_pools: usize,
    /// B4-pools: collapse `shared_rls` tenants that share a connection target
    /// onto ONE pool (keyed by DSN/credential, not tenant). Safe ONLY for
    /// shared_rls — RLS scoping is re-applied per checkout from the request
    /// identity, so the pool carries no tenant state. schema_per_tenant pins
    /// `search_path` per pool and db_per_tenant/tenant_owned have distinct DSNs,
    /// so those keep per-tenant pools regardless. Default `false` (per-tenant
    /// pools, byte-parity). From `DATA_PLANE_SHARE_POOLS` (`1`/`true`/`on`).
    /// This is the 100K lever: 10K shared_rls tenants on one DB → 1 pool.
    pub share_pools: bool,
    /// Whether the capability-aware planner (G6) may route a `Federate` verdict
    /// to the analytics plane. Default `false` — until Trino is wired, a
    /// federation plan is lowered to a clean `NotImplemented`. From
    /// `DATA_PLANE_FEDERATION_ENABLED` (`1`/`true`/`on`).
    pub planner_federation_enabled: bool,

    // ---- gap G8: pluggable credential providers (all DISABLED by default) ---
    // These mirror the env vars `EnvMountResolver::from_env` /
    // `ProviderRegistry::from_env` actually read. They live here so the
    // provider contract has ONE documented home (no config drift); the resolver
    // remains the single reader so the empty defaults below keep every provider
    // DISABLED until explicitly configured.
    /// Service token for the adapter-registry credential provider. Empty by
    /// default → the adapter-registry provider is NOT registered. From
    /// `DATA_PLANE_ADAPTER_REGISTRY_TOKEN`. (The URL reuses the existing
    /// `adapter_registry_url` field.)
    pub adapter_registry_token: String,
    /// Vault origin for the Vault credential provider. Empty by default → the
    /// Vault provider is NOT registered. From `DATA_PLANE_VAULT_ADDR`.
    pub vault_addr: String,
    /// Vault token (env-only, never logged). Empty by default. From
    /// `DATA_PLANE_VAULT_TOKEN`. Both addr and token must be set for the Vault
    /// provider to register.
    pub vault_token: String,
    /// KV v2 path prefix for DSN secrets. From `DATA_PLANE_VAULT_DSN_PREFIX`.
    pub vault_dsn_prefix: String,
    /// Secret field that holds the DSN. From `DATA_PLANE_VAULT_DSN_FIELD`.
    pub vault_dsn_field: String,
    /// Resolved-DSN cache TTL in ms. `0` (default) → cache DISABLED. From
    /// `DATA_PLANE_CREDENTIAL_CACHE_TTL_MS`.
    pub credential_cache_ttl_ms: u64,

    /// Security posture (Phase 5/6): `baseline` (default) or `max`. From
    /// `SECURITY_MODE`. In `max`, external engine mounts must present a
    /// verifiable TLS chain (a `require` DSN is upgraded to verify-full instead
    /// of accepting any cert), and credentials are expected to be Vault-backed.
    /// `baseline` keeps libpq `require` semantics (encrypt, don't verify).
    pub security_mode: String,
    /// Optional custom CA bundle (PEM) used to verify external-mount TLS chains
    /// under verify-ca/verify-full. From `DATA_PLANE_TLS_CA_FILE`. Empty → the
    /// system/webpki roots only.
    pub tls_ca_file: String,

    // ---- Phase 7: direct front door (/data/v1), shadow — DISABLED by default ---
    /// tenant-control origin for Rust-native API-key verification. Go remains
    /// the sole identity authority — Rust only CALLS `/v1/keys/verify`. From
    /// `TENANT_CONTROL_URL`.
    pub tenant_control_url: String,
    /// Shared internal service token presented to tenant-control + adapter-
    /// registry on the bypass path (never logged). From `INTERNAL_SERVICE_TOKEN`.
    pub internal_service_token: String,
    /// Mounts the additive `/data/v1` front door (Kong → Rust directly). Default
    /// OFF — the bypass ships dormant; the existing `/query/v1` (→ query-router)
    /// path is untouched, so this is pure shadow until explicitly enabled and
    /// parity-proven. From `DATA_PLANE_BYPASS_ENABLED` (`1`/`true`/`on`).
    pub bypass_enabled: bool,
    /// Phase D — apply ABAC field masks in the Rust data path (cutover prep).
    /// OFF by default (the query-router still masks → byte-parity); flip ON
    /// (`DATA_PLANE_APPLY_MASKS=1`) once the query-router's mask is removed.
    pub apply_masks: bool,
    /// TTL (ms) for the bypass `api-key → identity` cache; default 30 000 to
    /// match the query-router. 0 disables (verify every request).
    pub verify_cache_ttl_ms: u64,
    /// G-ReadAudit (A6) — also audit-log successful READS, not just mutations.
    /// OFF by default (`DATA_PLANE_AUDIT_READS`) → byte-parity: the read path
    /// emits nothing extra and stays off the hot path. Flip ON to get a `read`
    /// audit event (tenant/engine/op/resource/returned_rows) per served read,
    /// at the cost of audit-log volume. Mutations are audited unconditionally.
    pub audit_reads: bool,
    /// Track-B metering (B1a) — per-tenant usage counters in the data plane.
    /// OFF by default → byte-parity: the read/write hot path takes ZERO extra
    /// branches, increments ZERO counters, emits ZERO usage events. Requires
    /// BOTH the master `METERING_ENABLED` AND `DATA_PLANE_METERING` to be truthy
    /// (master + per-emitter sub-flag, mirroring the plan's flag ladder). When
    /// ON, the read arm records `query.count`/`query.rows` and the mutation arm
    /// records `write.rows` into an in-memory aggregate drained by a background
    /// flusher that emits one structured `usage` tracing event per
    /// (tenant, metric) window.
    pub metering: bool,
    /// Track-B metering flush cadence (ms) — how often the background flusher
    /// drains non-zero `(tenant, metric)` aggregates and emits one `usage` event
    /// each. From `DATA_PLANE_METERING_FLUSH_MS` (default 60000); a gate can set
    /// it low to force a fast flush. Only consulted when `metering` is ON.
    pub metering_flush_ms: u64,
}

impl ServerConfig {
    /// Whether the router is running in the max-hardening security posture.
    #[must_use]
    pub fn is_max_security(&self) -> bool {
        self.security_mode.eq_ignore_ascii_case("max")
    }
}

impl ServerConfig {
    #[must_use]
    pub fn from_env() -> Self {
        Self {
            host: read_env("DATA_PLANE_ROUTER_HOST", "0.0.0.0"),
            port: read_env("DATA_PLANE_ROUTER_PORT", "4011")
                .parse()
                .unwrap_or(4011),
            product_mode: read_env("DATA_PLANE_ROUTER_PRODUCT_MODE", "shadow"),
            adapter_registry_url: read_env(
                "DATA_PLANE_ADAPTER_REGISTRY_URL",
                "http://adapter-registry-go:3021",
            ),
            permission_bundle_url: read_env(
                "DATA_PLANE_PERMISSION_BUNDLE_URL",
                "http://permission-engine:3050/permissions/bundles/latest",
            ),
            permission_bundle_inline: read_env("DATA_PLANE_PERMISSION_BUNDLE", ""),
            permission_mode: read_env("DATA_PLANE_PERMISSION_MODE", "abac"),
            max_pools: read_env("DATA_PLANE_MAX_POOLS", "256")
                .parse()
                .unwrap_or(256),
            share_pools: matches!(
                read_env("DATA_PLANE_SHARE_POOLS", "false").to_lowercase().as_str(),
                "1" | "true" | "on"
            ),
            planner_federation_enabled: matches!(
                read_env("DATA_PLANE_FEDERATION_ENABLED", "false")
                    .to_lowercase()
                    .as_str(),
                "1" | "true" | "on"
            ),
            // gap G8: every provider knob defaults to empty/disabled.
            adapter_registry_token: read_env("DATA_PLANE_ADAPTER_REGISTRY_TOKEN", ""),
            vault_addr: read_env("DATA_PLANE_VAULT_ADDR", ""),
            vault_token: read_env("DATA_PLANE_VAULT_TOKEN", ""),
            vault_dsn_prefix: read_env("DATA_PLANE_VAULT_DSN_PREFIX", "data-plane/dsn"),
            vault_dsn_field: read_env("DATA_PLANE_VAULT_DSN_FIELD", "dsn"),
            credential_cache_ttl_ms: read_env("DATA_PLANE_CREDENTIAL_CACHE_TTL_MS", "0")
                .parse()
                .unwrap_or(0),
            security_mode: read_env("SECURITY_MODE", "baseline"),
            tls_ca_file: read_env("DATA_PLANE_TLS_CA_FILE", ""),
            tenant_control_url: read_env("TENANT_CONTROL_URL", "http://tenant-control:3022"),
            internal_service_token: read_env("INTERNAL_SERVICE_TOKEN", ""),
            bypass_enabled: matches!(
                read_env("DATA_PLANE_BYPASS_ENABLED", "false").to_lowercase().as_str(),
                "1" | "true" | "on"
            ),
            apply_masks: matches!(
                read_env("DATA_PLANE_APPLY_MASKS", "false").to_lowercase().as_str(),
                "1" | "true" | "on"
            ),
            verify_cache_ttl_ms: read_env("DATA_PLANE_VERIFY_CACHE_TTL_MS", "30000")
                .parse()
                .unwrap_or(30000),
            audit_reads: matches!(
                read_env("DATA_PLANE_AUDIT_READS", "false").to_lowercase().as_str(),
                "1" | "true" | "on"
            ),
            // Track-B metering (B1a): ON only when BOTH the master flag AND the
            // per-emitter sub-flag are truthy — so the master can gate the whole
            // pipeline while the data-plane emitter is still independently
            // toggleable for an isolated gate. BOTH default `false` → byte-parity.
            metering: matches!(
                read_env("METERING_ENABLED", "false").to_lowercase().as_str(),
                "1" | "true" | "on"
            ) && matches!(
                read_env("DATA_PLANE_METERING", "false").to_lowercase().as_str(),
                "1" | "true" | "on"
            ),
            metering_flush_ms: read_env("DATA_PLANE_METERING_FLUSH_MS", "60000")
                .parse()
                .unwrap_or(60000),
        }
    }
}

impl std::fmt::Debug for ServerConfig {
    /// Redact the two plaintext token fields (`adapter_registry_token`,
    /// `vault_token`) so a stray `{:?}` of the whole config can never leak a
    /// secret. Mirrors the redacting Debug on `ProviderConfig`/`ProviderRegistry`
    /// in the pool crate. A set token shows `"<redacted>"`, an empty one shows
    /// `""` (so "is the provider configured?" stays observable); every other
    /// field prints normally.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ServerConfig")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("product_mode", &self.product_mode)
            .field("adapter_registry_url", &self.adapter_registry_url)
            .field("permission_bundle_url", &self.permission_bundle_url)
            .field("permission_bundle_inline", &self.permission_bundle_inline)
            .field("permission_mode", &self.permission_mode)
            .field("max_pools", &self.max_pools)
            .field("planner_federation_enabled", &self.planner_federation_enabled)
            .field("adapter_registry_token", &redact(&self.adapter_registry_token))
            .field("vault_addr", &self.vault_addr)
            .field("vault_token", &redact(&self.vault_token))
            .field("vault_dsn_prefix", &self.vault_dsn_prefix)
            .field("vault_dsn_field", &self.vault_dsn_field)
            .field("credential_cache_ttl_ms", &self.credential_cache_ttl_ms)
            .field("security_mode", &self.security_mode)
            .field("tls_ca_file", &self.tls_ca_file)
            .field("tenant_control_url", &self.tenant_control_url)
            .field("internal_service_token", &redact(&self.internal_service_token))
            .field("bypass_enabled", &self.bypass_enabled)
            .field("metering", &self.metering)
            .field("metering_flush_ms", &self.metering_flush_ms)
            .finish()
    }
}

/// Map a secret to a Debug-safe placeholder: `""` when empty (so config
/// presence stays observable), `"<redacted>"` otherwise. Never echoes the value.
fn redact(secret: &str) -> &'static str {
    if secret.is_empty() {
        ""
    } else {
        "<redacted>"
    }
}

fn read_env(key: &str, default_value: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default_value.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    // N1 — `{:?}` of ServerConfig must NOT leak a set token value, but MUST
    // still render the field (redacted) so the struct stays diagnosable.
    #[test]
    fn debug_redacts_tokens() {
        let mut cfg = ServerConfig::from_env();
        cfg.vault_token = "s.SUPERSECRET-vault-token".to_string();
        cfg.adapter_registry_token = "svc-SECRET-registry-token".to_string();
        cfg.vault_dsn_prefix = "data-plane/dsn".to_string(); // pin a non-secret field
        let dbg = format!("{cfg:?}");
        assert!(
            !dbg.contains("SUPERSECRET-vault-token"),
            "vault_token value leaked into Debug: {dbg}"
        );
        assert!(
            !dbg.contains("SECRET-registry-token"),
            "adapter_registry_token value leaked into Debug: {dbg}"
        );
        assert!(dbg.contains("<redacted>"), "redacted placeholder present: {dbg}");
        // A non-secret field still renders normally.
        assert!(dbg.contains("data-plane/dsn"), "non-secret field still printed: {dbg}");
    }

    // An empty token renders as "" (so "is it configured?" stays observable),
    // never the redaction placeholder.
    #[test]
    fn debug_empty_token_not_redacted() {
        let mut cfg = ServerConfig::from_env();
        cfg.vault_token = String::new();
        cfg.adapter_registry_token = String::new();
        let dbg = format!("{cfg:?}");
        assert!(dbg.contains("vault_token: \"\""), "empty vault_token shows empty: {dbg}");
    }
}
