-- osionos_activity_events — the product-analytics log of what people do in osionos,
-- and osionos_activity_daily — the only thing an admin dashboard may read from it.
--
-- WHAT THIS IS
--   osionos_activity_events   one row per action: who (user_id), when (ts), in which
--                             workspace, what (event) and where (surface). Ids, enums
--                             and a timestamp only: no title, no text, no page id.
--                             Partitioned by month, aged out whole-partition.
--   osionos_activity_daily    one row per (day, event, surface): how many events and
--                             how many DISTINCT people. Counts only. It names no user
--                             and no workspace, and a cell is stored only when at
--                             least 5 people are in it (CHECK distinct_users >= 5).
--
-- WHY THE ROLLUP HAS NO WORKSPACE AND NO SMALL CELL
--   A dashboard that can say "workspace X had 1 export on Tuesday" has identified a
--   person. The rollup is therefore platform-wide and refuses a cell under 5 people
--   twice: the HAVING of osionos_activity_rollup() never emits it and the CHECK
--   refuses it if a later edit forgets the HAVING.
--
-- THE ROLLUP IS REBUILT, NEVER PATCHED
--   osionos_activity_rollup(day) deletes that day's cells and recomputes them from
--   the raw partition, so a replay is a no-op and an erasure is honoured by the next
--   rebuild: erase one person, rebuild, and a cell that falls under 5 disappears.
--   Until that rebuild a stored cell still counts the erased person (D3: the erasure
--   does not touch osionos_activity_daily). A cell holds no user id, so it cannot be
--   attributed back; it is a count of people, not a record of one.
--   Caveat: a late event (ts in a day already rolled up) is not counted until that
--   day is rebuilt; nothing rebuilds it by itself.
--
-- PARTITIONS
--   osionos_activity_events_default (always there) and osionos_activity_events_yYYYYMM
--   for the current UTC month and the next two. osionos_activity_maintain() creates
--   the missing months and drops the months older than raw_months (default 13), and
--   prunes the rollup past rollup_months (default 25). The DEFAULT partition is the
--   health signal: it must stay empty, and maintain() drains a month's rows out of it
--   before creating that month, because Postgres refuses to attach a range that
--   overlaps rows already in DEFAULT.
--   Caveat: retention is by whole partition, so a row lives up to one month longer
--   than raw_months. A drop is irreversible. The advisory locks are per database.
--   THE RUNNER THAT CALLS maintain() ONCE A DAY IS NOT IN THIS FILE.
--
-- EVERY CHILD IS CLOSED AT CREATION
--   A partition inherits neither the parent's grants nor its RLS flag. maintain()
--   closes each child it creates (ENABLE RLS, REVOKE from PUBLIC/anon/authenticated,
--   GRANT to service_role only) and this file closes the ones it creates itself.
--
-- THE FILE ORDER
--   Listed in ORDERED_LAST (scripts/apply-models-migrations.sh) directly before
--   osionos-account-erasure-migration.sql, which seeds the registry row for the
--   events table. The plain-glob scripts/apply-models.sh may sort the erasure file
--   first; that is harmless because the registry resolves tables with to_regclass.
--   Owner caveat: the rollup is FORCE RLS and the definer functions run as the
--   table owner, which must be a superuser or BYPASSRLS role (postgres is).
--
-- Idempotent: IF NOT EXISTS / CREATE OR REPLACE / DROP ... IF EXISTS. It never
-- deletes a row of the events table. No feature newer than PG 15.

BEGIN;

CREATE TABLE IF NOT EXISTS public.osionos_activity_events (
  id           BIGINT      GENERATED ALWAYS AS IDENTITY,
  ts           TIMESTAMPTZ NOT NULL DEFAULT now(),
  user_id      UUID        NOT NULL,
  workspace_id UUID,
  event        TEXT        NOT NULL CHECK (event IN ('page_open','page_create','page_edit','search','share','export','login','database_view')),
  surface      TEXT        NOT NULL CHECK (surface IN ('editor','database','canvas','chat','search','settings','admin')),
  PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);

