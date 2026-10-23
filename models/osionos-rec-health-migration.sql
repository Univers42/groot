-- ai_rec_health — the numbers of the "Recs health" admin chart (M3): the offline
-- quality of every trained model over time, and the daily click-through of the
-- served recommendations. It is the proof that the recommender "improves over
-- time", so it reads only what was measured: the registry's metrics and the
-- beacon's impression and click events.
--
-- Aggregates only: no user id, no item id leaves the function. Synthetic and
-- real events are counted apart, so a chart never mixes a simulation with use.
-- A click counts only with a rec_id: a click on an item that was not served by
-- the recommender is not its click-through.
--
-- Caveat: the CTR is clicks / impressions per day as logged; a client that drops
-- impressions (an ad blocker on the beacon, a tab closed before the flush) makes
-- it read high, and a day with few impressions is noise — the chart shows the
-- counts beside the rate.
--
-- Idempotent: CREATE OR REPLACE; needs osionos-user-events-migration.sql and
-- osionos-rec-factors-migration.sql first.

CREATE OR REPLACE FUNCTION public.ai_rec_health(p_days INTEGER DEFAULT 30)
RETURNS JSONB
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
    WITH bounds AS (
        SELECT now() - make_interval(days => LEAST(GREATEST(COALESCE(p_days, 30), 1), 180)) AS since
    ),
    daily AS (
        SELECT (e.ts AT TIME ZONE 'UTC')::date AS day,
               e.is_synthetic,
               count(*) FILTER (WHERE e.event = 'impression') AS impressions,
               count(*) FILTER (WHERE e.event = 'click' AND e.rec_id IS NOT NULL) AS clicks
          FROM public.ai_events e, bounds b
         WHERE e.ts >= b.since
           AND e.event IN ('impression', 'click')
         GROUP BY 1, 2
    )
    SELECT jsonb_build_object(
        'since', (SELECT since FROM bounds),
        'models', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', m.id,
                       'createdAt', m.created_at,
                       'status', m.status,
                       'isSynthetic', m.is_synthetic,
                       'eventsUsed', m.events_used,
                       'ndcg10', m.metrics -> 'ndcg10',
                       'recall20', m.metrics -> 'recall20')
                   ORDER BY m.created_at)
              FROM public.ai_rec_models m, bounds b
             WHERE m.created_at >= b.since), '[]'::jsonb),
        'daily', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'day', d.day,
                       'isSynthetic', d.is_synthetic,
                       'impressions', d.impressions,
                       'clicks', d.clicks)
                   ORDER BY d.day, d.is_synthetic)
              FROM daily d), '[]'::jsonb)
    );
$$;

COMMENT ON FUNCTION public.ai_rec_health(INTEGER) IS
    'Recs health (M3): the registry''s models with ndcg10/recall20 and the '
    'daily impressions/clicks (clicks with a rec_id), real and synthetic apart, '
    'over the last p_days (clamped 1..180). Aggregates only. service_role only.';

GRANT EXECUTE ON FUNCTION public.ai_rec_health(INTEGER) TO service_role;
REVOKE ALL ON FUNCTION public.ai_rec_health(INTEGER) FROM PUBLIC, ANON, AUTHENTICATED;

NOTIFY pgrst, 'reload schema';
