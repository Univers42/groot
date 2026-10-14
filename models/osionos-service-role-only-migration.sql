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
-- What it closes: /rest/v1 and /graphql/v1 for osionos_*, and the realtime row
-- broadcasts (`pg/osionos_*` topics): grobase's realtime_notify() triggers run SECURITY
-- DEFINER and send the full row to any subscriber whose token the gateway accepts, with
-- no grant or RLS check — so a REVOKE alone leaves every row change readable. grobase
-- re-adds such a trigger on every CREATE TABLE (realtime_auto_trigger_on_create); this
-- file runs last and drops them again. No osionos client subscribes to `pg/` topics:
-- the app's realtime goes through topics the bridge publishes.
-- What it does NOT close: bridge-published realtime topics, storage, and /query/v1.
--
-- Ponytail: name-pattern based — a relation the bridge serves without the osionos_
-- prefix is not covered; a new table needs the prefix or its own REVOKE. The trigger
-- pass matches on the trigger FUNCTION public.realtime_notify(): a trigger that
-- broadcasts through any other function is not dropped.
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

-- Its own block: a lock timeout here must not roll back the REVOKE above. Where
-- realtime_notify() does not exist (the desktop edition's embedded Postgres),
-- to_regproc() is NULL and nothing matches.
DO $$
DECLARE
  trg record;
BEGIN
  FOR trg IN
    SELECT t.tgname, c.oid::regclass AS rel FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
     WHERE c.relnamespace = 'public'::regnamespace
       AND c.relname LIKE 'osionos\_%'
       AND NOT t.tgisinternal
       AND t.tgfoid = to_regproc('public.realtime_notify')
     ORDER BY 2, 1
  LOOP
    EXECUTE format('DROP TRIGGER %I ON %s', trg.tgname, trg.rel);
  END LOOP;
END
$$;
