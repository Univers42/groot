-- Realtime row CDC off: no public table broadcasts its rows on `pg/<table>`.
--
-- Invariant: no public table carries a trigger on public.realtime_notify(), and
-- grobase's realtime_auto_trigger_on_create event trigger is disabled.
--
-- Why: realtime_notify() runs SECURITY DEFINER and sends the full row (and the old row)
-- to every subscriber whose token the gateway accepts, with no grant or RLS check. The
-- gateway grants namespace-less tokens (the app bundle token, the anon key, any session
-- JWT) every namespace, so a public token read every row change of every public table:
-- users, login_otps, sso_connections, function_secrets and roles were measured among
-- them. Nothing in this repo consumes `pg/` topics; the apps' realtime goes through
-- topics the osionos bridge, query-router and outbox-relay publish over HTTP.
--
-- Why every boot: grobase's pg-migrate re-runs 012_realtime_triggers_all_tables.sql on
-- each `up`, which recreates the event trigger ENABLED (012:133-134); a table created
-- after that (schema-service runtime DDL) is armed again until this file runs.
--
-- Where it runs: ORDERED_LAST in scripts/apply-models-migrations.sh, after
-- osionos-service-role-only-migration.sql. Where realtime_notify() or the event trigger
-- does not exist (the desktop edition's embedded Postgres), every step is a no-op.
--
-- Ponytail: matches on the trigger FUNCTION public.realtime_notify() — a trigger that
-- broadcasts through any other function is not dropped. A table whose lock is not
-- granted within 2 s keeps its trigger and raises a WARNING; the runner's final
-- realtime check then fails the run, and the next run retries it.
--
-- Idempotent; it changes no rows.
--
-- DOWN (manual, re-opens the broadcast): ALTER EVENT TRIGGER realtime_auto_trigger_on_create
-- ENABLE; then SELECT public.realtime_ensure_trigger('public', '<table>') per table.

-- Its own statement, before the drops: a table created while they run is not re-armed.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_event_trigger
              WHERE evtname = 'realtime_auto_trigger_on_create' AND evtenabled <> 'D') THEN
    ALTER EVENT TRIGGER realtime_auto_trigger_on_create DISABLE;
  END IF;
END
$$;

-- DROP TRIGGER takes ACCESS EXCLUSIVE: a 2 s lock budget per table keeps a long reader
-- (pg_dump) from queueing logins behind this file; a busy table is left for the next run.
DO $$
DECLARE
  trg record;
BEGIN
  FOR trg IN
    SELECT t.tgname, c.oid::regclass AS rel FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
     WHERE c.relnamespace = 'public'::regnamespace
       AND NOT t.tgisinternal
       AND t.tgfoid = to_regproc('public.realtime_notify')
       -- A partition's clone of its parent's trigger goes with the parent's DROP; listed
       -- here, its own DROP then fails with "does not exist" (ai_chunks, ai_page_vectors).
       AND t.tgparentid = 0
     ORDER BY 2, 1
  LOOP
    BEGIN
      PERFORM set_config('lock_timeout', '2s', true);
      EXECUTE format('DROP TRIGGER %I ON %s', trg.tgname, trg.rel);
    EXCEPTION WHEN lock_not_available THEN
      RAISE WARNING 'realtime-cdc-off: % is busy, its realtime trigger stays until the next run', trg.rel;
    END;
  END LOOP;
END
$$;
