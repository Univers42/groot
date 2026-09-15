# Row-Level Security — grobase (the BaaS backend)

> PostgreSQL Row-Level Security is enforced at every layer of the grobase stack — from the Rust data-plane GUC injection, through the non-superuser PostgREST authenticator role, down to per-table FORCE RLS policies — guaranteeing that no authenticated request can read or mutate a row it does not own, even if an upstream predicate is absent.

## What it is (the concept)

**Row-Level Security (RLS)** is a PostgreSQL feature that attaches **security policies** directly to tables. A policy is a boolean predicate evaluated by the database engine for every row returned or modified; rows that do not satisfy the predicate are silently filtered (SELECT) or rejected (INSERT/UPDATE/DELETE). The policy principal — the identity whose ownership is tested — is supplied through **transaction-scoped GUCs** (`set_config(..., true)`), which expire with the transaction and cannot be carried across connections. **FORCE ROW LEVEL SECURITY** extends the standard guarantee: without it, the table owner role bypasses policies entirely; FORCE removes that exemption and subjects every role — except a PostgreSQL superuser — to the same predicates.

## What it defends against

See [Horizontal Privilege Escalation / Cross-Tenant Data Leakage](../../attack/row-level-security.md).

In the grobase context the threat is concrete: the BaaS exposes a shared PostgREST surface over which any authenticated session can issue arbitrary REST queries against shared tables. Without database-enforced RLS, a single missing or bypassed application-layer ownership predicate would allow one tenant's session to read another tenant's workspaces, pages, connection strings, or API-key hashes. The controls below make the database itself the final arbiter, so a bug in application routing cannot leak cross-tenant rows.

## How grobase implements it

The implementation spans four interlocking layers.

**Layer 1 — Rust data-plane GUC injection (injection-safe)**

`apps/grobase/src/data-plane-router/crates/data-plane-pool/src/postgres/tx.rs` — `apply_rls_context` (lines 99–120) runs on every transaction before dispatch. It builds the JWT claims object with `serde_json::json!({ "sub": &principal, "tenant_id": &tenant })` (line 109) — the comment at lines 105–108 explicitly warns "never hand-format the security principal" — then sets three transaction-scoped GUCs with bound parameters:

```sql
SELECT set_config('app.current_user_id', $1, true),
       set_config('app.current_tenant_id', $2, true),
       set_config('request.jwt.claims', $3, true)
```

`apps/grobase/src/data-plane-router/crates/data-plane-pool/src/postgres/pool.rs` calls `tx::apply_rls_context` unconditionally on both the auto-commit path (line 55) and the interactive-transaction path (line 111). There is no feature flag and no bypass.

**Layer 2 — Non-superuser PostgREST authenticator role + FORCE RLS (migration 065)**

`apps/grobase/scripts/migrations/postgresql/065_least_privilege_rls.sql` closes three compounding weaknesses documented in its header (lines 18–43):

- Creates or re-affirms the `authenticator` login role as `NOINHERIT NOBYPASSRLS NOSUPERUSER` (lines 69, 74) — PostgREST connects as this role and `SET ROLE`s to `anon`/`authenticated`/`service_role` per request; a missing or forged JWT role claim yields the `anon` view, never superuser.
- Walks `pg_class` and applies `FORCE ROW LEVEL SECURITY` to every RLS-enabled table in `public`, `auth`, `gdpr`, and `session` schemas (lines 108–124) — closing the owner-exemption gap that `ENABLE`-only RLS leaves.
- Revokes all `anon`/`authenticated` grants on `public.tenant_databases` (AES-GCM connection strings) and `public.tenant_api_keys` (key hashes), granting them only to `service_role`/`adapter_registry_role` (lines 126–177).

**Layer 3 — Per-table RLS policies on the osionos bridge schema**

`models/osionos-bridge-migration.sql` — lines 8–10 define the policy principal function:

```sql
CREATE OR REPLACE FUNCTION auth.uid() RETURNS UUID AS $$
  SELECT (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb->>'sub')::uuid;
$$ LANGUAGE SQL STABLE;
```

Lines 149–155 enable RLS on all seven bridge tables (`osionos_bridge_identities`, `osionos_workspaces`, `osionos_workspace_members`, `osionos_pages`, `osionos_page_configurations`, `osionos_page_action_events`, `osionos_bridge_audit_events`). Lines 157–268 define per-verb policies: SELECT policies check `auth.uid() = user_id` or workspace membership; write policies additionally require the caller's `permissions` array to contain the relevant verb (`read`/`create`/`update`/`delete`/`admin`) via `member.permissions && ARRAY[...]:TEXT[]`. Lines 270–296 add `service_role` bypass policies (`USING (true)`) for the server-side RPC path.

