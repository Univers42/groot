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
