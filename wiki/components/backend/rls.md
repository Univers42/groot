# PostgREST + Row-Level Security — the database-level guardrail

> **In one sentence.** PostgREST + Row-Level Security is a database-level guardrail that makes cross-tenant data access structurally impossible by connecting through a non-superuser authenticator role (which cannot bypass RLS) and enforcing policies on every tenant-scoped table.

## What it is & why it exists

PostgREST is the REST gateway to PostgreSQL. Instead of connecting as the [superuser](glossary.md#superuser) (which bypasses RLS unconditionally), it connects as a dedicated non-superuser role called `authenticator` that is marked [NOBYPASSRLS](glossary.md#nobypassrls). This attribute makes the role structurally unable to skip [RLS](glossary.md#rls-row-level-security), no matter what future privilege changes occur.

For every request, PostgREST receives a [JWT](glossary.md#jwt-json-web-token) token from GoTrue, verifies its signature, and sets the verified claims (user ID, tenant ID, role) as a [GUC](glossary.md#guc-grand-unified-configuration) (`request.jwt.claims`) in the session. Then it executes [SET ROLE](glossary.md#set-role) to switch to the appropriate request role (anon, authenticated, or service_role) based on the JWT. Within that role's context, all RLS policies activate. Because the [authenticator role](glossary.md#authenticator-role) is NOBYPASSRLS and [NOINHERIT](glossary.md#noinherit), it gains no privileges until it explicitly switches roles—and switching only becomes active after JWT verification.

## How it works

- Client sends an API request with a JWT token (from GoTrue login) to Kong, which routes to PostgREST.
- PostgREST verifies the JWT signature using the shared JWT_SECRET.
- PostgREST sets request.jwt.claims (a GUC) to the verified JWT payload so identity helpers can read it within the same session.
- PostgREST executes SET ROLE <anon|authenticated|service_role> based on the verified JWT's role claim.
- The application code (a SELECT, INSERT, UPDATE, DELETE) runs in that role's context.
- RLS policies on the target table check auth.current_user_id() (which reads the GUC) against the row's owner_id or other identity columns.
- PostgreSQL filters the results to only rows where the policy condition is true; rows outside the policy are invisible to the query.
- The database itself refuses the query at the row level—there is no application code that can override it (because the authenticator role is NOBYPASSRLS).

## The code that does it

**What to look at:** PostgREST connects through a non-superuser authenticator role with NOBYPASSRLS, making RLS structurally inescapable.

```yaml
# apps/grobase/orchestrators/compose/base/auth-api.yml:104-136
  # ─── PostgreSQL REST API ─────────────────────────────────────────
  postgrest:
    extends: { file: orchestrators/compose/base/_common.yml, service: base }
    image: ghcr.io/univers42/grobase-postgrest:latest # pull-fallback (built from ./build context below)
    build:
      context: ./infra/docker/services/postgrest
      dockerfile: Dockerfile
    container_name: mini-baas-postgrest
    # No healthcheck BY DESIGN: the postgrest image is shell-less (no sh/curl/
    # wget), so an exec probe is impossible. Its health is observed upstream —
    # Kong's /rest/v1 route + `make health` probe it over HTTP.
    env_file: [.env]
    environment:
      # PostgREST connects as the dedicated non-superuser `authenticator` role
      # (NOBYPASSRLS), so RLS + FORCE RLS always bind the public REST/GraphQL
      # surface. The superuser DSN is NEVER used here (a superuser bypasses RLS
      # unconditionally). The fallback below mirrors the .env that
      # scripts/env/generate-env.sh writes; it still uses the authenticator role.
      PGRST_DB_URI: ${PGRST_DB_URI:-postgres://authenticator:${AUTHENTICATOR_PASSWORD:-authenticator}@postgres:5432/postgres}
      PGRST_DB_SCHEMA: ${PGRST_DB_SCHEMA:-public}
      PGRST_SERVER_PORT: 3000
      PGRST_JWT_SECRET: ${JWT_SECRET}
      PGRST_DB_SCHEMAS: public
      PGRST_DB_ANON_ROLE: anon
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      postgres:
        condition: service_healthy
      db-bootstrap:
        condition: service_completed_successfully
    mem_limit: 128m
    cpus: 0.25
```

**What to look at:** Identity helpers read the JWT's sub and tenant_id claims from the request.jwt.claims GUC, which PostgREST sets from the verified JWT token.

```sql
-- apps/grobase/scripts/migrations/postgresql/016_unify_rls.sql:21-51
CREATE OR REPLACE FUNCTION auth.current_user_id() RETURNS UUID
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'sub',
    NULLIF(current_setting('app.current_user_id', true), '')
  )::uuid;
$$;

CREATE OR REPLACE FUNCTION auth.uid() RETURNS UUID
LANGUAGE sql STABLE AS $$
  SELECT auth.current_user_id();
$$;

CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS UUID
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'tenant_id',
    NULLIF(current_setting('app.current_tenant_id', true), ''),
    auth.current_user_id()::text
  )::uuid;
$$;

CREATE OR REPLACE FUNCTION public.current_tenant_id() RETURNS TEXT
LANGUAGE sql STABLE AS $$
  SELECT auth.current_tenant_id()::text;
$$;

GRANT EXECUTE ON FUNCTION auth.current_user_id() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.current_tenant_id() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.current_tenant_id() TO anon, authenticated, service_role;
```

**What to look at:** RLS policies use auth.current_user_id() to enforce owner-scoping per request: a user can only read/write rows where the current identity matches the owner.

```sql
-- apps/grobase/scripts/migrations/postgresql/016_unify_rls.sql:70-100
  IF to_regclass('public.users') IS NOT NULL THEN
    DROP POLICY IF EXISTS users_select_own ON public.users;
    CREATE POLICY users_select_own ON public.users
      FOR SELECT USING (auth.current_user_id()::text = id::text);
  END IF;

  IF to_regclass('public.user_profiles') IS NOT NULL THEN
    DROP POLICY IF EXISTS user_profiles_select_own ON public.user_profiles;
    CREATE POLICY user_profiles_select_own ON public.user_profiles
      FOR SELECT USING (auth.current_user_id()::text = user_id::text);
  END IF;

  IF to_regclass('public.posts') IS NOT NULL THEN
    DROP POLICY IF EXISTS posts_select ON public.posts;
    CREATE POLICY posts_select ON public.posts
      FOR SELECT USING (is_public OR auth.current_user_id()::text = user_id::text);
  END IF;

  IF to_regclass('public.mock_orders') IS NOT NULL THEN
    DROP POLICY IF EXISTS mock_orders_owner_crud ON public.mock_orders;
    CREATE POLICY mock_orders_owner_crud ON public.mock_orders
      FOR ALL USING (auth.current_user_id()::text = owner_id)
      WITH CHECK (auth.current_user_id()::text = owner_id);
  END IF;

  IF to_regclass('public.projects') IS NOT NULL THEN
    DROP POLICY IF EXISTS projects_owner_crud ON public.projects;
    CREATE POLICY projects_owner_crud ON public.projects
      FOR ALL USING (auth.current_user_id()::text = owner_id)
      WITH CHECK (auth.current_user_id()::text = owner_id);
  END IF;
```

**What to look at:** The authenticator role is NOBYPASSRLS and NOINHERIT, making it structurally incapable of bypassing RLS; it can only switch to request roles after verifying the JWT.

```sql
-- apps/grobase/scripts/migrations/postgresql/065_least_privilege_rls.sql:63-94
DO $authrole$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    -- No LOGIN/password here: bootstrap sets both with the generated secret. We
    -- still pin NOINHERIT + NOBYPASSRLS + NOSUPERUSER so the role can never bypass
    -- RLS regardless of who later flips LOGIN on.
    CREATE ROLE authenticator NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE;
  ELSE
    -- Re-affirm the safety attributes on every run in case a prior bootstrap made
    -- the role differently. NOBYPASSRLS + NOSUPERUSER are the load-bearing ones.
    -- (LOGIN/password are left to bootstrap — not touched here.)
    ALTER ROLE authenticator WITH NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
END
$authrole$;

-- authenticator must be able to BECOME the three request roles PostgREST switches
-- to. These GRANTs are what let `SET ROLE authenticated` (etc.) succeed. Because
-- authenticator is NOINHERIT, holding the membership does NOT silently confer the
-- roles' privileges — they apply only after an explicit SET ROLE.
GRANT anon, authenticated, service_role TO authenticator;

-- It needs to connect to the database and see the public schema to do the switch.
GRANT CONNECT ON DATABASE postgres TO authenticator;
GRANT USAGE   ON SCHEMA public      TO authenticator;
DO $authgrant$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'auth') THEN
    GRANT USAGE ON SCHEMA auth TO authenticator;
  END IF;
END
$authgrant$;
```

**What to look at:** FORCE ROW LEVEL SECURITY removes the table-owner exemption so RLS policies bind even the creator; combined with NOBYPASSRLS on PostgREST's authenticator role, escape is impossible.

```sql
-- apps/grobase/scripts/migrations/postgresql/065_least_privilege_rls.sql:104-124
DO $force$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT n.nspname AS schema_name, c.relname AS table_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
      AND c.relrowsecurity            -- RLS is ENABLEd
      AND NOT c.relforcerowsecurity   -- but not yet FORCEd
      AND n.nspname IN ('public', 'auth', 'gdpr', 'session')
  LOOP
    EXECUTE format(
      'ALTER TABLE %I.%I FORCE ROW LEVEL SECURITY',
      r.schema_name, r.table_name
    );
    RAISE NOTICE 'FORCE ROW LEVEL SECURITY on %.%', r.schema_name, r.table_name;
  END LOOP;
END
$force$;
```

**What to look at:** Secret tables are revoked from anon/authenticated to prevent column-level bypass; RLS is the row gate, column revocation is the column gate (defence in depth).

```sql
-- apps/grobase/scripts/migrations/postgresql/065_least_privilege_rls.sql:139-161
DO $secret_db$
BEGIN
  IF to_regclass('public.tenant_databases') IS NOT NULL THEN
    REVOKE ALL ON public.tenant_databases FROM anon, authenticated;
    -- Belt-and-suspenders: undo the schema-wide ALTER DEFAULT PRIVILEGES grant
    -- (migration 001) for any privilege re-added to these roles in future.
    -- (No GRANT back to anon/authenticated — they get nothing on this table.)
  END IF;
END
$secret_db$;

-- 3b. tenant_api_keys — holds key_hash (the credential verifier) + scopes. The
--     public REST surface never needs to read the hash. Revoke the blanket grant.
--     Self-service key issuance/rotation goes through the Go control plane
--     (service_role), not PostgREST, so authenticated loses nothing it actually
--     uses on the public surface.
DO $secret_keys$
BEGIN
  IF to_regclass('public.tenant_api_keys') IS NOT NULL THEN
    REVOKE ALL ON public.tenant_api_keys FROM anon, authenticated;
  END IF;
END
$secret_keys$;
```

## Where it sits in the request flow

PostgREST sits between Kong (the gateway, which authenticates and rate-limits) and PostgreSQL (the datastore). Requests flow Kong → PostgREST → RLS policies (in Postgres). The permission-engine and query-router (TypeScript services upstream of Kong) handle business logic and API validation, but the final data-plane guardrail is the database itself: if a request passes all upstream gates, RLS is the last line of [defence in depth](glossary.md#defense-in-depth) that prevents cross-owner access at the row level. This is the database half of [owner-scoping](glossary.md#owner-scoping): the [request context](glossary.md#request-context) carries the verified identity, [least privilege](glossary.md#least-privilege) caps what each role can touch, [column-level privilege](glossary.md#column-level-privilege) revocation guards the secret tables, [identity helper](glossary.md#identity-helper) functions read the claims, and the [service role](glossary.md#service-role) handles the privileged control-plane path. The [FORCE ROW LEVEL SECURITY](glossary.md#force-row-level-security) sweep ensures even a table's creator cannot slip past its policies.

## Remember this

> Even if application logic is bypassed, the database refuses cross-owner reads because PostgREST is a non-superuser role with NOBYPASSRLS, and every table that needs isolation has RLS forced on it.

---
**See also:** [reverse_proxy.md](reverse_proxy.md) · [query-router-ApiKeyMiddleware.md](query-router-ApiKeyMiddleware.md) · [owner_isolation.md](owner_isolation.md) · [ABAC_RBAC.md](ABAC_RBAC.md) · [Glossary](glossary.md)
