-- osionos-account-profession-migration.sql — the profession column on the
-- account profile.
--
-- WHY THIS FILE EXISTS
--   The profession is the user's own pick (P2-4 decision 6): one of eight ids,
--   written through P1-2a's PATCH /api/account/profile under the same If-Match
--   as every other profile field. There is no second write path, so the pick
--   lands in one column of the row the account plane already owns.
--   The column is added HERE and not in P1-1's profiles file: that file is the
--   account plane's baseline and is not edited by a later package, and one
--   file per feature keeps the migration history readable.
--
-- WHAT IT CREATES
--   public.osionos_profiles.profession   TEXT, NULL or one of the eight ids
--
-- WHO REACHES WHAT
--   osionos_account_user  SELECT (profession) and UPDATE (profession): the
--                         user reads and writes their own profession, and
--                         nothing else.
--   service_role          everything (it owns the tables anyway), so the
--                         bridge's public profile read can carry it.
--   anon, authenticated   nothing.
--
-- WHY THE CHECK IS NAMED osionos_profiles_profession_check
--   P1-2a's bridge reads the refused column out of the constraint name
--   (apps/osionos/app/scripts/bridge-account-profile.mjs:140-155): the name
--   is the column with the _check suffix. A bad value therefore answers
--   422 invalid_field with field "profession" and never a generic error.
--
-- WHY THE CHECK IS INSTALLED BY A GUARDED BLOCK
--   The runner applies every file on every boot, so an unconditional
--   DROP CONSTRAINT + ADD CONSTRAINT would revalidate every row of the table
--   on every boot (models/osionos-code-surface-migration.sql:16-18 is the
--   pattern NOT to copy). The block below adds the constraint when it is
--   absent and replaces it only when the live definition is not the target
--   definition.
--
-- WHY THE TARGET DEFINITION IS BUILT AT RUN TIME
--   The two definitions are compared with pg_get_constraintdef, which renders
--   a CHECK in this PostgreSQL's own words. Rendering the target on a scratch
--   column of the SAME type keeps the comparison exact on every version: a
--   PostgreSQL upgrade changes the rendering on both sides at once, so the
--   constraint is replaced once and then converges. A hardcoded rendering
--   would differ from the live one forever after an upgrade and the file
--   would revalidate every row on every boot.
--   Caveat: the scratch table lives in pg_temp and is dropped at COMMIT; it
--   never reaches the public schema, where the checks look for osionos_%
--   relations.
--
-- WHY THE COLUMN INHERITS THE ROW POLICIES
--   osionos_profiles_owner_read and osionos_profiles_owner_update (P1-1)
--   already limit the row to the caller, and a column inherits them: another
--   user's profession is not reachable through the account role.
--
-- WHY THE VERSION MOVES WHEN THE PROFESSION CHANGES
--   osionos_profiles_touch (P1-1) bumps version whenever the row really
--   changes, so writing the profession bumps it. The route returns the new
--   version, and a client holding the older ETag gets the 412 P1-2a defines.
--
-- WHY THE PROFESSION IS NOT IN search_doc
--   P2-4 decision 9: nothing filters the directory by profession yet, and a
--   trigger maintaining a tsvector for it would cost on every write.
--
-- WHY THERE IS NO REALTIME TRIGGER
--   The account-plane tables had their realtime triggers dropped on purpose
--   (P1-1): the broadcast carries the whole row past every grant. Adding a
--   column adds no trigger.
--
-- WHERE IT RUNS
--   scripts/apply-models-migrations.sh lists it in ORDERED_LAST, right after
--   osionos-account-username-migration.sql and before
--   osionos-publish-account-migration.sql: the column and its grants must
--   exist before any bridge image that names the column.
--
-- Idempotent: a second run moves no grant, no constraint and no policy.

BEGIN;

-- Caveat: a busy table makes this file fail (the whole transaction rolls
-- back) instead of waiting; the next run retries it. 5 s is a budget, not a
-- promise.
SET LOCAL lock_timeout = '5s';

-- The table has to exist: this file grants on its columns, and a grant on a
-- missing column fails with 42703 and says nothing useful.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                  WHERE table_schema = 'public' AND table_name = 'osionos_profiles') THEN
    RAISE EXCEPTION 'public.osionos_profiles is missing — osionos-account-profiles-migration.sql must run first';
  END IF;
