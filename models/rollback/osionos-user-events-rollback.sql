-- The rollback of models/osionos-user-events-migration.sql (the ai_events log
-- and its capture triggers).
--
-- THE RUNNER NEVER PICKS THIS FILE UP
--   The runner's glob is "${MODELS_DIR}"/*.sql
--   (scripts/apply-models-migrations.sh:254 in --check, :289 in apply), and this
--   file lives in the models/rollback/ subdirectory, which that glob does not
--   reach. The ledger runner scripts/apply-models.sh globs the same way. A
--   rollback is run by hand, or by the service slice that owns the slice.
--
-- ORDER
--   The triggers first (a trigger on a dropped table would fail), then the
--   trigger functions, then the functions, then the tables. Dropping the
--   partitioned parent drops its partitions with it.
--
-- Idempotent: every statement is IF EXISTS shaped, so it can be applied twice.
--
-- WHAT A ROLLBACK COSTS
--   The log itself: every ai_events row of every user is dropped with the
--   table. The opt-out (ai_personalization_settings) goes with it. A rollback is
--   a demolition, not a migration: the recommender has nothing to read until
--   the migration is applied again.

-- The capture triggers, on the tables they observe.
DROP TRIGGER IF EXISTS ai_events_capture_feed_likes ON public.osionos_feed_likes;
DROP TRIGGER IF EXISTS ai_events_capture_feed_reactions ON public.osionos_feed_reactions;
DROP TRIGGER IF EXISTS ai_events_capture_feed_shares ON public.osionos_feed_shares;
DROP TRIGGER IF EXISTS ai_events_capture_feed_comments ON public.osionos_feed_comments;
DROP TRIGGER IF EXISTS ai_events_capture_page_comments ON public.osionos_page_comments;
DROP TRIGGER IF EXISTS ai_events_capture_page_favorites ON public.osionos_page_favorites;
DROP TRIGGER IF EXISTS ai_events_capture_connections ON public.osionos_connections;

-- The capture functions.
DROP FUNCTION IF EXISTS public.ai_events_capture_feed_likes();
DROP FUNCTION IF EXISTS public.ai_events_capture_feed_reactions();
DROP FUNCTION IF EXISTS public.ai_events_capture_feed_shares();
DROP FUNCTION IF EXISTS public.ai_events_capture_feed_comments();
DROP FUNCTION IF EXISTS public.ai_events_capture_page_comments();
DROP FUNCTION IF EXISTS public.ai_events_capture_page_favorites();
DROP FUNCTION IF EXISTS public.ai_events_capture_connections();

-- The service functions.
DROP FUNCTION IF EXISTS public.ai_erase_user(UUID);
DROP FUNCTION IF EXISTS public.ai_export_user(UUID);
DROP FUNCTION IF EXISTS public.ai_events_default_rows();
DROP FUNCTION IF EXISTS public.ai_events_maintain(interval);

-- The tables. Dropping the partitioned parent drops ai_events_default and every
-- ai_events_yYYYYMM with it.
DROP TABLE IF EXISTS public.ai_events;
DROP TABLE IF EXISTS public.ai_personalization_settings;
