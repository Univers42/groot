-- Service-role-only catalog pass for osionos_* relations.
--
-- Invariant: every public.osionos_* relation is reachable only by service_role.
-- The bridge (service_role) is the only reader and writer. anon and
-- authenticated get no privilege on any of them.
--
-- Why a catalog pass and not per-file grants:
--   * Databases first booted before grobase commit 1e407614 received a default
--     privilege: it gave anon and authenticated SELECT, INSERT, UPDATE and DELETE
--     on every new public table.
--   * Earlier models files also granted per table.
--   * Views owned by postgres run with their owner's rights, so a grant on a view
--     bypasses RLS.
--   * A per-file REVOKE cannot see the tables some other file created.
--   * Revoking at table level also removes column-level grants.
--
-- Where it runs:
--   * last, by explicit list (ORDERED_LAST in scripts/apply-models-migrations.sh);
--   * on every desktop launch (apps/osionos-electron/native/firstrun.mjs).
--
-- What it closes: /rest/v1 and /graphql/v1 for osionos_*. A REVOKE alone does not
-- close the realtime row broadcasts (`pg/<table>`): realtime-cdc-off-migration.sql,
-- which runs after this file, drops those for every public table.
-- What it does NOT close: bridge-published realtime topics, storage, and /query/v1.
--
-- Ponytail: name-pattern based — a relation the bridge serves without the osionos_
-- prefix is not covered; a new table needs the prefix or its own REVOKE.
--
-- Idempotent; it changes no rows; revoking does not undo writes made before it ran.
--
-- DOWN (manual, re-opens REST access): GRANT <privileges> ON public.<relation> TO authenticated;
DO $$
DECLARE
  rel regclass;
BEGIN
  FOR rel IN
    SELECT c.oid::regclass FROM pg_class c
     WHERE c.relnamespace = 'public'::regnamespace
       AND c.relname LIKE 'osionos\_%'
       AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
     ORDER BY c.relname
  LOOP
    EXECUTE format('REVOKE ALL ON %s FROM PUBLIC, anon, authenticated', rel);
  END LOOP;
END
$$;
