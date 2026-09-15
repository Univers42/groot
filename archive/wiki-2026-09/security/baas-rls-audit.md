# BaaS Postgres Row-Level-Security (RLS) Audit

- **Scope:** Every table / view / RPC reachable through PostgREST via the Kong gateway with the **public `anon` API key**, and over-broad `authenticated` access.
- **Threat model:** The Kong anon `apikey` is *public by design*. There is **no Kong ACL plugin gating `/rest/v1`** — any request bearing the anon key reaches PostgREST and runs as the Postgres `anon` role. **RLS is the only data-protection wall.**
- **Verification status:** Confirmed against the **LIVE database** (`track-binocle-postgres-1`, db `postgres`) and via **live anon-key HTTP probes through Kong** (`https://127.0.0.1:8000/rest/v1`, internal `kong:8000`). All probe writes were reverted; DB restored to baseline.
- **Date:** 2026-06-06. **Mode:** audit → remediation. The §4 fixes are finalized as `models/rls-hardening-migration.sql` and **APPLIED + VERIFIED on the local stack 2026-06-06**: anon-key probes for F1 (`anonymise_user`), F2, F3, F4 and F5 (email harvest) now all return **401** (were 200); the curated public columns and the full app flow (playground e2e) still pass. **Apply the same migration to staging/prod** and fix the source grant in `001_initial_schema.sql` so the hole is not re-created.
- **Secrets:** Never reproduced here. Referenced by env var name only: `KONG_PUBLIC_API_KEY` / `ANON_KEY` (anon), `KONG_SERVICE_API_KEY` / `SERVICE_ROLE_KEY` (service_role), `JWT_SECRET` / `PGRST_JWT_SECRET`, `PGRST_DB_URI`.

---

## 1. Exposed surface

### Routing / roles
- **PostgREST exposes schema `public` only.** `PGRST_DB_SCHEMAS: public`, `PGRST_DB_ANON_ROLE: anon` — `docker-compose.yml:245-247`, `apps/baas/mini-baas-infra/docker-compose.yml:586-587`. Live: `anon` has `USAGE` only on `public` (the GoTrue `auth` schema is **not** PostgREST-exposed and anon has no USAGE on it — good).
- **PostgREST connects as `postgres`** (superuser, `rolbypassrls=t`) via `PGRST_DB_URI` (`apps/baas/.env.local:51`), then `SET ROLE anon`/`authenticated` per request. Because the active role after `SET ROLE` is `anon`/`authenticated` (not the owner), RLS *does* apply to anon/authenticated traffic even though tables are not `FORCE`d. `FORCE` still matters as defense-in-depth (see §5).
- **Kong `/rest/v1` → PostgREST** with `key-auth` (apikey) + `jwt` plugins. The jwt plugin sets `anonymous: <KONG_ANON_UUID>`, so a request with a valid anon `apikey` and **no/invalid JWT falls back to the `anon` consumer** → PostgREST runs as DB role `anon`. Config: `apps/baas/config/kong.track-binocle.yml:69-92` (live: `/tmp/kong.yml` in `kong` container). **No `acl` plugin on the `rest` route** — every exposed `public` table/RPC is reachable by anon.
- Roles (live `pg_roles`): `anon` (no super, no bypassrls), `authenticated` (no super, no bypassrls), `service_role` (**`rolbypassrls=t`** — bypasses all RLS), `postgres` (super + bypassrls).

### Root-cause grant (the spine of every finding)
`apps/baas/mini-baas-infra/scripts/migrations/postgresql/001_initial_schema.sql:37-39`:
```sql
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated;
```
This blanket-grants **full CRUD to `anon` and `authenticated` on every current and future `public` table.** Live `pg_default_acl` confirms: `anon=arwd/postgres, authenticated=arwd/postgres`. Each table is therefore only as safe as its RLS. App migrations that `REVOKE ALL ... FROM anon` (users, calendar, mail, auth_audit) correctly neutralize this; tables that do **not** revoke anon and **also lack RLS** are wide open.

