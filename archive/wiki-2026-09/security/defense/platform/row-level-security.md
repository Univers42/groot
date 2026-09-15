# Row-Level Security — platform / infrastructure (cross-cutting)

> PostgreSQL enforces per-row, per-role access policies on every PII and workspace table so that no authenticated or anonymous API caller can read or write data that does not belong to them, even when all clients share the same PostgREST endpoint and the Kong API gateway carries no ACL plugin on `/rest/v1`.

## What it is (the concept)

**Row-Level Security (RLS)** is a PostgreSQL server-side mechanism that attaches **policy expressions** to a table. When RLS is enabled on a table, every query — regardless of who issued it — is rewritten by the database engine to filter rows through those expressions before returning or accepting data. The complementary `FORCE ROW LEVEL SECURITY` clause extends that filter to connections whose role normally bypasses policies (table owner connections), closing the last administrative loophole. **SECURITY DEFINER** functions owned by the `postgres` superuser (which carries `bypassrls`) remain the only intentionally privileged write path.

## What it defends against

See [Horizontal Privilege Escalation / Cross-Tenant Data Leakage](../../attack/row-level-security.md).

In this stack the Kong gateway exposes PostgREST on `/rest/v1` with a single public `anon` API key; there is no Kong ACL plugin scoping that route. Without RLS, any JWT-authenticated or anonymous client could `GET /rest/v1/users` and enumerate every user's PII. RLS is therefore the **only data wall** between the public API surface and all rows in the database — a fact stated verbatim in the migration header (see below).

## How platform implements it

### Layer 1 — GDPR baseline: ENABLE RLS + own-row policies

[`models/gdpr-migration.sql`](../../../../models/gdpr-migration.sql) (lines 780–813) is the first layer. It calls `ENABLE ROW LEVEL SECURITY` on the seven core PII tables (`users`, `user_consents`, `user_activities`, `sessions`, `user_tokens`, `gdpr_requests`, `newsletter_optins`) and creates `FOR SELECT`/`FOR UPDATE` policies keyed to `gdpr_current_user_id()`:

```sql
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
-- ...
CREATE POLICY users_authenticated_own_read ON users
  FOR SELECT TO authenticated
  USING (id = gdpr_current_user_id());
CREATE POLICY users_authenticated_own_update ON users
  FOR UPDATE TO authenticated
  USING  (id = gdpr_current_user_id())
  WITH CHECK (id = gdpr_current_user_id());
```

`gdpr_current_user_id()` resolves the calling JWT's `sub` claim, so every read and write is automatically scoped to the authenticated user's own row.

### Layer 2 — RLS hardening: FORCE + grant tightening across 17 tables

[`models/rls-hardening-migration.sql`](../../../../models/rls-hardening-migration.sql) closes findings F1–F7 identified in `wiki/security/baas-rls-audit.md`. Its header (lines 5–10) makes the threat model explicit:

```sql
-- The Kong anon apikey is public by design; there is no Kong ACL plugin on
-- /rest/v1, so Postgres RLS + grants are the ONLY data wall.
```

It then applies three mechanisms in sequence:

**a. FORCE RLS on internal tables** (lines 76–86) — `schema_registry` and `track_binocle_runtime_migrations` are locked to `service_role` only:

```sql
EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', t);
EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL TO service_role USING (true) WITH CHECK (true)', …);
```

**b. Column-level grant tightening on `users`** (lines 156–162) — `anon` is stripped of full-row SELECT and regranted only four non-PII columns (`id`, `username`, `avatar_url`, `is_email_verified`), capping anonymous enumeration.

**c. Defense-in-depth FORCE on all 18 policy-protected tables** (lines 169–183) — a loop applies `FORCE ROW LEVEL SECURITY` to every table that already has policies, ensuring that even a table-owner connection cannot bypass them:

