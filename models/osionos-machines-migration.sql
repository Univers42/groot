-- osionos-machines-migration.sql — the machines a user has paired.
--
-- WHY THIS FILE EXISTS
--   Every user pairs their OWN machine (ADR 0037); osionos never runs a cloud
--   OS for them. The bridge signs a machine token with ed25519 and the node
--   checks it against the machine's public key, so the bridge has to know, per
--   user, which machines exist, which key each holds and which one opens by
--   default. A paired machine is revocable, and a revocable thing has to be
--   LOOKED UP: it needs a row. The old NODE_ID ('laptop' for every user,
--   ide-token.mjs:35) let two users collide; the id here is random per machine.
--
-- WHAT IT CREATES
--   public.osionos_machines   one row per paired machine: its id, its owner,
--                             its name, its platform, its ed25519 public key,
--                             the fingerprint a human compares, whether it is
--                             the default, and the revocation.
--
-- WHO REACHES WHAT
--   service_role          everything. The bridge writes the row through it and
--                         it is the only writer (ADR 0003): the account role
--                         must not be able to plant a key.
--   osionos_account_user  the published columns of its OWN rows, through column
--                         grants and row-level security.
--   anon, authenticated   nothing.
--
-- WHY pubkey IS ON THE FAR SIDE OF THE LINE
--   The account role's grants are the whole boundary (the house model of
--   public.osionos_personal_access_tokens). The fingerprint is what a person
--   compares when pairing; the raw key is what the bridge verifies with. The
--   list route has no use for the key, so it cannot leak it even by accident.
--
-- WHY THE REALTIME TRIGGER IS DROPPED HERE
--   grobase's CREATE TABLE hook (apps/grobase/scripts/migrations/postgresql/
--   012_realtime_triggers_all_tables.sql:64) broadcasts every row of every new
--   public table past every grant: a broadcast would carry pubkey.
--
-- ERASURE
--   user_id is ON DELETE CASCADE to auth.users, so deleting the identity takes
--   the rows, but the erase runs before that delete: osionos-account-erasure-migration.sql
--   registers (osionos_machines, user_id, owner, delete), and p6_machines_erase
--   and p6_machines_erase_mutation in scripts/verify/models-grants/account-checks.sql
--   prove the registry row, not the cascade, removes them.
--
-- WHERE IT RUNS
--   scripts/apply-models-migrations.sh lists it in ORDERED_LAST after
--   osionos-personal-access-tokens-migration.sql (the role and the uid helper
--   exist by then) and before osionos-account-erasure-migration.sql (its
--   registry names this table) and osionos-service-role-only-migration.sql
--   (the catalog pass must SEE this table).
--
-- Idempotent: a second run moves no grant, policy, RLS flag or index
-- (check g of scripts/verify/models-grants.sh).

BEGIN;

-- Caveat: a busy table makes this file fail (the whole transaction rolls back)
-- instead of waiting; the next run retries it. 5 s is a budget, not a promise.
SET LOCAL lock_timeout = '5s';

-- 1. The table.
-- id is 'm-' and 16 base32 characters (80 random bits), minted by the bridge.
-- pubkey is a raw 32-byte ed25519 key in unpadded base64url: exactly 43 chars.
-- fingerprint is four groups of four base32 characters, the form a human reads
-- aloud while pairing.
-- Caveat: the CHECKs prove the SHAPE of a key, not that it is a point on the
-- curve; the bridge is the only place a key is parsed.
CREATE TABLE IF NOT EXISTS public.osionos_machines (
  id TEXT PRIMARY KEY CHECK (id ~ '^m-[a-z2-7]{16}$'),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 64),
  platform TEXT NOT NULL CHECK (platform ~ '^(linux|darwin|win32)-(x64|arm64)$'),
  pubkey TEXT NOT NULL CHECK (pubkey ~ '^[A-Za-z0-9_-]{43}$'),
  fingerprint TEXT NOT NULL CHECK (fingerprint ~ '^[A-Z2-7]{4}(-[A-Z2-7]{4}){3}$'),
  is_default BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_at TIMESTAMPTZ
);

-- 2. The indexes, named and IF NOT EXISTS (an unnamed CREATE INDEX makes a
-- duplicate on every boot).
-- One default per user among the live machines, enforced by the database: two
-- concurrent "make default" requests cannot both win. A revoked machine keeps
-- its flag for the record and does not block the next default.
CREATE UNIQUE INDEX IF NOT EXISTS osionos_machines_one_default_uidx
  ON public.osionos_machines (user_id) WHERE is_default AND revoked_at IS NULL;
-- The owner's list.
CREATE INDEX IF NOT EXISTS osionos_machines_user_idx
  ON public.osionos_machines (user_id);

-- 3. The grants, in the house order.
DROP TRIGGER IF EXISTS osionos_machines_realtime_trigger ON public.osionos_machines;

ALTER TABLE public.osionos_machines ENABLE ROW LEVEL SECURITY;
-- FORCE, which the token table lacks: a non-superuser owner (a future
-- migration role) is held to the policies too. A superuser still bypasses.
ALTER TABLE public.osionos_machines FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.osionos_machines FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.osionos_machines TO service_role;
-- The REVOKE first: a table-level grant left over from an earlier run (or from
-- a hand-made grant) survives a replay, and only this line takes it back.
REVOKE ALL ON public.osionos_machines FROM osionos_account_user;
-- Column grants, never a table grant: select=* answers 42501. pubkey and
-- user_id are absent; the policy reads user_id without the role holding it.
GRANT SELECT (id, name, platform, fingerprint, is_default, created_at, revoked_at)
  ON public.osionos_machines TO osionos_account_user;
DROP POLICY IF EXISTS osionos_machines_service_role_all ON public.osionos_machines;
CREATE POLICY osionos_machines_service_role_all ON public.osionos_machines FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS osionos_machines_owner_read ON public.osionos_machines;
-- (SELECT public.osionos_account_uid()) is deliberate: wrapped, it is evaluated
-- once per query (an InitPlan); bare, it would be evaluated once per row.
CREATE POLICY osionos_machines_owner_read ON public.osionos_machines FOR SELECT TO osionos_account_user
  USING (user_id = (SELECT public.osionos_account_uid()));
-- The marker every account-plane table carries; the grants checks read it.
COMMENT ON TABLE public.osionos_machines IS 'osionos:account-plane';

-- 4. PostgREST caches the schema; a new table is invisible to it until it
-- reloads.
NOTIFY pgrst, 'reload schema';

COMMIT;

-- DOWN (manual, in reverse order). Valid only while no bridge reads this
-- table: the moment public.osionos_machines is gone, no machine token verifies.
--   DROP POLICY IF EXISTS osionos_machines_owner_read ON public.osionos_machines;
--   DROP POLICY IF EXISTS osionos_machines_service_role_all ON public.osionos_machines;
--   DROP INDEX IF EXISTS osionos_machines_user_idx;
--   DROP INDEX IF EXISTS osionos_machines_one_default_uidx;
--   DROP TABLE IF EXISTS public.osionos_machines;