### Migrations applied to the live DB
`track_binocle_runtime_migrations` shows applied: `schema`, `auth_security`, `osionos_bridge`, `calendar`, `seeds`. The **mail migration is NOT applied** — `mail_accounts` / `mail_messages` do **not** exist live (probes returned `42P01`), so mail RLS is reviewed from SQL only. The gdpr migration's objects (`gdpr_requests`, `newsletter_optins`, `user_consents`, RLS, RPCs) are present in the live DB though not in the runtime tracker.

---

## 2. Per-object risk table (`public` schema; live-verified unless noted)

There are **no views** in `public` (live `pg_class relkind v/m` = none), so the view→`security_invoker` bypass class does not currently apply. Flag for any future view.

| Object | Type | RLS on? | Forced? | anon grant | authenticated isolation | Risk | Issue |
|---|---|---|---|---|---|---|---|
| `anonymise_user(int)` | RPC (SECDEF) | n/a | n/a | **EXECUTE via PUBLIC** | same | **CRITICAL** | Anon can anonymize/destroy ANY user by id (SECURITY DEFINER, runs as owner, bypasses RLS). Live: anon RPC rc=200. |
| `auth_record_audit_event(...)` | RPC (SECDEF) | n/a | n/a | **EXECUTE via PUBLIC** | same | **HIGH** | Anon can forge/inject security-audit rows. Live: anon RPC rc=200, created event_id (reverted). |
| `schema_registry` | table | **NO** | no | SELECT,INSERT,UPDATE,DELETE | none (RLS off) | **HIGH** | RLS disabled + anon CRUD. Live: anon SELECT rc=200, anon **INSERT rc=201**, anon **DELETE rc=200** (reverted). |
| `track_binocle_runtime_migrations` | table | **NO** | no | SELECT,INSERT,UPDATE,DELETE | none (RLS off) | **HIGH** | RLS disabled + anon CRUD. Live: anon **read returned rows**; anon INSERT rc=201; anon DELETE rc=200 (reverted). Leaks/pollutes migration state. |
| `osionos_bridge_identities` | table | yes | no | SELECT,INSERT,UPDATE,DELETE | `SELECT` own (`uid()=user_id`); no insert/update/delete policy | **MED** | Over-broad anon+authenticated CRUD grant; RLS denies anon (live SELECT `[]`). authenticated can only read own row; writes denied (no policy). Grant hygiene + maps identity rows. |
| `osionos_workspaces` | table | yes | no | SELECT,INSERT,UPDATE,DELETE | `SELECT` member; no write policy | **MED** | Anon CRUD grant (RLS denies, live `[]`). authenticated cannot write via PostgREST (no insert/update policy → all writes go through service_role RPC). |
| `osionos_workspace_members` | table | yes | no | SELECT,INSERT,UPDATE,DELETE | `SELECT` own | **MED** | Anon CRUD grant (RLS denies). No authenticated write policy. |
| `osionos_pages` | table | yes | no | SELECT,INSERT,UPDATE,DELETE | SELECT/INSERT/UPDATE/DELETE gated on workspace membership + permissions | **MED** | Anon CRUD grant present but RLS denies. Live: anon **INSERT rc=401** (`new row violates RLS`) — correct. Risk is grant hygiene only. |
| `osionos_page_configurations` | table | yes | no | SELECT,INSERT,UPDATE,DELETE | own + membership | **MED** | Anon CRUD grant; RLS denies anon. No DELETE policy for authenticated (grant exists but no policy → denied). |
| `osionos_page_action_events` | table | yes | no | SELECT,INSERT,UPDATE,DELETE | SELECT/INSERT own | **MED** | Anon CRUD grant; RLS denies anon. UPDATE/DELETE granted to authenticated but no policy → denied. |
| `osionos_bridge_audit_events` | table | yes | no | SELECT,INSERT,UPDATE,DELETE | **no anon/authenticated policy at all** (only service_role) | **MED** | Anon CRUD grant; RLS denies all anon+authenticated (no permissive policy). Grant hygiene. |
| `tenant_databases` | table | yes | **YES** | SELECT,INSERT,UPDATE,DELETE | policies `TO public` keyed on `current_tenant_id()` = `current_setting('app.current_user_id')` | **MED** | Holds **encrypted tenant DB connection material** (`connection_enc/iv/tag/salt`). Anon CRUD grant; GUC is unset for PostgREST anon → `tenant_id = NULL` never matches → fails closed (live SELECT `[]`). Depends entirely on the GUC never being attacker-influenced; policies should be role-scoped, not `TO public`, and anon grant removed. |
| `users` | table | yes | no | SELECT (10 non-sensitive cols only) | `SELECT`/`UPDATE` own | **MED** | Anon can enumerate **all** users' id/username/email/avatar/bio (policy `users_anon_public_read USING (deleted_at IS NULL)`). Email harvesting / account enumeration. No password_hash exposed (column grant excludes it). |
| `gdpr_requests` | table | yes | no | **SELECT,INSERT,UPDATE,DELETE** (intended: anon INSERT only) | `SELECT` own | **MED** | Intended grant is `INSERT` for anon (DSAR form). Live anon has full CRUD via blanket grant; RLS denies SELECT (live `[]`) and UPDATE/DELETE (no policy). Anon INSERT allowed (no INSERT policy + RLS... see note) — DSAR spam vector. |
| `newsletter_optins` | table | yes | no | **SELECT,INSERT,UPDATE,DELETE** | no anon/authenticated read policy | **MED** | Token-hash opt-in table. Anon CRUD grant; RLS has no permissive policy → reads/writes denied (live `[]`). Writes happen via SECDEF RPCs. Grant hygiene. |
| `auth_audit_events` | table | yes | no | **none** (REVOKEd) | `SELECT USING(false)` | LOW | Direct table access denied to anon (live SELECT rc=401). Only reachable via the `auth_record_audit_event` RPC — see HIGH finding above. |
| `calendar_accounts` | table | yes | no | none (REVOKEd) | `SELECT USING(false)` | LOW | Anon SELECT rc=401. service_role-only. Good. |
| `calendar_sources` | table | yes | no | none (REVOKEd) | `SELECT USING(false)` | LOW | Anon denied. Good. |
| `calendar_event_cache` | table | yes | no | none (REVOKEd) | `SELECT USING(false)` | LOW | Anon SELECT rc=401. Good. |
| `mail_accounts` | table | yes (SQL) | no | none (SQL REVOKE) | `SELECT USING(false)` | LOW (unverified) | Not present in live DB (migration not applied). SQL is correct. |
| `mail_messages` | table | yes (SQL) | no | none (SQL REVOKE) | `SELECT USING(false)` | LOW (unverified) | Not present in live DB. SQL is correct. |
| `user_consents` | table | yes | no | none (REVOKEd) | `SELECT`/`ALL` own | LOW | Anon SELECT rc=401. authenticated scoped to own rows. Good. |
| `sessions` | table | yes | no | none (REVOKEd) | `SELECT` own | LOW | Anon rc=401. Good. |
| `user_tokens` | table | yes | no | none (REVOKEd) | `SELECT` own | LOW | Anon rc=401. Good. |
| `user_activities` | table | yes | no | none (REVOKEd) | `SELECT` own | LOW | Anon rc=401. Good. |

