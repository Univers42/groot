-- osionos-personal-access-tokens-migration.sql — the personal access token table.
--
-- WHY THIS FILE EXISTS
--   Nothing in the tree mints, stores, lists or revokes a per-user API secret.
--   The IDE token is a JWT scoped to one workspace and it dies with the IDE
--   sandbox; the app session is a session, not a credential (it expires, it is
--   refused by the per-user cut-off and by the per-session revocation set), so
--   handing one to a script or an MCP client is what the account platform must
--   stop doing. A personal access token is the first real credential of the
--   account plane, and a revocable credential has to be LOOKED UP: it cannot be
--   a self-verifying token, so it needs a row.
--
-- WHAT IT CREATES
--   public.osionos_personal_access_tokens   one row per token: its name, its
--                                           kind, its scopes or its grants, the
--                                           sha256 of the secret, the expiry,
--                                           the last use and the revocation.
--
-- WHO REACHES WHAT
--   service_role          everything. The bridge writes the row through it and
--                         it is the only writer (ADR 0003): the account role
--                         must not be able to write a hash.
--   osionos_account_user  the published columns of its OWN rows, through column
--                         grants and row-level security.
--   anon, authenticated   nothing.
--
-- WHY token_hash IS ON THE FAR SIDE OF THE LINE
--   The account role's grants are the whole boundary (the house model of
--   public.osionos_sessions, models/osionos-account-foundation-migration.sql):
--   token_hash is deliberately absent from them, so the owner's own list route
--   cannot leak it even by accident. The secret itself is never stored: the
--   row holds the sha256 of the whole secret, and only the create answer
--   carries the secret, once.
--
-- WHY THE GRANTS ARE A COLUMN AND NOT A TABLE
--   A token's grant set is read with its token, in one row, and it is small (a
--   handful of resources). A second table would be a second join and a second
--   idempotency surface for no query this package makes.
--
-- WHY THE REALTIME TRIGGER IS DROPPED HERE
--   grobase's CREATE TABLE hook (apps/grobase/scripts/migrations/postgresql/
--   012_realtime_triggers_all_tables.sql:64) broadcasts every row of every new
--   public table, and realtime_notify() is SECURITY DEFINER with no grant and
--   no RLS check: a row broadcast would carry token_hash to every subscriber.
--
-- WHERE IT RUNS
--   scripts/apply-models-migrations.sh lists it in ORDERED_LAST: after
--   osionos-account-profiles-migration.sql (it grants to the role the
--   foundation file creates) and before osionos-service-role-only-migration.sql
--   (the catalog pass must SEE this table, or the table keeps the legacy
--   default privileges instead of being revoked from anon/authenticated).
--
-- Idempotent: a second run moves no grant, policy, RLS flag or index
-- (check g of scripts/verify/models-grants.sh).

BEGIN;

-- Caveat: a busy table makes this file fail (the whole transaction rolls back)
-- instead of waiting; the next run retries it. 5 s is a budget, not a promise.
SET LOCAL lock_timeout = '5s';

-- 1. The table.
-- name is what the user calls the token, and it is the only label a list can
-- show: a prefix of the secret buys nothing (eight characters of a 256-bit
-- secret are not a name).
-- kind is classic (a list of scopes) or fine_grained (a list of grants); the
-- two CHECKs below are the "one or the other, never both, never neither" rule,
-- enforced by the database as well as by the bridge.
-- last_used_at is when the token was last used. The bridge writes it
-- best-effort, at most once per token per hour, so the value is accurate to
-- the hour; NULL means never used.
-- Caveat: the table is stricter than the bridge in one place and looser in
-- another. Stricter: a row whose expiry is not in the future cannot exist at
-- all. Looser: a classic token with an empty scope list is accepted here (the
-- bridge refuses that body before it ever reaches this table).
CREATE TABLE IF NOT EXISTS public.osionos_personal_access_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 64),
  kind TEXT NOT NULL CHECK (kind IN ('classic','fine_grained')),
  -- classic: 'pages:read' / 'pages:write'; fine-grained: empty.
  scopes TEXT[] NOT NULL DEFAULT '{}',
  -- fine-grained: [{resource, attributes[], permissions[]}]; classic: empty.
  grants JSONB NOT NULL DEFAULT '[]'::jsonb,
  -- sha256 of the whole secret, hex. Never the secret.
  token_hash TEXT NOT NULL CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  expires_at TIMESTAMPTZ NOT NULL,
  last_used_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_at TIMESTAMPTZ,
  revoked_reason TEXT CHECK (revoked_reason IN ('user','admin')),
  -- The expiry is required at the storage layer: a row without a future expiry
  -- cannot exist.
  CHECK (expires_at > created_at),
  CHECK (kind = 'classic' OR scopes = '{}'),
  CHECK (kind = 'fine_grained' OR jsonb_array_length(grants) = 0),
  CHECK (jsonb_typeof(grants) = 'array')
);