COMMENT ON TABLE public.osionos_activity_events IS
  'Product-analytics log, one row per action. Partitioned by month '
  '(osionos_activity_events_yYYYYMM + _default). Service-role only. No FK on user_id '
  'so the erasure can delete a user without a cascade through a hot table.';

-- The user's own history (erasure, export) and the 200-newest read.
CREATE INDEX IF NOT EXISTS osionos_activity_events_user_ts_idx
  ON public.osionos_activity_events (user_id, ts DESC);

CREATE TABLE IF NOT EXISTS public.osionos_activity_daily (
  day            DATE    NOT NULL,
  event          TEXT    NOT NULL,
  surface        TEXT    NOT NULL,
  events         BIGINT  NOT NULL,
  distinct_users INTEGER NOT NULL CHECK (distinct_users >= 5),
  PRIMARY KEY (day, event, surface)
);

COMMENT ON TABLE public.osionos_activity_daily IS
  'Platform-wide daily counts per (event, surface). Only cells of 5 or more distinct '
  'people are stored. Rebuilt by osionos_activity_rollup(day), never patched. Holds '
  'no user id and no workspace id.';

REVOKE ALL ON public.osionos_activity_events FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.osionos_activity_events TO service_role;
ALTER TABLE public.osionos_activity_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.osionos_activity_daily FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.osionos_activity_daily TO service_role;
ALTER TABLE public.osionos_activity_daily ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_activity_daily FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_activity_daily_service_role_all ON public.osionos_activity_daily;
CREATE POLICY osionos_activity_daily_service_role_all ON public.osionos_activity_daily
  FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP TRIGGER IF EXISTS osionos_activity_events_realtime_trigger ON public.osionos_activity_events;
DROP TRIGGER IF EXISTS osionos_activity_daily_realtime_trigger ON public.osionos_activity_daily;

-- The DEFAULT partition is created through format(): a literal "create table <name>"
-- here would be read by the runner's pending() as a table this file still has to make.
DO $$
BEGIN
  IF to_regclass('public.osionos_activity_events_default') IS NULL THEN
    EXECUTE format('CREATE TABLE %I.%I PARTITION OF public.osionos_activity_events DEFAULT',
                   'public', 'osionos_activity_events_default');
  END IF;
  EXECUTE 'ALTER TABLE public.osionos_activity_events_default ENABLE ROW LEVEL SECURITY';
  EXECUTE 'REVOKE ALL ON public.osionos_activity_events_default FROM PUBLIC, anon, authenticated';
  EXECUTE 'GRANT SELECT, INSERT, DELETE ON public.osionos_activity_events_default TO service_role';
END
$$;

