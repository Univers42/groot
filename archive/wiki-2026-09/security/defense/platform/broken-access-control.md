# Broken Access Control — platform / infrastructure (cross-cutting)

> Postgres role grants and BEFORE INSERT trigger logic are the final data wall: they enforce least-privilege column access, deny unauthenticated callers destructive functions, and preserve the user `id` linkage that every owner-scoped RLS policy depends on.

## What it is (the concept)

**Broken Access Control** occurs when a system fails to enforce that principals can only reach the resources and operations explicitly authorized for their role. In a PostgREST-fronted BaaS stack the attack surface is the **role grant matrix**: the `anon`, `authenticated`, and `service_role` Postgres roles map directly to the Kong API-key the caller presents, so any **leaked PUBLIC grant** or overly broad column grant immediately becomes an exploitable API surface. **Row Level Security (RLS)** adds a per-row predicate layer on top of grants, but grants must be equally tight — an RLS policy on a table the anon role was never granted is redundant, but the inverse (grant without RLS) is a hole.

## What it defends against

See [Unauthorized Access / Privilege Escalation](../../attack/broken-access-control.md).

In this application the Kong gateway exposes the anon API key in the client bundle by design; there is no Kong ACL plugin on `/rest/v1`, making Postgres the sole enforcement boundary. An attacker who enumerates the PostgREST schema could call `SECURITY DEFINER` functions (e.g., `anonymise_user`, `auth_record_audit_event`) or read PII columns (email, bio) via the anon role unless the grant matrix is explicitly locked down. A second vector is a **duplicate-email insert** against `public.users` through the auth-gateway path, which without scoping could overwrite an existing account's identity fields and detach it from the `auth.users.id` that every `USING (auth.uid() = user_id)` owner policy evaluates.

## How platform implements it

### 1. Least-privilege Postgres grant hardening

[`models/rls-hardening-migration.sql`](../../../../models/rls-hardening-migration.sql) implements a layered revocation pass that runs after the base schema and is idempotent on every startup:

**PUBLIC execute revoked from destructive SECURITY DEFINER functions (lines 27–40):**
```sql
FOR fn IN SELECT … WHERE p.proname IN (
  'anonymise_user','auth_record_audit_event','gdpr_export_my_data', …)
LOOP
  EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', fn.sig);
END LOOP;
```
`anonymise_user` is then callable by no API role; `auth_record_audit_event` is narrowed to `service_role` only (line 51).

**Default-privilege future-proofing (lines 92–93):**
```sql
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM anon, authenticated;
```
This prevents any table added after the migration from inheriting open CRUD grants automatically.

**Per-table verb pinning (lines 99–126):** each application table is revoked then re-granted with exactly the verbs its RLS policies use — for example, `osionos_pages` receives `SELECT, INSERT, UPDATE, DELETE` for `authenticated`, while `osionos_bridge_audit_events` receives no grant at all.

**Anon column-level restriction on `users` (lines 156–162):**
```sql
REVOKE SELECT ON public.users FROM anon;
GRANT SELECT (id, username, avatar_url, is_email_verified) ON public.users TO anon;
```
Unauthenticated callers can enumerate public-profile fields but cannot read `email`, `bio`, or any other PII column.

**FORCE RLS defense-in-depth (lines 169–183):** `ALTER TABLE … FORCE ROW LEVEL SECURITY` is applied to all 18 policy-bearing tables so that even `service_role` connections that would normally bypass RLS are subject to row predicates when acting as a non-superuser.

[`models/auth-security-migration.sql`](../../../../models/auth-security-migration.sql) secures the audit table itself (lines 159–167):
```sql
ALTER TABLE auth_audit_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY auth_audit_events_no_public_access ON auth_audit_events
  FOR SELECT TO authenticated USING (false);
REVOKE ALL ON auth_audit_events FROM anon, authenticated;
GRANT INSERT, SELECT ON auth_audit_events TO service_role;
GRANT EXECUTE ON FUNCTION auth_record_audit_event(TEXT, TEXT, JSONB) TO service_role;
```
The `USING (false)` policy means even a role accidentally granted SELECT sees zero rows; the actual write path goes through the `SECURITY DEFINER` function callable only by `service_role`.