> Note on `gdpr_requests`/`osionos_*` INSERTs: with RLS **enabled** and **no permissive INSERT policy for anon**, INSERTs are denied (default-deny) — confirmed for `osionos_pages` (rc=401). `gdpr_requests` is intended to accept anon INSERT for the public DSAR form; it currently has *no* INSERT policy, so direct anon INSERT is denied and DSAR submission flows through the `gdpr_submit_request` RPC instead. The standing problem is the **over-broad grant**, not an open INSERT path here.

---

## 3. Findings ordered by severity

### F1 — CRITICAL: `anon` can anonymize/destroy any user account (`anonymise_user`)
- **Why exploitable:** `anonymise_user(int)` is `SECURITY DEFINER` (runs as owner `postgres`, bypassing RLS). Live `pg_proc.proacl` shows `=X/postgres` — i.e. **PUBLIC has EXECUTE**, which `anon` inherits. The migration ran `REVOKE EXECUTE ... FROM anon, authenticated` (`models/gdpr-migration.sql:837`) but **never `REVOKE ... FROM PUBLIC`**, so the default PUBLIC execute grant remains.
- **Exact attack:** `POST https://<kong>/rest/v1/rpc/anonymise_user` with header `apikey: <KONG_PUBLIC_API_KEY>` and body `{"target_user_id": 1}`. The function overwrites that user's `email`, `username`, `password_hash`, clears profile fields, sets `deleted_at`, and **deletes all their `sessions` and `user_tokens`** — full account takeover/destruction by an unauthenticated caller.
- **Live proof:** Called with `target_user_id: -1` (non-existent, no row touched) → **rc=200**, `{"anonymised": false}`. Confirms anon can invoke it; a real id would have executed the destructive UPDATE/DELETEs.

