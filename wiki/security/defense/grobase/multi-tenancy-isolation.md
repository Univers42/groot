# Multi-Tenancy Isolation — grobase (the BaaS backend)

> grobase enforces tenant boundary at every layer — registry lookup, schema routing, DB role, and per-request SQL — so no combination of a valid API key, a guessed mount UUID, or a forged request body can read or write another tenant's rows.

## What it is (the concept)

**Multi-tenancy isolation** is the set of controls that prevents one tenant's requests from accessing another tenant's data when multiple tenants share the same physical infrastructure. The threat surface includes **Broken Object-Level Authorization (BOLA)**, **schema/namespace collision**, **RLS bypass via a privileged DB role**, and **connection-state leakage** across pooled connections. Defense in depth requires that each of these attack surfaces be closed independently, so the failure of any one control does not expose data.

## What it defends against

See [Cross-Tenant Data Leakage](../../attack/multi-tenancy-isolation.md).

In grobase's context, tenants share a single Postgres instance (and optionally a single connection pool) for the control plane and for each multi-tenant mount. Without explicit per-request and per-query scoping, a tenant who knows (or can enumerate) another tenant's mount UUID, database connection string, or row identifier could read or mutate that tenant's data. The controls below address this across every layer: the control plane registry, the Rust data-plane router, the Postgres DB role model, and the SQL layer.

## How grobase implements it

Five independently verifiable controls compose into the full isolation guarantee.

### 1. Explicit `tenant_id` binding atop RLS in the adapter registry

The Go control plane's DB role (`adapter_registry_role`) bypasses RLS, so every registry query binds `tenant_id` explicitly as a query parameter rather than relying on RLS policies.

In [`src/control-plane/internal/adapterregistry/connection.go`](../../../../apps/grobase/src/control-plane/internal/adapterregistry/connection.go), `loadMountRow` documents the invariant and enforces it:

```go
// loadMountRow reads the mount under EXPLICIT tenant scope (not just RLS): the
// control-plane DB role bypasses RLS, so without `AND tenant_id = $2` a mount
// UUID would be a bearer capability — any valid tenant key + dbId would read
// another tenant's mount.
err := s.db.TenantTx(ctx, userID, func(tx pgx.Tx) error {
    row := tx.QueryRow(ctx,
        `SELECT … FROM public.tenant_databases WHERE id = $1 AND tenant_id = $2`, id, userID)
```

The `List` and `FindOne` methods in [`src/control-plane/internal/adapterregistry/query.go`](../../../../apps/grobase/src/control-plane/internal/adapterregistry/query.go) carry the same discipline:

```go
// Defense-in-depth: binds tenant_id EXPLICITLY (atop RLS), so isolation
// never depends on the DB role / RLS being active.
WHERE tenant_id = $1          -- List
WHERE id = $1 AND tenant_id = $2  -- FindOne
```

The Rust data-plane mirrors this: [`src/data-plane-router/crates/data-plane-server/src/auth.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-server/src/auth.rs) sends `X-Tenant-Id` on every call to the registry `/connect` endpoint and maps a registry 404 to `AuthError::NotFound("mount '{db_id}' not found for this tenant")` — a cross-tenant `db_id` is never resolved.

### 2. Injection-safe schema/namespace derivation for `schema_per_tenant` mounts

A mount's `isolation` field determines how tenants are physically separated on each engine. Unknown or empty values degrade to `SharedRls` (never error). For `schema_per_tenant` mounts, the per-tenant schema name must be safe to interpolate into `SET LOCAL search_path` (which cannot bind parameters).

[`src/data-plane-router/crates/data-plane-core/src/isolation.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-core/src/isolation.rs) derives the name with `safe_schema`:

```rust
// Every non-[a-z0-9_] char is mapped to '_', the fragment is capped at 40
// chars, and a stable 8-char FNV-1a hash suffix prevents collision between
// distinct raw ids that sanitize to the same fragment.
let mapped: String = tenant_id.chars().map(|c| {
    if c.is_ascii_alphanumeric() || c == '_' { c.to_ascii_lowercase() } else { '_' }
}).collect();
Some(format!("tenant_{fragment}_{hash8}"))
```

