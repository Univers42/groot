-- osionos-publish-account-migration.sql — the account role reads its OWN
-- published pages.
--
-- WHY THIS FILE EXISTS
--   Publishing a page writes a snapshot into public.osionos_published_pages
--   (models/osionos-publish-migration.sql), and that file grants the table to
--   service_role only. The account plane could not read it at all: a per-user
--   read of "the pages I published to the web" was impossible, so the app had
--   no way to list them.
--
-- WHO REACHES WHAT
--   service_role          everything (the bridge: the public GET reads the
--                         snapshot as service_role).
--   osionos_account_user  five columns of its OWN rows: token, page_id, title,
--                         icon, published_at.
--   anon, authenticated   nothing.
--
-- WHY THE GRANTS ARE COLUMN GRANTS
--   A table grant would hand the role the snapshot body (content) and the
--   owner of every row. The body is not the account plane's business: the
--   public copy is served by the bridge, from the service role.
--   The REVOKE comes first: a table-level grant left over from an earlier run
--   (or from a hand-made grant) survives a replay, and only this line takes it
--   back.
--
-- WHY THE FILTER IS THE DATABASE'S JOB
--   The read is the caller's own, and the filter is the row filter, not a
--   WHERE clause the route may forget. The helper is wrapped on purpose: it
--   is evaluated once per query, not once per row.
--
-- WHERE IT RUNS
--   scripts/apply-models-migrations.sh lists it in ORDERED_LAST, right after
--   osionos-account-profiles-migration.sql: it needs the role and
--   public.osionos_account_uid() (models/osionos-account-foundation-migration.sql),
--   and the alphabetical pass would reach it before either exists.
--
-- Idempotent: a second run moves no grant, policy or comment (check g of
-- scripts/verify/models-grants.sh).

BEGIN;

REVOKE ALL ON public.osionos_published_pages FROM osionos_account_user;

GRANT SELECT (token, page_id, title, icon, published_at)
  ON public.osionos_published_pages TO osionos_account_user;

DROP POLICY IF EXISTS osionos_published_pages_owner_read ON public.osionos_published_pages;
CREATE POLICY osionos_published_pages_owner_read ON public.osionos_published_pages
  FOR SELECT TO osionos_account_user
  USING (owner_id = (SELECT public.osionos_account_uid()));

-- The marker every account-plane table carries. Without it the account role
-- reaches a relation anon does not, and check k1 fails.
COMMENT ON TABLE public.osionos_published_pages IS 'osionos:account-plane';

COMMIT;

-- PostgREST caches the schema: the grants and the policy are invisible to it
-- until it reloads. The NOTIFY is after the COMMIT, so the policy exists
-- before PostgREST reads it.
NOTIFY pgrst, 'reload schema';