### 2. Gateway-scoped duplicate-email reconcile trigger

[`models/auth-gateway-users-reconcile-migration.sql`](../../../../models/auth-gateway-users-reconcile-migration.sql) installs a `BEFORE INSERT` trigger on `public.users` (lines 66–97). The critical scoping guard (line 74):

```sql
IF NEW.password_hash IS DISTINCT FROM 'managed-by-gotrue' THEN
  RETURN NEW;  -- not the gateway path: let normal UNIQUE handling apply
END IF;
```

Only when the auth-gateway's specific placeholder value is present does the trigger execute the `UPDATE … RETURN NULL` branch, reconciling the duplicate-email row in place and preserving `id = auth.users.id`. Any other inserter — including a potential attacker crafting a duplicate-email payload through the API — receives normal `UNIQUE` constraint enforcement instead of an in-place overwrite. The function runs `SECURITY DEFINER` with `search_path = public, pg_temp` to bypass the FORCED RLS while keeping a pinned search path against search-path-injection.

## How we know it is applied

Both migrations use the same apply-project-sql.sh bootstrap path with **migration marker tracking**, ensuring they are applied once and in the correct order relative to the base schema (the rls-hardening migration header explicitly states it must run "AFTER the base schema + the inline column grants … so its grants are final").

The rls-hardening migration closes named findings F1–F7 from `wiki/security/baas-rls-audit.md` — a live-verified audit. The header comment names the architectural invariant the grants enforce:

```
-- The Kong anon apikey is public by design; there is no Kong ACL plugin on
-- /rest/v1, so Postgres RLS + grants are the ONLY data wall.
```

The reconcile migration comment (lines 61–65) explicitly documents the scoping as a security boundary:

```
-- Scoped to the gateway path (password_hash = 'managed-by-gotrue') so
-- nothing else can overwrite a row via a duplicate-email insert.
```

## Reference

[A01 Broken Access Control — OWASP Top 10:2021](https://owasp.org/Top10/2021/A01_2021-Broken_Access_Control/) catalogues the failure modes that occur when access-control checks are absent, bypassable, or insufficiently granular. The controls documented here address two specific sub-categories from that taxonomy: insecure direct object reference through overly permissive database roles, and privilege escalation through callable `SECURITY DEFINER` functions exposed to the wrong callers.

## Residual risk / assumptions

- **Service-role key exposure:** `service_role` bypasses RLS by default. If the service-role JWT leaks (e.g., via a misconfigured client bundle or logging pipeline), all grant restrictions become moot. The `FORCE ROW LEVEL SECURITY` layer partially mitigates this only for connections that set `role = authenticated` explicitly — not for connections carrying the service-role token directly.
- **Migration ordering dependency:** The rls-hardening migration must run after the base schema. A deployment that applies it out of order will silently succeed (the idempotent `IF … IS NOT NULL` guards skip missing objects) but will leave grants un-narrowed on objects not yet present at migration time.
- **Reconcile trigger scope is implicit:** The scoping predicate `password_hash = 'managed-by-gotrue'` is a convention, not a cryptographic proof. If another code path were to set that exact string, it would gain reconcile behavior. The value is a placeholder, not a secret, so this is a soft boundary.
- **Column-level anon grants do not cover future columns:** If new columns are added to `public.users` they inherit no anon grant (thanks to the `ALTER DEFAULT PRIVILEGES` revoke), but the explicit `GRANT SELECT (id, username, …)` list is static — a schema change that renames a PII column would require a corresponding migration update.
- **No Kong ACL plugin:** The stack deliberately relies on Postgres as the sole data wall at `/rest/v1`. A Kong-level ACL or JWT-claim check would provide defense-in-depth but is not currently configured.