### F2 — HIGH: `anon` can forge/inject security audit logs (`auth_record_audit_event`)
- **Why exploitable:** Same PUBLIC-EXECUTE leak. `models/auth-security-migration.sql:166` revokes from `anon, authenticated` but not `PUBLIC`; live `proacl` = `=X/postgres, ..., service_role=X/postgres`.
- **Exact attack:** `POST /rest/v1/rpc/auth_record_audit_event` with the anon key and `{"event_type":"login_success","email":"victim@x","details":{...}}` → writes an arbitrary row into `auth_audit_events`. Enables log forging (fake successful logins), log flooding, and masking of real attacker activity.
- **Live proof:** anon RPC → **rc=200**, `{"status":"recorded","event_id":168}`. Probe row deleted afterward (`DELETE 1`, 0 remaining).

### F3 — HIGH: `schema_registry` — RLS disabled + anon full CRUD
- **Why exploitable:** Live `pg_tables.rowsecurity = false`; `001_initial_schema.sql:38-39` grants anon `SELECT/INSERT/UPDATE/DELETE`. With RLS off, grants are the only gate → anon has unrestricted read/write.
- **Exact attack:** anon `GET /rest/v1/schema_registry` reads every row; anon `POST` inserts arbitrary rows; anon `DELETE` removes rows.
- **Live proof:** anon SELECT **rc=200**; anon INSERT **rc=201** (row returned); anon DELETE **rc=200** (row removed). Table restored to 0 rows.

### F4 — HIGH: `track_binocle_runtime_migrations` — RLS disabled + anon full CRUD
- **Why exploitable:** Same as F3 — RLS off, anon CRUD grant.
- **Exact attack:** anon reads internal migration markers/timestamps (recon of applied schema versions); anon can **delete or forge migration markers**, which can trick idempotent migration runners into re-running or skipping migrations.
- **Live proof:** anon read returned the 5 migration rows; anon INSERT **rc=201**; anon DELETE **rc=200**. Restored to 5 rows.

### F5 — MED: `users` allows full anon enumeration of all accounts
- **Why exploitable:** Policy `users_anon_public_read ON users FOR SELECT TO anon USING (deleted_at IS NULL)` (`models/gdpr-migration.sql:791`) + column grant to anon (`gdpr-migration.sql:816`) lets anon read **every** non-deleted user's `id, username, email, avatar_url, bio, is_email_verified, ...`.
- **Exact attack:** `GET /rest/v1/users?select=id,email,username` returns the full membership list — email harvesting, account enumeration, target reconnaissance.
- **Risk note:** `password_hash` is correctly excluded by the column grant; this is a confidentiality/enumeration issue, not credential exposure. If a public directory is intentional, accept; otherwise restrict to authenticated or to a minimal public-profile projection.

