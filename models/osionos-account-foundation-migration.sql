-- osionos-account-foundation-migration.sql — the account plane's database foundation.
--
-- One transaction creates: the role a per-user JWT reaches the account plane with,
-- the uid helper that turns a verified token into a row owner, the first
-- account-plane table (public.osionos_sessions), the audit columns the bridge guard
-- writes, and the indexes whose absence makes today's queries sequential scans.
-- Nothing reads these objects yet.
--
-- WHO REACHES WHAT
--   service_role          everything (the bridge).
--   osionos_account_user  only the relations marked COMMENT ... 'osionos:account-plane',
--                         through column grants and row-level security.
--   anon, authenticated   nothing.
--
-- THE ROLE IS THE BOUNDARY
--   The `role` claim in a JWT is a claim: a client picks it. Only the database's
--   role assignment is a fact, so the helper checks current_user (and the policy
--   names the role in polroles). Every condition fails closed to NULL.
--
-- WHY THE ROLE IS NORMALIZED ON EVERY RUN
--   A role created by hand with BYPASSRLS survives a pg_roles-guarded CREATE and
--   reads every user's rows (reproduced). The guard only creates; the ALTER ROLE
--   and the membership revoke outside it are what make the shape true.
--
-- ON DELETE CASCADE DELETES INSTEAD OF REVOKING
--   A session row disappears with its user instead of being marked revoked, so a
--   delta poll on revoked_at never sees a user deleted straight in GoTrue. P0-4
--   therefore treats a missing jti row as revoked, and account deletion writes
--   revoked_reason = 'deletion' before it deletes.
--
-- WHERE IT RUNS
--   scripts/apply-models-migrations.sh lists it in ORDERED_LAST: after the
--   alphabetical pass (it indexes osionos_feed_shares, created by
--   osionos-feed-engagement-migration.sql, and alters osionos_bridge_audit_events,
--   created by osionos-bridge-migration.sql — both sort after it alphabetically)
--   and before the service-role-only pass, which must not revoke the account role.
--   The OTHER runner, scripts/apply-models.sh, sorts it BEFORE
--   osionos-bridge-migration.sql: on a database without the bridge tables this
--   file fails as one rolled-back transaction and applies on the next pass. A
--   database adopted without running it (apply-models.sh:121-126 records the
--   files it did not run) has no role and no table, and the bridge answers 503
--   account_plane_unavailable — never a leak.
--
-- DESKTOP
--   P0-4 must wire apps/osionos-electron/native/firstrun.mjs to this file, and
--   that wiring is not free: osionos_feed_shares never exists on the desktop
--   (firstrun.mjs:34-48) and auth.users exists only after GoTrue starts
--   (firstrun.mjs:109-111). The file therefore needs a guard or a split there,
--   and it runs in the post-GoTrue step.
--
-- Idempotent: a second run moves no grant, policy, role attribute or index
-- (check g of scripts/verify/models-grants.sh).

BEGIN;

-- Caveat: a busy table makes this file fail (the whole transaction rolls back)
-- instead of waiting; the next run retries it. 5 s is a budget, not a promise.
SET LOCAL lock_timeout = '5s';

-- 1. The account role.
-- The CREATE is guarded on pg_roles; the ALTER below is not, and that is the
-- point — a role created by hand with BYPASSRLS (or LOGIN) survives the guard.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'osionos_account_user') THEN
    CREATE ROLE osionos_account_user NOLOGIN NOINHERIT NOBYPASSRLS;
  END IF;
END
$$;

ALTER ROLE osionos_account_user NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;

-- A role that is a member of another role reaches that role's privileges through
-- it; the account role must be a member of nothing.
-- The grantor is named on purpose: REVOKE without GRANTED BY only removes the
-- memberships the current role granted, so a membership handed out by a
-- CREATEROLE role survived the plain revoke (with a WARNING) and the account
-- role kept that role's privileges. GRANTED BY names the grantor, CASCADE
-- removes what it granted in turn.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT g.rolname, m.grantor::regrole::text AS grantor
      FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid
     WHERE m.member = (SELECT oid FROM pg_roles WHERE rolname = 'osionos_account_user')
  LOOP
    EXECUTE format('REVOKE %I FROM osionos_account_user GRANTED BY %I CASCADE', r.rolname, r.grantor);
  END LOOP;
END
$$;

-- PostgREST connects as `authenticator` and switches to the role the token names;
-- without this membership the account role is unreachable over HTTP.
-- WITH INHERIT FALSE, SET TRUE: the authenticator may SWITCH to the account role
-- but must not INHERIT its privileges. The option lives on the membership, not
-- on the role: db-bootstrap.psql alters an existing authenticator without
-- NOINHERIT, and a membership granted to an INHERIT role would otherwise hand
-- the account role's privileges to the authenticator itself.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    GRANT osionos_account_user TO authenticator WITH INHERIT FALSE, SET TRUE;
  END IF;
END
$$;

GRANT USAGE ON SCHEMA public TO osionos_account_user;

