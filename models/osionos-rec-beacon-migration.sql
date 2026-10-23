-- The beacon of the recommender (M3): impressions, clicks and views the client
-- reports, written by ai_events_beacon() and by nothing else. Devil C48–C50
-- (records: a2-events-voice-verdict.md).
--
-- The bridge vouches for every event before it calls this (C49): the session's
-- user, the page readable by them, the rec_id and rank taken from the signed
-- slate the bridge itself issued. This function re-checks what the database
-- alone can know:
--   - the consent (C48): beacon_consent must be TRUE for the user, and no row
--     means FALSE — nothing is written for a user who never said yes;
--   - the bucket (C49, C50): a beacon row's ts is the start of its UTC day,
--     and a partial UNIQUE index over (user, item_kind, item_id, event,
--     surface, ts) keeps one row per user, item, event, surface and day — a
--     thousand clicks of one account are one row. A repeated view keeps its
--     longest dwell;
--   - the daily cap: at most 2000 beacon rows per user per UTC day.
--
-- C50 binds the READERS too: one user still writes one row per SURFACE, so a
-- trending count, a popularity or a posterior counts DISTINCT user_id per item
-- per day, never rows.
--
-- Caveat: the day bucket is coarse — two real views of a page on one day count
-- once, and the time-split evaluation sees beacon events at day resolution only.
--
-- Idempotent: IF NOT EXISTS / OR REPLACE. Needs osionos-user-events-migration.sql.

-- -----------------------------------------------------------------------------
-- 1. One row per (user, item, event, surface, day) for the beacon's surfaces.
--    The partition key (ts) is in the index, as Postgres requires; the beacon
--    writes ts = the start of the UTC day, so the key IS the bucket. Trigger
--    rows (surface 'trigger') keep their exact time and are not deduplicated.
-- -----------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS ai_events_beacon_bucket_idx
    ON public.ai_events (user_id, item_kind, item_id, event, surface, ts)
    WHERE surface <> 'trigger';

-- -----------------------------------------------------------------------------
-- 2. The write. p_events is a JSON array of
--      { item_id, workspace_id, event, surface, rec_id?, rank?, dwell_ms? }
--    already vouched for by the bridge. Returns the number of rows the call
--    inserted or updated; 0 when the user has not consented.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_events_beacon(p_user UUID, p_events JSONB)
RETURNS INTEGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_consent BOOLEAN;
    v_today   INTEGER;
    v_written INTEGER;
BEGIN
    IF p_user IS NULL OR jsonb_typeof(p_events) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'ai_events_beacon: a user and an array of events are required' USING ERRCODE = '22023';
    END IF;
    IF jsonb_array_length(p_events) > 50 THEN
        RAISE EXCEPTION 'ai_events_beacon: at most 50 events per call' USING ERRCODE = '22023';
    END IF;

    SELECT s.beacon_consent INTO v_consent
      FROM public.ai_personalization_settings s
     WHERE s.user_id = p_user;
    IF v_consent IS NOT TRUE THEN
        RETURN 0;
    END IF;

    SELECT count(*) INTO v_today
      FROM public.ai_events e
     WHERE e.user_id = p_user
       AND e.surface <> 'trigger'
       AND e.ts >= date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
    IF v_today + jsonb_array_length(p_events) > 2000 THEN
        RAISE EXCEPTION 'ai_events_beacon: the daily cap is reached' USING ERRCODE = '54000';
    END IF;

    WITH incoming AS (
        SELECT (x ->> 'item_id')::uuid      AS item_id,
               (x ->> 'workspace_id')::uuid AS workspace_id,
               x ->> 'event'                AS event,
               x ->> 'surface'              AS surface,
               (x ->> 'rec_id')::uuid       AS rec_id,
               (x ->> 'rank')::smallint     AS rank,
               LEAST(GREATEST((x ->> 'dwell_ms')::integer, 0), 1800000) AS dwell_ms
          FROM jsonb_array_elements(p_events) AS x
    ), checked AS (
        SELECT DISTINCT ON (item_id, event, surface) *
          FROM incoming
         WHERE item_id IS NOT NULL
           AND event IN ('view', 'impression', 'click')
           AND surface IN ('feed', 'home', 'search', 'page')
           -- An impression or a click is a recommendation's, or it is nothing.
           AND (event = 'view' OR (rec_id IS NOT NULL AND rank BETWEEN 1 AND 100))
         ORDER BY item_id, event, surface, dwell_ms DESC NULLS LAST
    )
    INSERT INTO public.ai_events AS e
           (ts, user_id, item_kind, item_id, workspace_id, event, weight, surface, rec_id, rank, dwell_ms)
    SELECT date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC', p_user, 'page', c.item_id, c.workspace_id, c.event,
           CASE c.event WHEN 'click' THEN 1 WHEN 'view' THEN 1 ELSE 0 END,
           c.surface, c.rec_id, c.rank, CASE WHEN c.event = 'view' THEN c.dwell_ms END
      FROM checked c
    ON CONFLICT (user_id, item_kind, item_id, event, surface, ts) WHERE surface <> 'trigger'
    DO UPDATE SET dwell_ms = GREATEST(e.dwell_ms, EXCLUDED.dwell_ms)
     WHERE EXCLUDED.dwell_ms > COALESCE(e.dwell_ms, -1);

    GET DIAGNOSTICS v_written = ROW_COUNT;
    RETURN v_written;
END;
$$;

COMMENT ON FUNCTION public.ai_events_beacon(UUID, JSONB) IS
    'The beacon write (M3, C48–C50): nothing without beacon_consent = TRUE; '
    'one row per (user, page, event, surface, UTC day); impressions and clicks '
    'need a rec_id and a rank; at most 50 events per call and 2000 per user per '
    'UTC day (54000). The bridge vouches for the user, the page and the slate. '
    'service_role only.';

GRANT EXECUTE ON FUNCTION public.ai_events_beacon(UUID, JSONB) TO service_role;
REVOKE ALL ON FUNCTION public.ai_events_beacon(UUID, JSONB) FROM PUBLIC, ANON, AUTHENTICATED;

NOTIFY pgrst, 'reload schema';