### F6 — MED: `tenant_databases` holds encrypted connection secrets behind a `TO public` GUC policy
- **Why exploitable:** RLS is enabled **and forced** (good), but policies are `TO public` keyed on `current_tenant_id()` = `current_setting('app.current_user_id', true)`. For PostgREST anon this GUC is unset → `tenant_id = NULL` is never true → fails closed (live SELECT `[]`). The protection rests entirely on that GUC never being attacker-settable and on the broad anon CRUD grant being inert. Policies should be role-scoped and the anon grant removed for defense-in-depth.
- **Exact attack (today):** none working (fails closed). **Latent risk:** if any code path lets a request set `app.current_user_id` (e.g. via `Prefer`/`set_config` or a future header mapping), anon could read encrypted blobs for a chosen tenant.

### F7 — MED: Over-broad `anon`/`authenticated` CRUD grants on `osionos_*`, `gdpr_requests`, `newsletter_optins` (defense-in-depth gap)
- **Why exploitable:** The blanket `001_initial_schema.sql` grant leaves anon with `INSERT/UPDATE/DELETE` on tables that *intend* anon to have nothing (osionos) or only `INSERT` (gdpr_requests). Today RLS denies these (no permissive anon policy → live `[]` / rc=401 on writes), so the grants are inert — **but they are landmines**: adding any future permissive policy (or disabling RLS during maintenance) instantly opens full anon CRUD. `authenticated` similarly holds `UPDATE/DELETE` grants on tables with no matching policy (e.g. `osionos_page_action_events`, `osionos_page_configurations` DELETE) — currently denied by RLS, but the grant should match the policy surface.

---

## 4. Proposed remediation (copy-pasteable migration — NOT yet applied)

Group these into one migration, e.g. `models/rls-hardening-migration.sql`. Review against the running app before applying — several tables intentionally restrict authenticated to SELECT and route writes through `service_role` RPCs, so do **not** add write policies you don't need.

