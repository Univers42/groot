use crate::isolation::{safe_schema, Isolation};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PoolPolicy {
    pub min: u32,
    pub max: u32,
    pub idle_ttl_ms: u64,
    pub max_lifetime_ms: u64,
}

impl Default for PoolPolicy {
    fn default() -> Self {
        Self {
            min: 0,
            max: 10,
            idle_ttl_ms: 30_000,
            max_lifetime_ms: 1_800_000,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CredentialRef {
    pub provider: String,
    pub reference: String,
    pub version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DatabaseMount {
    pub id: String,
    pub tenant_id: String,
    pub project_id: Option<String>,
    pub engine: String,
    pub name: String,
    pub credential_ref: CredentialRef,
    #[serde(default)]
    pub pool_policy: PoolPolicy,
    pub capability_overrides: Option<Value>,
    /// Optional inline DSN supplied by the caller (e.g. the TS query-router
    /// proxy after it already fetched `connection_string` from the
    /// adapter-registry). When present the resolver uses this directly and
    /// the static `DATA_PLANE_MOUNTS` env-backed map becomes a fallback for
    /// purely server-side flows.
    #[serde(default)]
    pub inline_dsn: Option<String>,
    /// Tenant isolation strategy for this mount (wiki/02-layer-edition-model.md §5):
    ///   * `shared_rls` / absent — one schema, RLS + owner_id (the default);
    ///   * `schema_per_tenant`   — pin `search_path` to `tenant_<id>`;
    ///   * `db_per_tenant`       — a distinct DSN; no execution change.
    #[serde(default)]
    pub isolation: Option<String>,
}

impl DatabaseMount {
    #[must_use]
    pub fn pool_key(&self) -> String {
        format!(
            "{}/{}/{}/{}/{}",
            self.tenant_id,
            self.project_id.as_deref().unwrap_or("default"),
            self.id,
            self.engine,
            self.credential_ref.version,
        )
    }

    /// The parsed [`Isolation`] strategy for this mount. The wire `isolation`
    /// string is parsed exactly once here; every consumer matches the enum.
    /// Absent / empty / unknown degrades to [`Isolation::SharedRls`] (parity).
    #[must_use]
    pub fn isolation(&self) -> Isolation {
        Isolation::from_mount(self.isolation.as_deref())
    }

    /// The per-tenant schema name for a `schema_per_tenant` mount, or `None`
    /// for any other isolation strategy (shared / db-per-tenant need no
    /// `search_path` change).
    ///
    /// Thin delegator to [`crate::isolation::safe_schema`] — the single source
    /// of truth for the `tenant_` prefix + `[a-z0-9_]` sanitization shared by
    /// the PG `search_path` lowering and provisioning DDL. The result is a
    /// fixed, safe identifier callers may interpolate into `SET search_path`
    /// (which cannot bind parameters) without injection risk. `None` when the
    /// strategy isn't `schema_per_tenant` or the id sanitizes to empty.
    #[must_use]
    pub fn tenant_schema(&self) -> Option<String> {
        match self.isolation() {
            Isolation::SchemaPerTenant => safe_schema(&self.tenant_id),
            Isolation::SharedRls | Isolation::DbPerTenant => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mount(tenant: &str, isolation: Option<&str>) -> DatabaseMount {
        DatabaseMount {
            id: "db1".into(),
            tenant_id: tenant.into(),
            project_id: None,
            engine: "postgresql".into(),
            name: "n".into(),
            credential_ref: CredentialRef {
                provider: "adapter-registry".into(),
                reference: "r".into(),
                version: "1".into(),
            },
            pool_policy: PoolPolicy::default(),
            capability_overrides: None,
            inline_dsn: None,
            isolation: isolation.map(str::to_string),
        }
    }

    #[test]
    fn shared_and_absent_have_no_schema() {
        assert_eq!(mount("acme", None).tenant_schema(), None);
        assert_eq!(mount("acme", Some("shared_rls")).tenant_schema(), None);
        assert_eq!(mount("acme", Some("db_per_tenant")).tenant_schema(), None);
    }

    #[test]
    fn schema_per_tenant_derives_safe_name() {
        // Delegates to `safe_schema` (the single source of truth), so the derived
        // name carries the collision-free `_<hash8>` suffix. Assert it equals
        // `safe_schema` and keeps the human-readable prefix, not a brittle literal.
        assert_eq!(
            mount("acme", Some("schema_per_tenant")).tenant_schema(),
            safe_schema("acme")
        );
        // slugs / uuids with separators sanitize to underscores
        let s = mount("t-Acme_2", Some("schema_per_tenant")).tenant_schema().unwrap();
        assert!(s.starts_with("tenant_t_acme_2_"), "{s}");
        let s = mount("00000000-0000-4000-8000-000000000003", Some("schema_per_tenant"))
            .tenant_schema()
            .unwrap();
        assert!(s.starts_with("tenant_00000000_0000_4000_8000_000000000003_"), "{s}");
    }

    #[test]
    fn injection_chars_are_neutralised() {
        let s = mount("a; DROP SCHEMA public; --", Some("schema_per_tenant"))
            .tenant_schema()
            .unwrap();
        assert!(s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'));
        assert!(s.starts_with("tenant_a"));
    }

    #[test]
    fn empty_after_sanitize_is_none() {
        assert_eq!(mount("---", Some("schema_per_tenant")).tenant_schema(), None);
    }

    #[test]
    fn distinct_tenants_get_distinct_pool_keys_and_schemas() {
        // The cross-tenant-leak guard: two DISTINCT raw tenant ids must NEVER
        // share a pool_key NOR a schema. pool_key keys on the raw id, so two ids
        // that previously sanitized to the SAME schema (`t-acme` / `t.acme`) got
        // separate pools pointing at one schema — a leak. Both axes must differ.
        let a = mount("t-acme", Some("schema_per_tenant"));
        let b = mount("t.acme", Some("schema_per_tenant"));
        assert_ne!(a.pool_key(), b.pool_key(), "distinct tenants → distinct pool_key");
        assert_ne!(
            a.tenant_schema(),
            b.tenant_schema(),
            "distinct tenants → distinct schema (collision-free)"
        );
        // Both still resolve to a schema (neither sanitizes to empty).
        assert!(a.tenant_schema().is_some() && b.tenant_schema().is_some());
    }
}