-- 2. The uid helper: the token's subject, but only for the role that is allowed
-- to ask. The ROLE is the boundary (GoTrue never issues osionos_account_user and
-- a client picks its own `aud`), so every condition fails closed to NULL: an array
-- `aud`, an upper-case or malformed `sub`, a missing claim set.
-- Caveat: claims that are not JSON raise 22P02 (invalid_text_representation).
-- Only a hand-set setting can produce that — PostgREST always sends JSON — and
-- the error still fails closed: the calling statement raises, it does not widen.
-- It is NOT SECURITY DEFINER: it reads the caller's claims and nothing else.
CREATE OR REPLACE FUNCTION public.osionos_account_uid() RETURNS uuid
  LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT CASE
    WHEN current_user = 'osionos_account_user'
     AND c ->> 'role' = 'osionos_account_user'
     AND c ->> 'aud' = 'osionos-account'
     AND c ->> 'sub' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    THEN (c ->> 'sub')::uuid END
  FROM (SELECT NULLIF(current_setting('request.jwt.claims', true), '')::jsonb AS c) AS s
$$;
REVOKE ALL ON FUNCTION public.osionos_account_uid() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.osionos_account_uid() TO osionos_account_user, service_role;

-- 3. The first account-plane table: one row per sign-in, keyed by the app token's
-- jti. ip_prefix is how "a raw IP is never stored" is enforced by the database: a
-- /32 is refused by the CHECK, so the column can only hold a network.
-- ip_hash (here and on the audit table) is an HMAC-SHA256 keyed by a server
-- secret, written by the bridge (clientMeta in P0-3). The database cannot enforce
-- the key, so it cannot tell a keyed hash from an unkeyed one — and an unkeyed
-- sha256 of an IPv4 address is reversed by trying all 2^32 inputs.
CREATE TABLE IF NOT EXISTS public.osionos_sessions (
  id UUID PRIMARY KEY,                                   -- the osionos_v1 token jti
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  auth_method TEXT NOT NULL CHECK (auth_method IN ('password','email_otp','passkey','oauth','handoff','refresh')),
  ip_prefix CIDR CHECK (ip_prefix IS NULL OR (family(ip_prefix) = 4 AND masklen(ip_prefix) <= 24)
                                          OR (family(ip_prefix) = 6 AND masklen(ip_prefix) <= 48)),
  ip_hash TEXT CHECK (ip_hash IS NULL OR ip_hash ~ '^[0-9a-f]{64}$'),
  user_agent TEXT CHECK (user_agent IS NULL OR char_length(user_agent) <= 256),
  sudo_until TIMESTAMPTZ,
  refresh_hash TEXT CHECK (refresh_hash IS NULL OR refresh_hash ~ '^[0-9a-f]{64}$'),
  family_id UUID,
  parent_id UUID,
  revoked_at TIMESTAMPTZ,
  revoked_reason TEXT CHECK (revoked_reason IN ('user','admin','logout_all','password_change','refresh_reuse','deletion')),
  CHECK (expires_at > created_at),
  CHECK ((revoked_at IS NULL) = (revoked_reason IS NULL))
);

-- Every index is NAMED and IF NOT EXISTS: an unnamed CREATE INDEX makes a
-- duplicate on every boot.
CREATE INDEX IF NOT EXISTS osionos_sessions_user_active_idx ON public.osionos_sessions (user_id, created_at DESC) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS osionos_sessions_revoked_idx ON public.osionos_sessions (revoked_at) WHERE revoked_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS osionos_sessions_expires_idx ON public.osionos_sessions (expires_at);

-- grobase's CREATE TABLE hook (apps/grobase/scripts/migrations/postgresql/012_realtime_triggers_all_tables.sql:64)
-- broadcasts every row of every new public table — ip_hash and refresh_hash
-- included. The trigger is dropped here, not only by realtime-cdc-off, because
-- this file may run without that pass (apply-models.sh).
DROP TRIGGER IF EXISTS osionos_sessions_realtime_trigger ON public.osionos_sessions;

ALTER TABLE public.osionos_sessions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.osionos_sessions FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.osionos_sessions TO service_role;
-- Column grants, not a table grant: the role can never select=* (PostgREST
-- answers 42501), so a caller names the columns it wants. A table-level grant
-- here would hand the role ip_hash, refresh_hash and the user_id of every row.
-- The REVOKE first: a table-level grant left over from an earlier run (or from
-- a hand-made grant) survives a replay, and only this line takes it back.
REVOKE ALL ON public.osionos_sessions FROM osionos_account_user;
GRANT SELECT (id, created_at, expires_at, last_seen_at, auth_method, ip_prefix, user_agent, revoked_at, revoked_reason)
  ON public.osionos_sessions TO osionos_account_user;