```sql
-- =====================================================================
-- RLS hardening migration — track-binocle BaaS
-- Closes F1–F7 from wiki/security/baas-rls-audit.md
-- =====================================================================
BEGIN;
SET LOCAL search_path = public;

-- ---------------------------------------------------------------------
-- F1/F2: revoke PUBLIC execute on SECURITY DEFINER functions.
-- REVOKE ... FROM anon/authenticated does NOT remove the default PUBLIC grant.
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.anonymise_user(INT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.auth_record_audit_event(TEXT, TEXT, JSONB) FROM PUBLIC;
-- (anonymise_user should be callable by NO API role; keep it owner/service_role only)
REVOKE EXECUTE ON FUNCTION public.anonymise_user(INT) FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.auth_record_audit_event(TEXT, TEXT, JSONB) TO service_role;
-- Audit every other SECURITY DEFINER function the same way:
--   SELECT proname, proacl FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--   WHERE n.nspname='public' AND p.prosecdef;
-- For gdpr_* functions intended for anon/authenticated, REVOKE FROM PUBLIC then
-- GRANT explicitly to the intended role only (do not leave the PUBLIC grant):
REVOKE EXECUTE ON FUNCTION public.gdpr_export_my_data()                       FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.gdpr_request_deletion()                     FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.gdpr_set_newsletter(BOOLEAN)                FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.gdpr_withdraw_consent(TEXT, TEXT)           FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.gdpr_submit_request(TEXT, TEXT, JSONB)      FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.gdpr_request_newsletter_optin(TEXT, TEXT)   FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.gdpr_confirm_newsletter_optin(TEXT)         FROM PUBLIC;
-- then re-grant to the intended roles (matches models/gdpr-migration.sql:829-835):
GRANT EXECUTE ON FUNCTION public.gdpr_export_my_data()                     TO authenticated;
GRANT EXECUTE ON FUNCTION public.gdpr_request_deletion()                   TO authenticated;
GRANT EXECUTE ON FUNCTION public.gdpr_set_newsletter(BOOLEAN)              TO authenticated;
GRANT EXECUTE ON FUNCTION public.gdpr_withdraw_consent(TEXT, TEXT)         TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gdpr_submit_request(TEXT, TEXT, JSONB)    TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gdpr_request_newsletter_optin(TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gdpr_confirm_newsletter_optin(TEXT)       TO anon, authenticated;

-- ---------------------------------------------------------------------
-- F3: schema_registry — enable + force RLS, drop anon access.
-- ---------------------------------------------------------------------
REVOKE ALL ON public.schema_registry FROM anon, authenticated;
ALTER TABLE public.schema_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.schema_registry FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS schema_registry_service_role_all ON public.schema_registry;
CREATE POLICY schema_registry_service_role_all ON public.schema_registry
  FOR ALL TO service_role USING (true) WITH CHECK (true);
GRANT ALL ON public.schema_registry TO service_role;

-- ---------------------------------------------------------------------
-- F4: track_binocle_runtime_migrations — enable + force RLS, drop anon access.
-- ---------------------------------------------------------------------
REVOKE ALL ON public.track_binocle_runtime_migrations FROM anon, authenticated;
ALTER TABLE public.track_binocle_runtime_migrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.track_binocle_runtime_migrations FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS trk_runtime_migrations_service_role_all ON public.track_binocle_runtime_migrations;
CREATE POLICY trk_runtime_migrations_service_role_all ON public.track_binocle_runtime_migrations
  FOR ALL TO service_role USING (true) WITH CHECK (true);
GRANT ALL ON public.track_binocle_runtime_migrations TO service_role;

-- ---------------------------------------------------------------------
-- F7 (+F3/F4 source): strip the blanket anon/authenticated grants and the
-- dangerous default-privilege grant so future tables are not auto-opened.
-- Re-grant ONLY what each table's policies actually use.
-- ---------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM anon, authenticated;

-- osionos_* : authenticated reads via policy; writes go through service_role RPCs.
REVOKE ALL ON public.osionos_bridge_identities, public.osionos_workspaces,
              public.osionos_workspace_members, public.osionos_pages,
              public.osionos_page_configurations, public.osionos_page_action_events,
              public.osionos_bridge_audit_events
  FROM anon, authenticated;
-- Re-grant exactly the verbs the existing authenticated policies cover:
GRANT SELECT ON public.osionos_bridge_identities  TO authenticated;
GRANT SELECT ON public.osionos_workspaces         TO authenticated;
GRANT SELECT ON public.osionos_workspace_members  TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.osionos_pages TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.osionos_page_configurations TO authenticated;
GRANT SELECT, INSERT ON public.osionos_page_action_events TO authenticated;
-- osionos_bridge_audit_events: no anon/authenticated access intended (service_role only).

-- gdpr_requests: anon/authenticated only need INSERT (DSAR); authenticated SELECT own.
REVOKE ALL ON public.gdpr_requests FROM anon, authenticated;
GRANT INSERT ON public.gdpr_requests TO anon, authenticated;
GRANT SELECT ON public.gdpr_requests TO authenticated;
-- (If direct anon INSERT is intended, add a matching WITH-CHECK INSERT policy;
--  otherwise keep INSERT flowing through gdpr_submit_request() and REVOKE INSERT too.)

-- newsletter_optins: written only by SECDEF RPCs -> no anon/authenticated table grant.
REVOKE ALL ON public.newsletter_optins FROM anon, authenticated;

-- ---------------------------------------------------------------------
-- F6: tenant_databases — role-scope policies and drop the public/anon grant.
-- ---------------------------------------------------------------------
REVOKE ALL ON public.tenant_databases FROM anon, authenticated;
DROP POLICY IF EXISTS tenant_databases_select ON public.tenant_databases;
DROP POLICY IF EXISTS tenant_databases_insert ON public.tenant_databases;
DROP POLICY IF EXISTS tenant_databases_update ON public.tenant_databases;
-- Recreate scoped to authenticated (not public); keep the tenant predicate:
CREATE POLICY tenant_databases_select ON public.tenant_databases
  FOR SELECT TO authenticated USING (tenant_id = current_tenant_id());
CREATE POLICY tenant_databases_insert ON public.tenant_databases
  FOR INSERT TO authenticated WITH CHECK (tenant_id = current_tenant_id());
CREATE POLICY tenant_databases_update ON public.tenant_databases
  FOR UPDATE TO authenticated USING (tenant_id = current_tenant_id())
                              WITH CHECK (tenant_id = current_tenant_id());
DROP POLICY IF EXISTS tenant_databases_service_role_all ON public.tenant_databases;
CREATE POLICY tenant_databases_service_role_all ON public.tenant_databases
  FOR ALL TO service_role USING (true) WITH CHECK (true);
-- tenant_databases already has FORCE ROW LEVEL SECURITY (verified live). Good.

-- ---------------------------------------------------------------------
-- F5: users — restrict anon enumeration (choose ONE of the options below).
-- Option A (recommended): remove anon read entirely; expose a curated public view.
DROP POLICY IF EXISTS users_anon_public_read ON public.users;
REVOKE SELECT ON public.users FROM anon;
--   then, if a public directory is required, create an explicit projection:
--   CREATE VIEW public.public_profiles WITH (security_invoker = on) AS
--     SELECT id, username, avatar_url FROM public.users WHERE deleted_at IS NULL;
--   GRANT SELECT ON public.public_profiles TO anon, authenticated;
-- Option B (minimal): keep anon read but drop email/bio from the column grant:
--   REVOKE SELECT ON public.users FROM anon;
--   GRANT SELECT (id, username, avatar_url, is_email_verified) ON public.users TO anon;

-- ---------------------------------------------------------------------
-- Defense-in-depth: FORCE RLS on every policy-protected table so a future
-- owner-context query (or a misconfigured connection role) cannot bypass RLS.
-- ---------------------------------------------------------------------
ALTER TABLE public.users                        FORCE ROW LEVEL SECURITY;
ALTER TABLE public.user_consents                FORCE ROW LEVEL SECURITY;
ALTER TABLE public.user_activities              FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sessions                     FORCE ROW LEVEL SECURITY;
ALTER TABLE public.user_tokens                  FORCE ROW LEVEL SECURITY;
ALTER TABLE public.gdpr_requests                FORCE ROW LEVEL SECURITY;
ALTER TABLE public.newsletter_optins            FORCE ROW LEVEL SECURITY;
ALTER TABLE public.auth_audit_events            FORCE ROW LEVEL SECURITY;
ALTER TABLE public.calendar_accounts            FORCE ROW LEVEL SECURITY;
ALTER TABLE public.calendar_sources             FORCE ROW LEVEL SECURITY;
ALTER TABLE public.calendar_event_cache         FORCE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_bridge_identities    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_workspaces           FORCE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_workspace_members    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_pages                FORCE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_page_configurations  FORCE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_page_action_events   FORCE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_bridge_audit_events  FORCE ROW LEVEL SECURITY;
-- NOTE: FORCE applies to the table OWNER too. The bridge/calendar/mail SECDEF
-- helpers run as owner and rely on service_role_all policies; verify those RPCs
-- still pass after FORCE (they have explicit service_role policies, so they should).
-- service_role has rolbypassrls=t and is unaffected.

NOTIFY pgrst, 'reload schema';
COMMIT;
```

