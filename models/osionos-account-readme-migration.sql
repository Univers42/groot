-- osionos-account-readme-migration.sql — the README page pointer on the
-- account profile (P2-1-a).
--
-- WHY THIS FILE EXISTS
--   Every user can have one README page, created lazily on their first
--   "Customize" and bound to the profile. The binding is one column written
--   through the same PATCH and the same If-Match as every other profile field,
--   so there is no second write path. The column is added HERE and not in
--   P1-1's profiles file: that file is the account plane's baseline, and one
--   file per feature keeps the migration history readable.
--
-- WHAT IT CREATES
--   public.osionos_profiles.readme_page_id   UUID, NULL, FK to osionos_pages(id)
--
-- WHO REACHES WHAT
--   osionos_account_user  SELECT (readme_page_id) and UPDATE (readme_page_id):
--                         the user reads and writes their own pointer only.
--   service_role          everything (it owns the tables anyway), so the
--                         bridge's public README projection can read it.
--   anon, authenticated   nothing.
--
-- WHY ON DELETE SET NULL
--   Deleting the README page must leave the profile intact and make the next
--   "Customize" create a fresh page; CASCADE would delete the profile row.
--
-- WHY THE POINTER IS NOT A CAPABILITY
--   The column holds an id, not access: whose page it is and whether it is
--   archived is checked by the bridge when it projects the README
--   (owner_id = the profile's user), because a user could write any page id
--   into their own column.
--   Caveat: nothing in the database stops a user pointing at a page they do
--   not own; the bridge projection is the only guard.
--
-- WHY THE COLUMN INHERITS THE ROW POLICIES
--   osionos_profiles_owner_read and osionos_profiles_owner_update (P1-1)
--   already limit the row to the caller, and a column inherits them.
--
-- WHY THERE IS NO REALTIME TRIGGER
--   The account-plane tables had their realtime triggers dropped on purpose
--   (P1-1): the broadcast carries the whole row past every grant.
--
-- WHERE IT RUNS
--   scripts/apply-models-migrations.sh lists it in ORDERED_LAST right after
--   osionos-account-profession-migration.sql: the column and its grants must
--   exist before any bridge image that names the column, and osionos_pages
--   (ORDERED_FIRST) exists by then.
--
-- Idempotent: a second run moves no grant and no column.

BEGIN;

-- Caveat: a busy table makes this file fail (the whole transaction rolls
-- back) instead of waiting; the next run retries it. 5 s is a budget, not a
-- promise.
SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                  WHERE table_schema = 'public' AND table_name = 'osionos_profiles') THEN
    RAISE EXCEPTION 'public.osionos_profiles is missing — osionos-account-profiles-migration.sql must run first';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                  WHERE table_schema = 'public' AND table_name = 'osionos_pages') THEN
    RAISE EXCEPTION 'public.osionos_pages is missing — osionos-bridge-migration.sql must run first';
  END IF;
END
$$;

-- ADD COLUMN IF NOT EXISTS takes ACCESS EXCLUSIVE on every boot, even when
-- the column is already there: the lock_timeout above bounds the wait.
ALTER TABLE public.osionos_profiles
  ADD COLUMN IF NOT EXISTS readme_page_id UUID REFERENCES public.osionos_pages(id) ON DELETE SET NULL;

-- Column grants only, so the account role still cannot select=*. There is no
-- REVOKE here: a table-level REVOKE takes the column grants of the same role
-- with it (see osionos-account-profession-migration.sql).
GRANT SELECT (readme_page_id), UPDATE (readme_page_id)
  ON public.osionos_profiles TO osionos_account_user;

COMMIT;

-- PostgREST caches the schema; the NOTIFY is after the COMMIT so the column
-- exists before PostgREST reads it.
NOTIFY pgrst, 'reload schema';

-- DOWN (manual). Roll the bridge image back FIRST: the bridge names
-- readme_page_id in its profile read, so a bridge that still names it breaks
-- every profile read. Only then:
--   REVOKE SELECT (readme_page_id), UPDATE (readme_page_id) ON public.osionos_profiles FROM osionos_account_user;
--   ALTER TABLE public.osionos_profiles DROP COLUMN readme_page_id;