DROP POLICY IF EXISTS osionos_sessions_service_role_all ON public.osionos_sessions;
CREATE POLICY osionos_sessions_service_role_all ON public.osionos_sessions FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS osionos_sessions_owner_read ON public.osionos_sessions;
-- (SELECT public.osionos_account_uid()) is deliberate: wrapped, it is evaluated
-- once per query (an InitPlan); bare, it would be evaluated once per row.
CREATE POLICY osionos_sessions_owner_read ON public.osionos_sessions FOR SELECT TO osionos_account_user
  USING (user_id = (SELECT public.osionos_account_uid()));
-- The marker every account-plane table carries; the grants checks read it.
COMMENT ON TABLE public.osionos_sessions IS 'osionos:account-plane';

-- 4. The indexes today's queries miss. This step runs BEFORE step 5 on purpose:
-- the sign-in function osionos_bridge_upsert_workspace locks the identities
-- table and then the audit table (osionos-bridge-migration.sql:279,354), so
-- taking the audit table's lock first deadlocks a concurrent sign-in
-- (reproduced: 40P01). The identities lock comes first here, the audit lock
-- second, and the two orders then agree.
-- A replay takes the same locks: CREATE INDEX IF NOT EXISTS locks the table
-- before it finds the index already there, so the order matters on a
-- converged database too, not only on the first run.
-- Caveat: a plain CREATE INDEX takes a write lock for its duration — fine at
-- today's row counts (both tables are small), wrong for a table with millions of
-- rows (build it CONCURRENTLY, outside this transaction).
CREATE INDEX IF NOT EXISTS osionos_bridge_identities_email_hash_idx ON public.osionos_bridge_identities (email_hash);
CREATE INDEX IF NOT EXISTS osionos_feed_shares_user_target_idx ON public.osionos_feed_shares (user_id, target, created_at DESC);

-- 5. The audit columns the bridge guard writes.
-- The ALTER runs only when one of the four columns is missing: a converged replay
-- then takes no AccessExclusiveLock on a table the bridge writes on every sign-in.
DO $$
BEGIN
  IF (SELECT count(*) FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'osionos_bridge_audit_events'
         AND column_name IN ('actor_id','session_id','ip_hash','user_agent')) < 4 THEN
    ALTER TABLE public.osionos_bridge_audit_events
      ADD COLUMN IF NOT EXISTS actor_id UUID,
      ADD COLUMN IF NOT EXISTS session_id UUID,
      ADD COLUMN IF NOT EXISTS ip_hash TEXT CHECK (ip_hash IS NULL OR ip_hash ~ '^[0-9a-f]{64}$'),
      ADD COLUMN IF NOT EXISTS user_agent TEXT CHECK (user_agent IS NULL OR char_length(user_agent) <= 256);
  END IF;
END
$$;

-- Same reason as the sessions table: the table now carries ip_hash and
-- user_agent, and on an adopted database cdc-off may never have run.
-- Caveat: DROP TRIGGER takes an AccessExclusiveLock on the table, so this line
-- locks the audit table too — it belongs after the identities index, not before.
DROP TRIGGER IF EXISTS osionos_bridge_audit_events_realtime_trigger ON public.osionos_bridge_audit_events;

-- No foreign key on actor_id: an audit row must outlive the user it describes.
CREATE INDEX IF NOT EXISTS osionos_bridge_audit_events_actor_idx ON public.osionos_bridge_audit_events (actor_id, created_at DESC) WHERE actor_id IS NOT NULL;

-- 6. PostgREST caches the schema; a new table and a new role are invisible to it
-- until it reloads.
NOTIFY pgrst, 'reload schema';

COMMIT;

-- DOWN (manual, in reverse order). Valid only while no bridge reads these
-- objects: the role is cluster-wide, and the moment public.osionos_sessions is
-- gone the bridge answers 503 account_plane_unavailable.
--   DROP POLICY IF EXISTS osionos_sessions_owner_read ON public.osionos_sessions;
--   DROP POLICY IF EXISTS osionos_sessions_service_role_all ON public.osionos_sessions;
--   DROP TABLE IF EXISTS public.osionos_sessions;
--   DROP FUNCTION IF EXISTS public.osionos_account_uid();
--   DROP INDEX IF EXISTS public.osionos_sessions_user_active_idx;
--   DROP INDEX IF EXISTS public.osionos_sessions_revoked_idx;
--   DROP INDEX IF EXISTS public.osionos_sessions_expires_idx;
--   DROP INDEX IF EXISTS public.osionos_bridge_audit_events_actor_idx;
--   DROP INDEX IF EXISTS public.osionos_feed_shares_user_target_idx;
--   DROP INDEX IF EXISTS public.osionos_bridge_identities_email_hash_idx;
--   ALTER TABLE public.osionos_bridge_audit_events
--     DROP COLUMN IF EXISTS user_agent,
--     DROP COLUMN IF EXISTS ip_hash,
--     DROP COLUMN IF EXISTS session_id,
--     DROP COLUMN IF EXISTS actor_id;
--   REVOKE osionos_account_user FROM authenticator;
--   REVOKE USAGE ON SCHEMA public FROM osionos_account_user;
--   DROP ROLE osionos_account_user;