**Layer 4 — RLS hardening: FORCE, PUBLIC-revoke on SECURITY DEFINER functions, PII column-grant capping**

`models/rls-hardening-migration.sql` closes the residual gaps:

- Lines 27–40 loop over `REVOKE EXECUTE ... FROM PUBLIC` on all sensitive `SECURITY DEFINER` functions (`anonymise_user`, `gdpr_*`, `auth_record_audit_event`) — the `PUBLIC` pseudo-role is what `anon` inherits by default, so role-specific revokes alone would not have been sufficient.
- Lines 92–93 strip the blanket `ALTER DEFAULT PRIVILEGES` grant so future tables are not auto-opened.
- Lines 156–162 revoke the open `SELECT` on `public.users` from `anon` and re-grant only `(id, username, avatar_url, is_email_verified)` — dropping `email` and `bio` from unauthenticated reach.
- Lines 169–183 apply `FORCE ROW LEVEL SECURITY` to 17 named tables, ensuring the FORCE predicate covers tables that existed before migration 065 ran.

`models/auth-security-migration.sql` — lines 159–167 enable RLS on `auth_audit_events` with a deny-all SELECT policy (`USING (false)`) and revoke all access from `anon`/`authenticated`, granting only `service_role` INSERT/SELECT. The audit log is structurally unreadable from the public REST surface.

## How we know it is applied

**Rust data plane:** `apply_rls_context` is called on the unconditional execute path in `pool.rs` with no feature flag. `make rust-data-plane-test` (`cargo test --workspace`) covers the `postgres` pool and `tx` modules.

**SQL migrations (migration 065):** CI applies every numbered migration in sorted order before the integration tests run. `.github/workflows/ci.yml` lines 325–331:

```bash
# numbered migrations the way `make migrate` does (strip # comment lines).
for f in $(ls -1 scripts/migrations/postgresql/*.sql 2>/dev/null | sort); do
  sed '/^#/d' "$f" | docker compose -f docker-compose.yml exec -T postgres \
    psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f -
done
```

Migration 065 is sorted after 064 and before 066 — it runs in every CI pipeline against a live Postgres container.

**Root-app bridge and hardening migrations:** `apps/grobase/scripts/db/apply-project-sql.sh` applies the migrations at stack boot with idempotency markers:

- Line 49: `$psql_base -f /project-init/04-osionos-bridge.sql` applies `models/osionos-bridge-migration.sql`; a marker row is recorded immediately after.
- Line 69: `$psql_base -f /project-init/07-rls-hardening.sql` applies `models/rls-hardening-migration.sql`; the comment at lines 67–68 explicitly states this must run after the inline column grants so its tightened `anon` grant is final.

Both scripts end with `NOTIFY pgrst, 'reload schema'` so PostgREST picks up the new policies without a container restart.

## Reference

The OWASP [Database Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Database_Security_Cheat_Sheet.html) recommends the principle of least privilege at the database role level and enforcing access control directly in the data tier rather than relying solely on application logic. Grobase's layered approach — injecting the identity through bound-parameter GUCs, restricting the connection role to a non-superuser, and forcing RLS on every policy-protected table — maps directly to those guidelines and adds defense in depth by ensuring that a bug in any single layer does not yield a cross-tenant data exposure.

## Residual risk / assumptions

- **PostgreSQL superuser is still exempt from FORCE RLS.** The data-plane outbox and any maintenance job that connects as the `postgres` superuser bypasses all RLS policies unconditionally. The architecture assumes those paths are never reachable from a tenant session.
- **`service_role` bypass policies grant unrestricted row access.** All `service_role` bypass policies use `USING (true)`. Any path that can forge or obtain a `service_role` JWT escapes the RLS boundary entirely. The JWT signing secret must remain confidential; it is stored under the env-var name `PGRST_JWT_SECRET` (never in the repo).
- **RLS covers the PostgREST and data-plane surfaces only.** Direct connections to Postgres (e.g., via the Postgres port if accidentally exposed) bypass PostgREST role-switching and reach the connection role's native grants. The compose configuration must not expose port 5432 on a public interface.
- **`auth.uid()` reads the GUC that the Rust data plane injects; on the PostgREST path, GoTrue sets the same GUC via its own JWT-verified claims.** If either path is bypassed — for example through a misconfigured Kong plugin that forges the `request.jwt.claims` header — the policy principal can be spoofed at the database level. The GUC is trusted by the database; upstream JWT verification is the gating check.
- **The bridge schema hardening does not extend automatically to new tables.** Future tables added by application migrations that forget `ENABLE ROW LEVEL SECURITY` will default to open. The `ALTER DEFAULT PRIVILEGES REVOKE` in `rls-hardening-migration.sql` (line 92–93) prevents the blanket grant, but the ENABLE step must still be explicit in each new migration.
