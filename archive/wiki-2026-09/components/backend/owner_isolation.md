# Rust data plane — per-request owner-scoping (the primary data guardrail)

> **In one sentence.** Per-request owner-scoping is the runtime data guardrail that validates every single query runs as a specific owner (authenticated user or tenant), not by connection pool state—the technique that lets thousands of tenants safely share one database pool.

## What it is & why it exists

[Owner-scoping](glossary.md#owner-scoping) is the load-bearing security frontier of the Grobase data plane. Every request carries a [`RequestIdentity`](glossary.md#requestidentity) struct (tenant_id, user_id, roles, scopes) resolved once from the API key via the control plane. The data plane then executes the query with that identity—never by pool configuration, never by connection state, always by explicit per-request injection. This is what makes it possible for 10,000 tenants to run on a single shared connection pool without cross-tenant leaks. The system also supports four tenant-isolation strategies (SharedRls with row-level filtering, SchemaPerTenant, DbPerTenant, and TenantOwned for external databases), but they all rest on the same per-request identity principle.

The component is engine-agnostic by design—the same identity and isolation logic hold across all 8 database adapters (Postgres, MySQL, MongoDB, Redis, SQLite, MSSQL, DynamoDB, HTTP). A fix that works for Postgres but breaks MongoDB is not done; ownership enforcement is identical across all engines.

## How it works

- The control plane's [identity service](glossary.md#requestidentity) verifies an API key cleartext and returns a RequestIdentity struct (tenant_id, user_id, roles, scopes, source—all cryptographically certified).
- The [query router](glossary.md#query-router-query-router) receives an HTTP request with that API key, calls POST /v1/keys/verify to get the identity, and forwards the query to the Rust data plane with the identity attached.
- For each request, the data plane calls RequestIdentity::owner_principal() to derive the effective data owner: user_id if authenticated, else tenant_id (the user ?? tenant rule, one source of truth)—this is the [owner principal](glossary.md#owner-principal).
- The system looks up the target [DatabaseMount](glossary.md#databasemount) and reads its [isolation strategy](glossary.md#isolation-strategy) (shared-RLS, schema-per-tenant, db-per-tenant, or tenant-owned).
- Isolation::scope() is called once per request to produce a [ScopeDirective](glossary.md#scopedirective): for Postgres+schema-per-tenant it returns SetSearchPath with the collision-free tenant schema name; for MySQL/MongoDB+schema-per-tenant it returns UseNamespace; for shared-RLS and db-per-tenant it returns None (no per-request scoping needed).
- The [engine adapter](glossary.md#engine-adapter) executes the operation with that identity and scope directive. For shared-RLS, the adapter injects owner_id filters on reads/writes and [RLS](glossary.md#rls-row-level-security) policies; for schema-per-tenant adapters execute SET search_path / USE database / prefix keys before running the query.
- On every read: rows are filtered to owner_principal only. On every write (insert/update/delete): owner_id is stamped/filtered. On DDL: owner_id columns are synthesized by the adapter only if isolation.owner_scoped() is true.
- A flag-gated [admin bypass](glossary.md#admin-bypass-data_plane_admin_bypass--f2) (DATA_PLANE_ADMIN_BYPASS, OFF by default) can be applied when is_admin() is true (roles contain admin/superadmin/service_role, or scopes contain admin/apikey:admin), but the flag gate itself is a second lock—never widening access on its own.
- The [safe_schema](glossary.md#safe-schema-derivation) function ensures the derived schema name is [injection-safe](glossary.md#safe-schema-derivation) (all non-alphanumeric → underscore, max 40 chars fragment + 8-char [FNV-1a hash](glossary.md#fnv-1a-hash) of raw id) and collision-free (distinct tenant ids always → distinct schema names even if they sanitize identically).

## The code that does it

**What to look at:** Core identity struct and the two load-bearing methods: owner_principal (user if authenticated, else tenant) and is_admin (bypass check).

```rust
// apps/grobase/src/data-plane-router/crates/data-plane-core/src/identity.rs:24-70
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RequestIdentity {
    pub tenant_id: String,
    pub project_id: Option<String>,
    pub app_id: Option<String>,
    pub user_id: Option<String>,
    #[serde(default)]
    pub roles: Vec<String>,
    #[serde(default)]
    pub scopes: Vec<String>,
    pub source: IdentitySource,
}

impl RequestIdentity {
    #[must_use]
    pub fn is_tenant_scoped(&self) -> bool {
        !self.tenant_id.trim().is_empty()
    }

    /// The owner principal for per-request scoping: the authenticated user, or
    /// the tenant when there is no user. Borrowed (`&str`) so callers allocate
    /// only when they must — SQL/NoSQL owner stamps `.to_string()` it, the
    /// Postgres RLS GUC consumes it by reference. The single source of truth for
    /// the `user_id ?? tenant_id` rule (was reimplemented per engine adapter).
    #[must_use]
    pub fn owner_principal(&self) -> &str {
        self.user_id.as_deref().unwrap_or(self.tenant_id.as_str())
    }

    /// Whether this caller is an administrator — a role/scope that an
    /// owner-scope bypass (F2, `DATA_PLANE_ADMIN_BYPASS`) honours so an admin
    /// reads/updates/deletes across owners. True when `roles` contains `admin`
    /// / `superadmin` / `service_role`, or `scopes` carries `admin` /
    /// `apikey:admin` (the projected API-key admin scope). Pure over the
    /// already-verified identity — the bypass that consults it is itself
    /// flag-gated OFF by default, so this never widens access on its own.
    #[must_use]
    pub fn is_admin(&self) -> bool {
        self.roles
            .iter()
            .any(|r| r == "admin" || r == "superadmin" || r == "service_role")
            || self
                .scopes
                .iter()
                .any(|s| s == "admin" || s == "apikey:admin")
    }
}
```

**What to look at:** Isolation enum (4 strategies) and ScopeDirective enum; the parse-once contract and the strategy×engine-class routing table.

```rust
// apps/grobase/src/data-plane-router/crates/data-plane-core/src/isolation.rs:41-154
/// The selectable per-mount tenant isolation strategy.
///
/// `Copy` + small: it lives by value on the pool and is matched on the hot
/// path with no allocation or dynamic dispatch.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Isolation {
    /// One shared schema; rows separated by RLS + `owner_id`. The default and
    /// the only strategy that existed before G5.
    #[default]
    SharedRls,
    /// A distinct schema per tenant (`tenant_<id>`); pin `search_path` to it.
    SchemaPerTenant,
    /// A distinct database/DSN per tenant; the resolver must supply a tenant
    /// DSN (no fall back to a shared one).
    DbPerTenant,
    /// The mount IS one tenant's database (an external client DB the platform
    /// dashboards, e.g. a customer's Supabase project): no per-row
    /// `owner_id` scoping on writes and no `owner_id` DDL synthesis — the
    /// tables belong to the tenant wholesale and predate the platform.
    ///
    /// SAFETY: dropping row-level owner scoping cannot cross tenants by
    /// construction — tenant gating already happened upstream at key→mount
    /// resolution (`mount.tenant_id == caller tenant`); a foreign tenant's
    /// key never resolves this mount at all.
    TenantOwned,
}

impl Isolation {
    /// Parse a mount's wire `isolation` field. NEVER errors: `None`, empty, or
    /// any unrecognised value degrades to [`Isolation::SharedRls`] so an
    /// existing or mistyped mount behaves exactly as it does today. The set of
    /// *accepted* values is enforced upstream in Go provisioning, not here.
    ///
    /// ```
    /// use data_plane_core::Isolation;
    ///
    /// // Known values parse to their typed variant (whitespace-tolerant).
    /// assert_eq!(Isolation::from_mount(Some("schema_per_tenant")), Isolation::SchemaPerTenant);
    /// assert_eq!(Isolation::from_mount(Some(" tenant_owned ")), Isolation::TenantOwned);
    ///
    /// // The parity invariant: absent / empty / unknown all degrade to the
    /// // historical default rather than erroring — a typo can never 500.
    /// assert_eq!(Isolation::from_mount(None), Isolation::SharedRls);
    /// assert_eq!(Isolation::from_mount(Some("typo")), Isolation::SharedRls);
    /// ```
    #[must_use]
    pub fn from_mount(isolation: Option<&str>) -> Self {
        match isolation.map(str::trim) {
            Some("schema_per_tenant") => Self::SchemaPerTenant,
            Some("db_per_tenant") => Self::DbPerTenant,
            Some("tenant_owned") => Self::TenantOwned,
            // "shared_rls", "", unknown, None → the safe default.
            _ => Self::SharedRls,
        }
    }

    /// Whether the platform owner-scopes rows on this mount (insert injects
    /// `owner_id`; update/delete filter on it; DDL synthesizes the column).
    /// Everything except [`Isolation::TenantOwned`] — pools gate every
    /// owner-touching site on this single predicate.
    ///
    /// ```
    /// use data_plane_core::Isolation;
    ///
    /// // Every platform-managed strategy owner-scopes every read and write.
    /// assert!(Isolation::SharedRls.owner_scoped());
    /// assert!(Isolation::SchemaPerTenant.owner_scoped());
    /// assert!(Isolation::DbPerTenant.owner_scoped());
    ///
    /// // A tenant-owned external DB is the sole exception: the tables predate
    /// // the platform, so no per-row owner_id is injected or filtered.
    /// assert!(!Isolation::TenantOwned.owner_scoped());
    /// ```
    #[must_use]
    pub fn owner_scoped(&self) -> bool {
        !matches!(self, Self::TenantOwned)
    }

    /// The engine-neutral per-request scoping instruction for this strategy,
    /// given the mount + verified identity. A branchless `match` (no heap, no
    /// `Box<dyn>`): the only allocation is the schema/namespace string, and
    /// only for the strategies that actually need one.
    ///
    /// * [`Isolation::SharedRls`] → always [`ScopeDirective::None`] (parity).
    /// * [`Isolation::SchemaPerTenant`] →
    ///   - PostgreSQL: [`ScopeDirective::SetSearchPath`] — Postgres is the only
    ///     engine with a true `search_path`, set per transaction.
    ///   - MySQL / MongoDB / Redis: [`ScopeDirective::UseNamespace`] — a
    ///     per-tenant database (`USE`/`client.database`) or key-prefix segment.
    ///   - HTTP / unknown: [`ScopeDirective::None`] (no schema concept).
    /// * [`Isolation::DbPerTenant`] → [`ScopeDirective::None`]: the per-tenant
    ///   separation is the DSN itself, resolved before the pool is opened, so
    ///   no per-request scoping is needed.
    ///
    /// If the tenant id sanitizes to empty we fall back to `None` rather than
    /// pinning a bogus schema — the shared-schema behaviour, which is safe.
    #[must_use]
    pub fn scope(&self, mount: &DatabaseMount, _identity: &RequestIdentity) -> ScopeDirective {
        match self {
            Self::SharedRls | Self::DbPerTenant | Self::TenantOwned => ScopeDirective::None,
            Self::SchemaPerTenant => match EngineClass::of(&mount.engine) {
                EngineClass::SearchPath => match safe_schema(&mount.tenant_id) {
                    Some(schema) => ScopeDirective::SetSearchPath { schema },
                    None => ScopeDirective::None,
                },
                EngineClass::Namespace => match safe_schema(&mount.tenant_id) {
                    Some(namespace) => ScopeDirective::UseNamespace { namespace },
                    None => ScopeDirective::None,
                },
                EngineClass::Unscoped => ScopeDirective::None,
            },
        }
    }
```

**What to look at:** Safe schema derivation: injection-safe (all non-alphanumeric → underscore) with collision-free hash suffix to prevent cross-tenant schema collision on distinct raw ids.

```rust
// apps/grobase/src/data-plane-router/crates/data-plane-core/src/isolation.rs:256-295
pub fn safe_schema(tenant_id: &str) -> Option<String> {
    let mapped: String = tenant_id
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' {
                c.to_ascii_lowercase()
            } else {
                '_'
            }
        })
        .collect();
    let trimmed = mapped.trim_matches('_');
    if trimmed.is_empty() {
        return None;
    }
    // Mapping precedes truncation, so each retained char is ASCII → byte-safe.
    let fragment: String = trimmed.chars().take(MAX_SCHEMA_FRAGMENT).collect();
    let hash8 = tenant_hash8(tenant_id);
    Some(format!("tenant_{fragment}_{hash8}"))
}

/// First 8 hex chars of a stable 64-bit FNV-1a hash of the **raw** tenant id.
///
/// FNV-1a is chosen over a crypto hash deliberately: this is a *collision-
/// avoidance* tag for namespacing, NOT a security primitive, so we want a fixed,
/// dependency-free, allocation-free function with good dispersion over short
/// ids. (No `sha2`/`blake` dependency is pulled into `data-plane-core` for this.)
/// The constant is the published 64-bit FNV offset basis / prime, so the value
/// is stable across builds and machines — the same id always hashes the same.
fn tenant_hash8(raw: &str) -> String {
    const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;
    let mut hash = FNV_OFFSET;
    for byte in raw.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(FNV_PRIME);
    }
    // 32 high bits → exactly 8 lowercase hex chars, zero-padded.
    format!("{:08x}", (hash >> 32) as u32)
}
```

**What to look at:** Core pool interface: every execute call receives the per-request RequestIdentity, enabling per-request owner-scoping on every operation.

```rust
// apps/grobase/src/data-plane-router/crates/data-plane-core/src/ports.rs:52-62
#[async_trait]
pub trait EnginePool: Send + Sync {
    fn mount_id(&self) -> &str;
    async fn execute(
        &self,
        operation: DataOperation,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult>;
    async fn begin(&self, request: crate::TxBeginRequest) -> DataPlaneResult<Box<dyn TxHandle>>;
    async fn close(&self) -> DataPlaneResult<()>;
```

## Where it sits in the request flow

Per-request owner-scoping sits at the execution boundary in the data plane, downstream of [Kong](glossary.md#kong) (gateway) and the query-router (identity verification), upstream of the eight engine adapters and the actual database. Kong handles TLS/rate-limiting/auth, the query-router resolves API key → RequestIdentity via the control plane, then the data plane executes the query in isolation.rs + identity.rs to enforce the owner-principal rule, and finally delegates to each adapter (postgres, mysql, mongo, etc.) to apply the engine-native equivalent (RLS, search_path, USE namespace, key prefixes). RLS policies and row filters then run inside Postgres/MySQL/MongoDB itself.

## Remember this

> Every query runs as a specific owner (user or tenant) resolved fresh per request, never cached by connection—this is why 10K tenants can share one pool safely.

---
**See also:** [reverse_proxy.md](reverse_proxy.md) · [query-router-ApiKeyMiddleware.md](query-router-ApiKeyMiddleware.md) · [rls.md](rls.md) · [ABAC_RBAC.md](ABAC_RBAC.md) · [Glossary](glossary.md)