END
$$;

-- The column. ADD COLUMN IF NOT EXISTS takes ACCESS EXCLUSIVE on every boot,
-- even when the column is already there: the lock_timeout above bounds the
-- wait.
ALTER TABLE public.osionos_profiles ADD COLUMN IF NOT EXISTS profession TEXT;

-- The CHECK, installed by a guarded block: absent -> add; present with the
-- target definition -> nothing; present with another one -> replace.
DO $$
DECLARE
  -- The eight ids, in the order P2-4-c's catalogue lists them.
  v_expr CONSTANT text :=
    'profession IS NULL OR profession IN (''student'',''developer'',''designer'',''data-analyst'',''researcher'',''creator'',''founder'',''teacher'')';
  v_type text;
  v_target text;
  v_live text;
BEGIN
  -- The scratch column carries the live column's type, so the two definitions
  -- render the same way.
  SELECT format_type(a.atttypid, a.atttypmod) INTO v_type
    FROM pg_attribute a
   WHERE a.attrelid = 'public.osionos_profiles'::regclass
     AND a.attname = 'profession' AND a.attnum > 0 AND NOT a.attisdropped;

  EXECUTE format('CREATE TEMP TABLE _osionos_profession_target (profession %s) ON COMMIT DROP', v_type);
  EXECUTE format('ALTER TABLE _osionos_profession_target ADD CONSTRAINT osionos_profession_target_check CHECK (%s)', v_expr);
  SELECT pg_get_constraintdef(oid) INTO v_target
    FROM pg_constraint
   WHERE conrelid = '_osionos_profession_target'::regclass
     AND conname = 'osionos_profession_target_check';

  SELECT pg_get_constraintdef(oid) INTO v_live
    FROM pg_constraint
   WHERE conrelid = 'public.osionos_profiles'::regclass
     AND conname = 'osionos_profiles_profession_check'
     AND contype = 'c';

  IF v_live IS NULL THEN
    EXECUTE format('ALTER TABLE public.osionos_profiles ADD CONSTRAINT osionos_profiles_profession_check CHECK (%s)', v_expr);
  ELSIF v_live IS DISTINCT FROM v_target THEN
    -- A different definition is a different rule (PostgreSQL normalizes an IN
    -- list to = ANY (ARRAY[...]), so a live rule written any other way and
    -- meaning the same thing is replaced once and then converges).
    EXECUTE format('ALTER TABLE public.osionos_profiles DROP CONSTRAINT osionos_profiles_profession_check');
    EXECUTE format('ALTER TABLE public.osionos_profiles ADD CONSTRAINT osionos_profiles_profession_check CHECK (%s)', v_expr);
  END IF;
END
$$;

-- The column grants. They are column grants, so the account role still cannot
-- select=* (PostgREST answers 42501).
-- There is no REVOKE here, and there must not be one: a table-level REVOKE
-- takes the column grants of the same role with it (measured: REVOKE ALL ON
-- t FROM r clears attacl), and P1-1's profiles file — which runs earlier in
-- the same pass — grants the other twenty columns. P1-1's own REVOKE is the
-- one that takes a table-level grant back, and it runs before this file.
GRANT SELECT (profession), UPDATE (profession)
  ON public.osionos_profiles TO osionos_account_user;

COMMIT;

-- PostgREST caches the schema: the new column and its grants are invisible
-- to it until it reloads. The NOTIFY is after the COMMIT, so the column
-- exists before PostgREST reads it.
NOTIFY pgrst, 'reload schema';

-- DOWN (manual). The bridge image is rolled back FIRST: the bridge names the
-- profession column in its profile read, so a bridge that still names it
-- breaks every profile read (PostgREST 400 -> 422/503). Only then:
--   REVOKE SELECT (profession), UPDATE (profession) ON public.osionos_profiles FROM osionos_account_user;
--   ALTER TABLE public.osionos_profiles DROP CONSTRAINT osionos_profiles_profession_check;
--   ALTER TABLE public.osionos_profiles DROP COLUMN profession;
