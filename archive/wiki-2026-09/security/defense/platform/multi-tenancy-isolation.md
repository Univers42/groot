# Multi-Tenancy Isolation — platform / infrastructure (cross-cutting)

> PostgreSQL Row-Level Security policies bound to `current_tenant_id()` ensure that an authenticated session can only read and write rows belonging to its own tenant, enforced at the database engine before any data leaves the server.

## What it is (the concept)

**Multi-tenancy isolation** is the guarantee that one tenant's data is structurally inaccessible to another tenant, even when both share the same database schema or connection pool. **Row-Level Security (RLS)** is the PostgreSQL mechanism that evaluates a predicate on every row access, re-checking identity at query time regardless of how the connection arrived. **`FORCE ROW LEVEL SECURITY`** closes the superuser-bypass loophole by applying RLS even to table owners. The combination means no amount of crafted SQL can return a row whose `tenant_id` does not match the session's resolved identity.

## What it defends against

See [Cross-Tenant Data Leakage](../../attack/multi-tenancy-isolation.md). In this stack the threat is concrete: the Kong API gateway exposes PostgREST at `/rest/v1` with a public anon API key by design, so **PostgreSQL RLS and column grants are the only data wall** — there is no Kong ACL plugin between the client and the database. An attacker who supplies a valid JWT for tenant A must not be able to enumerate or modify rows provisioned for tenant B's `tenant_databases` registry, workspace objects, or any other multi-tenant table.

## How the platform implements it

The control is in [`models/rls-hardening-migration.sql`](../../../../models/rls-hardening-migration.sql), applied idempotently at bootstrap. Three layers work together:

**Layer 1 — Tenant-scoped policies on `tenant_databases`** (lines 131–150): an existence-guarded block activates only when both the `tenant_databases` table and the `current_tenant_id()` GUC function are present, making it safe to run on lean installs that omit the heavier BaaS plane.

```sql
CREATE POLICY tenant_databases_select ON public.tenant_databases
  FOR SELECT TO authenticated USING (tenant_id = current_tenant_id());
CREATE POLICY tenant_databases_insert ON public.tenant_databases
  FOR INSERT TO authenticated WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_databases_update ON public.tenant_databases
  FOR UPDATE TO authenticated USING (tenant_id = current_tenant_id())
                              WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_databases_service_role_all ON public.tenant_databases
  FOR ALL TO service_role USING (true) WITH CHECK (true);
```

The `service_role` catch-all policy preserves RPC and provisioning paths (which run as `service_role`, which carries `bypassrls`) without widening the `authenticated` surface.

**Layer 2 — FORCE RLS on all policy-protected tables** (lines 165–183): even if a future migration creates a table-owning role, `FORCE ROW LEVEL SECURITY` prevents that owner from bypassing the policies. The guarded list covers every table that holds cross-tenant-sensitive data — `users`, `sessions`, `osionos_workspaces`, `osionos_workspace_members`, `osionos_pages`, `calendar_accounts`, and others.

```sql
EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', t);
```

**Layer 3 — Default-privilege revocation** (lines 92–93): future tables are not auto-opened to `anon` or `authenticated` roles at creation time.

```sql
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM anon, authenticated;
```

**Layer 4 — Internal table lockdown** (lines 71–86): `schema_registry` and `track_binocle_runtime_migrations` have their grants fully revoked from `anon` and `authenticated`, RLS enabled and forced, and a `service_role`-only policy applied — preventing a tenant from reading or writing infrastructure metadata.

## How we know it is applied

The migration is wired into the bootstrap sequence in [`apps/grobase/scripts/db/apply-project-sql.sh`](../../../../apps/grobase/scripts/db/apply-project-sql.sh), line 69:

```sh
$psql_base -f /project-init/07-rls-hardening.sql
$psql_base -c "INSERT INTO track_binocle_runtime_migrations (marker)
               VALUES ('${marker}_rls_hardening') ON CONFLICT DO NOTHING"
```

The second line writes a deduplication marker into `track_binocle_runtime_migrations`, so every startup confirms execution idempotently. This script is the `command` of the bootstrap service defined in [`apps/grobase/orchestrators/compose/docker-compose.track-binocle.yml`](../../../../apps/grobase/orchestrators/compose/docker-compose.track-binocle.yml) (line 77), meaning the RLS hardening runs unconditionally on every `make all` bring-up before any frontend connects.

The comment at line 67–68 of the bootstrap script makes the contract explicit:

> RLS hardening (idempotent + existence-guarded) — runs after the inline grants so its tightened anon column grant on public.users is the final word.

## Reference

The [OWASP Multi-Tenant Application Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Multi_Tenant_Security_Cheat_Sheet.html) frames data isolation as the primary trust boundary in shared-infrastructure deployments. This stack's approach maps directly to the cheat sheet's recommendation that tenant identity be resolved from the credential (not a client-supplied header) and enforced at the storage layer, which is what `current_tenant_id()` and RLS together achieve.

## Residual risk / assumptions

- **`current_tenant_id()` trust assumption.** The RLS policies delegate identity resolution entirely to this GUC function. If the function is incorrectly implemented or the GUC is not set before a query executes (e.g., a connection pool that reuses sessions without re-setting the GUC), the predicate evaluates to `NULL` and `authenticated` policies become deny-all rather than wrong-tenant-allow. This is a safe failure mode but would manifest as spurious 404s, not a data leak.
- **Conditional activation.** The `tenant_databases` policies only apply when both the table and the function exist. On a lean install without the heavier BaaS control plane, the table is absent and the policies are skipped — the isolation guarantee applies only to the installed plane.
- **`service_role` bypass.** `service_role` holds `bypassrls` at the Postgres level. Any code path that acquires the `service_role` credential — provisioning scripts, RPC handlers — operates without tenant scoping. This is intentional for administrative paths, but a bug in a `service_role` code path could return cross-tenant data without RLS catching it.
- **No coverage of connection-level isolation.** RLS scopes rows within a shared schema; it does not provide network-level or schema-level isolation between tenants. The `SHARE_POOLS` model (many tenants on one connection pool) relies entirely on per-request GUC setting being correct and atomic.