```sql
FOREACH t IN ARRAY ARRAY[
  'users','user_consents','user_activities','sessions','user_tokens',
  'gdpr_requests','newsletter_optins','auth_audit_events',
  'calendar_accounts','calendar_sources','calendar_event_cache',
  'osionos_bridge_identities','osionos_workspaces','osionos_workspace_members',
  'osionos_pages','osionos_page_configurations','osionos_page_action_events',
  'osionos_bridge_audit_events'] LOOP
  IF to_regclass('public.'||t) IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', t);
  END IF;
END LOOP;
```

The migration is idempotent (every DDL block is existence-guarded with `to_regclass`/`to_regprocedure` checks) and ends with `NOTIFY pgrst, 'reload schema'` so PostgREST picks up the updated grant set immediately.

## How we know it is applied

[`apps/grobase/scripts/db/apply-project-sql.sh`](../../../../apps/grobase/scripts/db/apply-project-sql.sh) is the database bootstrap entrypoint. It runs on every container start, applies the SQL files in order, and records idempotency markers in `track_binocle_runtime_migrations`. The RLS sequence is explicit (lines 40–70):

```sh
if [ "$schema_applied" != "1" ]; then
  $psql_base -f /project-init/01-user.sql
  $psql_base -f /project-init/02-gdpr.sql          # ENABLE RLS + own-row policies
  $psql_base -c "INSERT INTO track_binocle_runtime_migrations …"
fi
# … inline column grants …
$psql_base -f /project-init/07-rls-hardening.sql   # FORCE + grant tightening
$psql_base -c "INSERT INTO track_binocle_runtime_migrations (marker) VALUES ('${marker}_rls_hardening') ON CONFLICT DO NOTHING"
```

The `ON CONFLICT DO NOTHING` marker guarantees the file is applied exactly once per marker, never skipped. The script itself runs with `set -eu`, so any SQL error (`ON_ERROR_STOP=1`) aborts the container start rather than silently continuing with incomplete security configuration.

## Reference

The [Database Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Database_Security_Cheat_Sheet.html) (OWASP, A01 Broken Access Control) describes least-privilege as the foundational database hardening principle: applications should connect with a role granted only the verbs their workflows require, and row-visibility should be enforced at the database layer rather than relying solely on application-layer filtering. This implementation follows that guidance by combining role-scoped column grants (`anon` receives only four non-PII columns; `authenticated` receives exactly the verbs each table's policies rely on) with server-enforced row policies that cannot be bypassed by application code.

## Residual risk / assumptions

- **`service_role` key exposure.** RLS policies grant `service_role` unrestricted access (`USING (true)`) to support PostgREST RPCs and the auth gateway. If the `service_role` JWT secret (stored in `PGRST_JWT_SECRET` / `SERVICE_ROLE_KEY`, populated from vault42 or the grobase self-generated secrets) is leaked, all RLS protections are bypassed. Rotation must be done at the secret store level.
- **SECURITY DEFINER functions.** Eight `gdpr_*` and audit functions are owned by `postgres` (`bypassrls`) and executed by `authenticated` via targeted `GRANT EXECUTE`. A vulnerability in one of these functions could allow a caller to read or modify rows outside their own scope.
- **New tables.** The migration revokes default privileges (`ALTER DEFAULT PRIVILEGES … REVOKE … FROM anon, authenticated`) to prevent auto-opening of future tables, but any new table added without an explicit `ENABLE ROW LEVEL SECURITY` call will be open to the role's grant. The default-privilege revoke reduces the blast radius but does not eliminate it.
- **Kong routing.** RLS is the data wall for PostgREST traffic only. Routes that bypass PostgREST (e.g., direct service-role RPC calls from the auth-gateway or the osionos-bridge service) rely on those services' own authorization logic; RLS does not constrain them.
- **Policy correctness.** Policies are only as correct as `gdpr_current_user_id()` and `current_tenant_id()`. If either function returns a wrong identity (e.g., due to a malformed JWT accepted by GoTrue), the row filter will silently scope to the wrong principal.