-- 2. The indexes, named and IF NOT EXISTS (an unnamed CREATE INDEX makes a
-- duplicate on every boot).
-- The unique index on the hash is the lookup a bearer token is resolved with,
-- and its uniqueness is what turns a hash collision into a 409 instead of an
-- ambiguity.
CREATE UNIQUE INDEX IF NOT EXISTS osionos_personal_access_tokens_hash_uidx
  ON public.osionos_personal_access_tokens (token_hash);
-- The owner's list.
CREATE INDEX IF NOT EXISTS osionos_personal_access_tokens_user_idx
  ON public.osionos_personal_access_tokens (user_id, created_at DESC);

-- 3. The grants, in the house order.
DROP TRIGGER IF EXISTS osionos_personal_access_tokens_realtime_trigger ON public.osionos_personal_access_tokens;

ALTER TABLE public.osionos_personal_access_tokens ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.osionos_personal_access_tokens FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.osionos_personal_access_tokens TO service_role;
-- The REVOKE first: a table-level grant left over from an earlier run (or from
-- a hand-made grant) survives a replay, and only this line takes it back.
REVOKE ALL ON public.osionos_personal_access_tokens FROM osionos_account_user;
-- Column grants, never a table grant: the role can never select=* (PostgREST
-- answers 42501), so a caller names the columns it wants. token_hash is
-- deliberately absent: the account role cannot select it at all, so the owner's
-- list route cannot leak it even by accident.
GRANT SELECT (id, user_id, name, kind, scopes, grants, created_at, expires_at,
              last_used_at, revoked_at, revoked_reason)
  ON public.osionos_personal_access_tokens TO osionos_account_user;
DROP POLICY IF EXISTS osionos_personal_access_tokens_service_role_all ON public.osionos_personal_access_tokens;
CREATE POLICY osionos_personal_access_tokens_service_role_all ON public.osionos_personal_access_tokens FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS osionos_personal_access_tokens_owner_read ON public.osionos_personal_access_tokens;
-- (SELECT public.osionos_account_uid()) is deliberate: wrapped, it is evaluated
-- once per query (an InitPlan); bare, it would be evaluated once per row.
CREATE POLICY osionos_personal_access_tokens_owner_read ON public.osionos_personal_access_tokens FOR SELECT TO osionos_account_user
  USING (user_id = (SELECT public.osionos_account_uid()));
-- The marker every account-plane table carries; the grants checks read it.
COMMENT ON TABLE public.osionos_personal_access_tokens IS 'osionos:account-plane';

-- 4. PostgREST caches the schema; a new table is invisible to it until it
-- reloads.
NOTIFY pgrst, 'reload schema';

COMMIT;

-- DOWN (manual, in reverse order). Valid only while no bridge reads this
-- table: the moment public.osionos_personal_access_tokens is gone, every
-- personal access token stops resolving.
--   DROP POLICY IF EXISTS osionos_personal_access_tokens_owner_read ON public.osionos_personal_access_tokens;
--   DROP POLICY IF EXISTS osionos_personal_access_tokens_service_role_all ON public.osionos_personal_access_tokens;
--   DROP INDEX IF EXISTS osionos_personal_access_tokens_user_idx;
--   DROP INDEX IF EXISTS osionos_personal_access_tokens_hash_uidx;
--   DROP TABLE IF EXISTS public.osionos_personal_access_tokens;