The sanitized name is then interpolated in [`src/data-plane-router/crates/data-plane-pool/src/postgres/tx.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-pool/src/postgres/tx.rs) `apply_search_path`:

```rust
// The schema name is pre-sanitized to [a-z0-9_] by DatabaseMount::tenant_schema,
// so interpolating it here (SET cannot bind parameters) carries no injection risk.
let sql = format!("SET LOCAL search_path TO {schema}, public");
```

Unit tests `safe_schema_neutralizes_injection` and `safe_schema_is_collision_free_for_previously_colliding_ids` are inline in `isolation.rs`.

### 3. Per-table shared-resource opt-in and per-mount `read_scoped` opt-in — both OFF by default

Two knobs that narrow the baseline-owner-scope model are opt-in and default to OFF (byte-parity with the historical behavior).

`DATA_PLANE_PER_TABLE_ISOLATION` in [`src/data-plane-router/crates/data-plane-pool/src/postgres/adapter.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-pool/src/postgres/adapter.rs) controls shared-resource tables: when OFF, `shared_resources` is forced empty, so every table is owner-stamped. When ON, only tables explicitly listed in a mount's `shared_resources` column skip owner-stamping.

Per-mount `read_scoped` is a boolean column added by migration [`scripts/migrations/postgresql/070_mount_read_scoped.sql`](../../../../apps/grobase/scripts/migrations/postgresql/070_mount_read_scoped.sql):

```sql
-- DEFAULT false on every existing row ⇒ no per-mount opt-in ⇒ read_predicate is
-- decided by the global env flag alone = byte-identical to every pre-070 row.
ALTER TABLE public.tenant_databases ADD COLUMN IF NOT EXISTS read_scoped boolean NOT NULL DEFAULT false;
```

[`connection.go`](../../../../apps/grobase/src/control-plane/internal/adapterregistry/connection.go) stamps both overrides only when set (`mergeReadScoped` / `mergeSharedResources`), leaving `CapabilityOverrides` untouched for mounts that opted into neither. The Rust pool derives its `read_predicate` as `read_predicate_enabled() || mount.read_scoped()`.

### 4. PostgREST connects as `NOINHERIT NOBYPASSRLS` `authenticator` and `SET ROLE` per request

Migration [`scripts/migrations/postgresql/065_least_privilege_rls.sql`](../../../../apps/grobase/scripts/migrations/postgresql/065_least_privilege_rls.sql) closes the superuser-PostgREST weakness documented in the migration header (the prior `postgres` superuser connection rendered every RLS policy decorative):

```sql
-- NOBYPASSRLS + NOSUPERUSER are the load-bearing ones.
CREATE ROLE authenticator NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE;
GRANT anon, authenticated, service_role TO authenticator;
```

Because `authenticator` is `NOINHERIT`, membership grants do NOT silently confer privileges — they apply only after an explicit `SET ROLE`. A missing or forged JWT role claim yields the `anon` role's empty view, never an elevated view.

The same migration walks all RLS-enabled tables and issues `ALTER TABLE … FORCE ROW LEVEL SECURITY` so the table owner is also bound — `ENABLE RLS` alone still exempts the table owner.

The compose service [`orchestrators/compose/base/auth-api.yml`](../../../../apps/grobase/orchestrators/compose/base/auth-api.yml) wires this at runtime:

```yaml
# PostgREST connects as the dedicated non-superuser `authenticator` role
# (NOBYPASSRLS) … The superuser DSN is NEVER used here.
PGRST_DB_URI: ${PGRST_DB_URI:-postgres://authenticator:${AUTHENTICATOR_PASSWORD:-authenticator}@postgres:5432/postgres}
PGRST_DB_ANON_ROLE: anon
```

[`scripts/db/db-bootstrap.psql`](../../../../apps/grobase/scripts/db/db-bootstrap.psql) creates the role before PostgREST starts (lines 46–53: `CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD :'authenticator_pwd'`), and also creates the tenant-scoped RLS policies on `public.tenant_databases` that read `public.current_tenant_id()` (lines 136–146).

### 5. Per-request transaction-scoped RLS GUCs and server-controlled `owner_id` stamping

Isolation is enforced per request, not by pool or connection state. Every query runs inside a transaction that first sets three transaction-local GUCs via `set_config(..., true)`:

In [`src/data-plane-router/crates/data-plane-pool/src/postgres/tx.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-pool/src/postgres/tx.rs), `apply_rls_context`:

```rust
// set_config(..., true) scopes them to the current transaction.
client.execute(
    "SELECT set_config('app.current_user_id', $1, true),
            set_config('app.current_tenant_id', $2, true),
            set_config('request.jwt.claims', $3, true)",
    &[&principal, &tenant, &claims],
).await
```

On INSERT/UPSERT, [`src/data-plane-router/crates/data-plane-pool/src/postgres/crud.rs`](../../../../apps/grobase/src/data-plane-router/crates/data-plane-pool/src/postgres/crud.rs) strips any client-supplied `owner_id` and re-injects the server-controlled value:

```rust
// Strip any client-supplied owner_id (server controls tenant scope) and
// re-inject the trusted value from the verified identity.
if owner_scoped && col == "owner_id" { continue; }  // drop client override
// … then:
columns.push(quote_ident("owner_id")?);
params.push(Box::new(PostgresPool::principal(identity).to_string()));
```

On UPDATE and DELETE, the WHERE clause is extended with `AND owner_id = $N` so a row belonging to a different owner is simply not found (0 rows affected, not a 403 — which also prevents enumeration).

## How we know it is applied

**Control 1 (registry tenant-scope):** gate `scripts/verify/m158-admin-tenant-scope.sh` asserts the asymmetry live — an anon API key against the adapter-registry admin route yields 403; the service key yields 200. Go tests over `adapterregistry` run in CI (`go test ./...` over `src/control-plane`).

**Control 2 (safe_schema):** `isolation.rs` carries inline Rust doctests and unit tests (`safe_schema_neutralizes_injection`, `safe_schema_is_collision_free_for_previously_colliding_ids`) that run under `cargo test --workspace` in CI.

**Control 3 (opt-in defaults):** migration `070` runs in the numbered migration loop in CI; `adapter.rs` unit tests (including `read_scoped_true_forces_on_even_when_global_off`) run under `cargo test --workspace`. Live owner-isolation under shared pools is gated by `scripts/verify/m46-share-pools-isolation.sh`.

**Control 4 (NOBYPASSRLS authenticator):** `db-bootstrap.psql` is mounted and executed at container start (as a one-shot `db-bootstrap` service in `orchestrators/compose/base/data-engines.yml`), so the role exists before PostgREST connects. Migration 065 runs in the numbered migration loop and idempotently re-affirms the safety attributes on every run. Gate `scripts/verify/m98-pooler-parity.sh` (lines 186–218) creates a `NOSUPERUSER NOBYPASSRLS` app role, forces RLS, seeds rows for two owners (A=2, B=1), and asserts cross-owner isolation survives a pooler checkout.

**Control 5 (per-request RLS GUCs):** this is the live execution path of every Postgres adapter request. Cross-tenant isolation under shared pools is gated by `scripts/verify/m46-share-pools-isolation.sh` and `scripts/verify/m133-cross-tenant-safety.sh`.

## Reference

The [OWASP Multi-Tenant Application Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Multi_Tenant_Security_Cheat_Sheet.html) identifies tenant-context injection, BOLA via shared identifiers, and insufficient DB-role separation as the primary multi-tenancy failure modes. grobase addresses each: the tenant identifier is never client-supplied (it is derived from the verified API key), mount UUIDs are not bearer capabilities (explicit `AND tenant_id = $2` closes the BOLA gap), and the public DB surface uses a `NOBYPASSRLS` role (not a superuser) so RLS policies are structurally enforced.

## Residual risk / assumptions

- **`tenant_owned` mounts** drop per-row `owner_id` scoping by design (the tables predate the platform and have no `owner_id` column). Tenant gating still happens at key→mount resolution, so a foreign tenant cannot reach these tables at all — but within the mount, all rows are readable by the mount's owner. This is the documented contract for externally-managed databases.
- **`service_role` is `BYPASSRLS`** (by design, for internal service paths). Any service-role JWT issued to an untrusted caller would bypass all RLS policies. Key issuance for service-role tokens must be restricted to administrative paths.
- **Schema-per-tenant isolation** relies on the Rust data plane correctly calling `apply_search_path` before each query. A bug that skips or mis-derives the schema name would collapse tenants onto the shared `public` schema, where RLS GUCs (control 5) would still provide a second line of defense.
- **Connection pool state** is cleared by transaction-scoped `set_config(..., true)`: GUCs revert at transaction end, so a subsequent checkout from the same connection starts clean. This is only true if the transaction boundary is correctly committed or rolled back; a half-open transaction leaked to the pool would carry stale GUCs.
- The explicit `tenant_id` binding (control 1) closes the BOLA gap only for the Go control-plane registry. Any future query path added to the control plane that does not run inside a `TenantTx` (which enforces the binding) would need to be audited separately.