-- -----------------------------------------------------------------------------
-- osionos_activity_maintain — create the coming months, drop the old ones, prune
-- the rollup. One advisory lock (7203001) so two runners never race; it is the
-- first statement. The 2s lock_timeout is a function setting, so a DROP or CREATE
-- that waits behind a long reader gives up instead of queueing every writer
-- behind it, and the setting does not leak to the caller.
-- A failure is reported (ok=false + NOTICE), never swallowed into ok=true.
-- Caveat: the failure path rolls the work of that call back, so the counts it
-- returns are what was attempted, not what stuck.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.osionos_activity_maintain(raw_months integer DEFAULT 13, rollup_months integer DEFAULT 25)
RETURNS TABLE (ok boolean, created integer, dropped integer, rollup_pruned bigint, default_rows bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
SET lock_timeout = '2s'
AS $fn$
DECLARE
  v_created integer := 0;
  v_dropped integer := 0;
  v_pruned  bigint  := 0;
  v_default bigint  := 0;
  v_cur     date    := date_trunc('month', now() AT TIME ZONE 'UTC')::date;
  v_month   date;
  v_name    text;
  v_lo      timestamptz;
  v_hi      timestamptz;
  i         integer;
  r         record;
BEGIN
  IF NOT pg_try_advisory_xact_lock(7203001) THEN
    RAISE NOTICE 'osionos_activity_maintain: another run holds the lock, skipped';
    RETURN QUERY SELECT true, 0, 0, 0::bigint, 0::bigint;
    RETURN;
  END IF;

  IF raw_months < 2 OR rollup_months < raw_months THEN
    RAISE EXCEPTION 'osionos_activity_maintain: raw_months >= 2 and rollup_months >= raw_months required (got %, %)',
      raw_months, rollup_months;
  END IF;

  IF to_regclass('public.osionos_activity_events_default') IS NULL THEN
    EXECUTE format('CREATE TABLE %I.%I PARTITION OF public.osionos_activity_events DEFAULT',
                   'public', 'osionos_activity_events_default');
    EXECUTE 'ALTER TABLE public.osionos_activity_events_default ENABLE ROW LEVEL SECURITY';
    EXECUTE 'REVOKE ALL ON public.osionos_activity_events_default FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT SELECT, INSERT, DELETE ON public.osionos_activity_events_default TO service_role';
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS osionos_activity_drain
    (id bigint, ts timestamptz, user_id uuid, workspace_id uuid, event text, surface text) ON COMMIT DROP;
  TRUNCATE osionos_activity_drain;

  FOR i IN 0..2 LOOP
    v_month := (v_cur + (i * INTERVAL '1 month'))::date;
    v_name  := 'osionos_activity_events_y' || to_char(v_month, 'YYYYMM');
    IF to_regclass('public.' || v_name) IS NULL THEN
      v_lo := v_month::timestamp AT TIME ZONE 'UTC';
      v_hi := (v_month + INTERVAL '1 month')::timestamp AT TIME ZONE 'UTC';
      -- Rows of this month already in DEFAULT block the new range: move them out,
      -- create and close the child, put them back (they now route to the child).
      WITH moved AS (
        DELETE FROM public.osionos_activity_events_default WHERE ts >= v_lo AND ts < v_hi RETURNING *
      )
      INSERT INTO osionos_activity_drain SELECT id, ts, user_id, workspace_id, event, surface FROM moved;
      EXECUTE format('CREATE TABLE %I.%I PARTITION OF public.osionos_activity_events FOR VALUES FROM (%L) TO (%L)',
                     'public', v_name, v_lo, v_hi);
      EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', v_name);
      EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', v_name);
      EXECUTE format('GRANT SELECT, INSERT, DELETE ON public.%I TO service_role', v_name);
      INSERT INTO public.osionos_activity_events (id, ts, user_id, workspace_id, event, surface)
        OVERRIDING SYSTEM VALUE
        SELECT id, ts, user_id, workspace_id, event, surface FROM osionos_activity_drain;
      TRUNCATE osionos_activity_drain;
      v_created := v_created + 1;
    END IF;
  END LOOP;

  FOR r IN
    SELECT c.relname
      FROM pg_inherits h
      JOIN pg_class c ON c.oid = h.inhrelid
     WHERE h.inhparent = 'public.osionos_activity_events'::regclass
       AND c.relname ~ '^osionos_activity_events_y[0-9]{6}$'
     ORDER BY c.relname
  LOOP
    v_month := (to_date(right(r.relname, 6), 'YYYYMM') + INTERVAL '1 month')::date;
    IF v_month <= (v_cur - (raw_months * INTERVAL '1 month'))::date THEN
      EXECUTE format('DROP TABLE IF EXISTS public.%I', r.relname);
      v_dropped := v_dropped + 1;
    END IF;
  END LOOP;

  DELETE FROM public.osionos_activity_daily
   WHERE day < (v_cur - (rollup_months * INTERVAL '1 month'))::date;
  GET DIAGNOSTICS v_pruned = ROW_COUNT;

  SELECT count(*) INTO v_default
    FROM (SELECT 1 FROM public.osionos_activity_events_default LIMIT 1000) s;

  RETURN QUERY SELECT true, v_created, v_dropped, v_pruned, v_default;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'osionos_activity_maintain failed: %', SQLERRM;
  RETURN QUERY SELECT false, v_created, v_dropped, v_pruned, v_default;
END
$fn$;

COMMENT ON FUNCTION public.osionos_activity_maintain(integer, integer) IS
  'Creates the current UTC month + 2 partitions (draining DEFAULT first), closes each '
  'child, drops months older than raw_months (13), prunes the rollup past rollup_months '
  '(25). Returns (ok, created, dropped, rollup_pruned, default_rows<=1000). Advisory '
  'lock 7203001; a second concurrent run returns ok=true with zero counts.';

-- -----------------------------------------------------------------------------
-- osionos_activity_rollup — rebuild one CLOSED UTC day of osionos_activity_daily.
-- Advisory lock 7203002. Statuses: ok, partition_gone (maintain already dropped
-- that month: nothing is touched, so a stored day is never zeroed), too_old (inside
-- the last month before the drop), busy (another rebuild is running).
-- Caveat: the 13 in the too_old test mirrors maintain()'s default raw_months; a
-- caller that shortens raw_months must not expect a rebuild of the last month.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.osionos_activity_rollup(for_day date)
RETURNS TABLE (status text, cells integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_today date := (now() AT TIME ZONE 'UTC')::date;
  v_cur   date := date_trunc('month', now() AT TIME ZONE 'UTC')::date;
  v_lo    timestamptz;
  v_hi    timestamptz;
  v_n     integer;
BEGIN
  IF for_day IS NULL OR for_day >= v_today THEN
    RAISE EXCEPTION 'day_not_closed' USING ERRCODE = '22023';
  END IF;
  IF for_day < (v_cur - INTERVAL '12 months')::date THEN
    RETURN QUERY SELECT 'too_old'::text, 0;
    RETURN;
  END IF;
  IF to_regclass('public.osionos_activity_events_y' || to_char(for_day, 'YYYYMM')) IS NULL THEN
    RETURN QUERY SELECT 'partition_gone'::text, 0;
    RETURN;
  END IF;
  IF NOT pg_try_advisory_xact_lock(7203002) THEN
    RETURN QUERY SELECT 'busy'::text, 0;
    RETURN;
  END IF;

  v_lo := for_day::timestamp AT TIME ZONE 'UTC';
  v_hi := (for_day + 1)::timestamp AT TIME ZONE 'UTC';

  DELETE FROM public.osionos_activity_daily WHERE day = for_day;
  -- HAVING mirrors the table CHECK (distinct_users >= 5): a cell under 5 people is
  -- never written, so a small cell cannot be read back.
  INSERT INTO public.osionos_activity_daily (day, event, surface, events, distinct_users)
  SELECT for_day, e.event, e.surface, count(*), count(DISTINCT e.user_id)
    FROM public.osionos_activity_events e
   WHERE e.ts >= v_lo AND e.ts < v_hi
   GROUP BY e.event, e.surface
  HAVING count(DISTINCT e.user_id) >= 5;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN QUERY SELECT 'ok'::text, v_n;
END
$fn$;

COMMENT ON FUNCTION public.osionos_activity_rollup(date) IS
  'Rebuilds one closed UTC day of osionos_activity_daily from the raw partition: delete '
  'then insert, cells of 5+ distinct users only. Refuses today or later (day_not_closed). '
  'Returns (status, cells).';

REVOKE ALL ON FUNCTION public.osionos_activity_maintain(integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.osionos_activity_maintain(integer, integer) TO service_role;
REVOKE ALL ON FUNCTION public.osionos_activity_rollup(date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.osionos_activity_rollup(date) TO service_role;

-- The current month + 2 now, so the table accepts a row the moment the file lands.
DO $$
BEGIN
  IF NOT (SELECT m.ok FROM public.osionos_activity_maintain() m) THEN
    RAISE EXCEPTION 'osionos-activity-analytics: initial partitions were not created';
  END IF;
END
$$;

COMMIT;

NOTIFY pgrst, 'reload schema';
