-- The checks of ai_events_beacon (models/osionos-rec-beacon-migration.sql), run by
-- scripts/verify/rec-beacon.sh. Each prints "ok: <label>" or raises "FAIL: <label>".
CREATE OR REPLACE FUNCTION pg_temp.ok(cond boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF cond IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', label; END IF; RAISE NOTICE 'ok: %', label; END $$;
-- users: A consented, B consented, C explicit false, D no row
INSERT INTO public.ai_personalization_settings (user_id, beacon_consent) VALUES
 ('00000000-0000-4000-8000-00000000000a', true),
 ('00000000-0000-4000-8000-00000000000b', true),
 ('00000000-0000-4000-8000-00000000000c', false);
SELECT pg_temp.ok(public.ai_events_beacon('00000000-0000-4000-8000-00000000000c',
  '[{"item_id":"00000000-0000-4000-8000-0000000000f1","event":"click","surface":"home","rec_id":"00000000-0000-4000-8000-0000000000e1","rank":1}]') = 0, 'explicit false consent writes 0');
SELECT pg_temp.ok(public.ai_events_beacon('00000000-0000-4000-8000-00000000000d',
  '[{"item_id":"00000000-0000-4000-8000-0000000000f1","event":"click","surface":"home","rec_id":"00000000-0000-4000-8000-0000000000e1","rank":1}]') = 0, 'no row writes 0');
DO $$ BEGIN FOR i IN 1..200 LOOP
  PERFORM public.ai_events_beacon('00000000-0000-4000-8000-00000000000a',
   '[{"item_id":"00000000-0000-4000-8000-0000000000f1","event":"click","surface":"home","rec_id":"00000000-0000-4000-8000-0000000000e1","rank":1}]');
END LOOP; END $$;
SELECT pg_temp.ok((SELECT count(*) FROM public.ai_events WHERE item_id='00000000-0000-4000-8000-0000000000f1' AND event='click') = 1, '200 clicks of one user = 1 row (C50)');
SELECT public.ai_events_beacon('00000000-0000-4000-8000-00000000000b',
  '[{"item_id":"00000000-0000-4000-8000-0000000000f1","event":"click","surface":"home","rec_id":"00000000-0000-4000-8000-0000000000e1","rank":1}]');
SELECT pg_temp.ok((SELECT count(DISTINCT user_id) FROM public.ai_events WHERE item_id='00000000-0000-4000-8000-0000000000f1' AND event='click') = 2, 'two users = 2');
SELECT pg_temp.ok((SELECT count(*) FROM public.ai_events WHERE user_id IN ('00000000-0000-4000-8000-00000000000c','00000000-0000-4000-8000-00000000000d')) = 0, 'no rows for C or D');
SELECT pg_temp.ok((SELECT bool_and(ts = date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC') FROM public.ai_events WHERE surface <> 'trigger'), 'ts is the UTC day start');
SELECT pg_temp.ok(public.ai_events_beacon('00000000-0000-4000-8000-00000000000a',
  '[{"item_id":"00000000-0000-4000-8000-0000000000f2","event":"click","surface":"home"}]') = 0, 'a click without rec_id is nothing');
DO $$ BEGIN
  PERFORM public.ai_events_beacon('00000000-0000-4000-8000-00000000000a', (SELECT jsonb_agg(jsonb_build_object('item_id', gen_random_uuid(), 'event','view','surface','home')) FROM generate_series(1,51)));
  RAISE EXCEPTION 'FAIL: 51 events accepted';
EXCEPTION WHEN sqlstate '22023' THEN RAISE NOTICE 'ok: 51 events -> 22023'; END $$;
DO $$ BEGIN FOR i IN 1..39 LOOP
  PERFORM public.ai_events_beacon('00000000-0000-4000-8000-00000000000b', (SELECT jsonb_agg(jsonb_build_object('item_id', gen_random_uuid(), 'event','view','surface','home')) FROM generate_series(1,50)));
END LOOP; END $$;
DO $$ BEGIN
  PERFORM public.ai_events_beacon('00000000-0000-4000-8000-00000000000b', (SELECT jsonb_agg(jsonb_build_object('item_id', gen_random_uuid(), 'event','view','surface','home')) FROM generate_series(1,50)));
  RAISE EXCEPTION 'FAIL: cap not reached';
EXCEPTION WHEN sqlstate '54000' THEN RAISE NOTICE 'ok: daily cap -> 54000'; END $$;
SELECT pg_temp.ok(NOT has_function_privilege('authenticated', 'public.ai_events_beacon(uuid,jsonb)', 'EXECUTE'), 'authenticated cannot execute');