Also fix the source so it never regenerates the hole:
`apps/baas/mini-baas-infra/scripts/migrations/postgresql/001_initial_schema.sql:38-39` — remove the blanket `GRANT ... ON ALL TABLES` and the `ALTER DEFAULT PRIVILEGES ... TO anon, authenticated`; grant per-table per-verb in each app migration instead.

---

## 5. How to verify (read-only, re-run after applying)

### A. RLS enabled + forced on every table
```bash
docker compose exec -T postgres psql -U postgres -d postgres -c "
SELECT c.relname, c.relrowsecurity AS rls, c.relforcerowsecurity AS forced
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relkind='r' ORDER BY 1;"
# Expect rls=t (and forced=t after hardening) for every row.
```

### B. No anon/authenticated grants on internal tables
```bash
docker compose exec -T postgres psql -U postgres -d postgres -c "
SELECT table_name, grantee, string_agg(privilege_type,',') 
FROM information_schema.role_table_grants
WHERE table_schema='public' AND grantee IN ('anon','authenticated')
GROUP BY 1,2 ORDER BY 1,2;"
# Expect: NO rows for schema_registry / track_binocle_runtime_migrations / tenant_databases;
#         osionos_* anon rows gone; gdpr_requests anon = INSERT only.
```

### C. No PUBLIC execute on SECURITY DEFINER functions
```bash
docker compose exec -T postgres psql -U postgres -d postgres -c "
SELECT proname, proacl FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.prosecdef ORDER BY 1;"
# Expect: no '=X/postgres' (PUBLIC) entry on anonymise_user / auth_record_audit_event.
```

### D. Anon-key HTTP probes through Kong (read the key by env var name; never echo it)
```bash
ANON=$(grep -m1 -E '^KONG_PUBLIC_API_KEY=' apps/baas/.env.local | cut -d= -f2-)
BASE="https://127.0.0.1:8000/rest/v1"

# F3/F4 — must now be 401/empty, not readable/writable:
curl -sk -o /dev/null -w "schema_registry SELECT rc=%{http_code}\n" "$BASE/schema_registry?select=*" -H "apikey: $ANON"
curl -sk -o /dev/null -w "runtime_migrations SELECT rc=%{http_code}\n" "$BASE/track_binocle_runtime_migrations?select=*" -H "apikey: $ANON"
curl -sk -o /dev/null -w "schema_registry INSERT rc=%{http_code}\n" -X POST "$BASE/schema_registry" \
  -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d '{"database_id":"00000000-0000-0000-0000-000000000000","name":"p","engine":"e","created_by":"00000000-0000-0000-0000-000000000000"}'
# Expect rc=401 (permission denied) on all three.

# F1/F2 — must now be 401/403, not 200:
curl -sk -o /dev/null -w "anonymise_user rc=%{http_code}\n" -X POST "$BASE/rpc/anonymise_user" \
  -H "apikey: $ANON" -H "Content-Type: application/json" -d '{"target_user_id": -1}'
curl -sk -o /dev/null -w "auth_record_audit_event rc=%{http_code}\n" -X POST "$BASE/rpc/auth_record_audit_event" \
  -H "apikey: $ANON" -H "Content-Type: application/json" -d '{"event_type":"login_success","email":"x@y"}'
# Expect rc=404/401 (function not found for anon / permission denied).

# F5 — anon should no longer dump all emails:
curl -sk -w "\nusers rc=%{http_code}\n" "$BASE/users?select=id,email,username&limit=3" -H "apikey: $ANON"
# Expect rc=401, or only a curated public projection if a view was added.
```

---

## 6. Confirmation basis

- **LIVE-confirmed:** F1, F2, F3, F4, F5 (all reproduced with the anon key through Kong against the running stack). RLS state, grants, policies, default ACLs, role flags, and function ACLs read directly from the live `postgres` DB.
- **SQL-only (live unverifiable):** `mail_accounts` / `mail_messages` — the mail migration is not applied to this DB; their SQL RLS/grants are correct.
- **Probe residue:** Two probe rows (`schema_registry`, `track_binocle_runtime_migrations`) and one forged `auth_audit_events` row were created during proof-of-exploit and **all deleted**; row counts verified back to baseline. No migrations were applied; the database schema is unchanged.
