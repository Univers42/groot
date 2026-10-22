-- Rollback of the AI migrations' triggers on non-ai tables (generated, do not edit).
-- Source files:
--   models/osionos-ai-access-tokens-migration.sql
--   models/osionos-ai-graph-migration.sql
--   models/osionos-ai-jobs-migration.sql
--   models/osionos-ai-migration.sql
--   models/osionos-ai-rag-migration.sql
--   models/osionos-membership-cutoff-migration.sql
--   models/osionos-page-version-migration.sql
--   models/osionos-rec-beacon-migration.sql
--   models/osionos-rec-factors-migration.sql
--   models/osionos-rec-health-migration.sql
--   models/osionos-rec-serving-migration.sql
--   models/osionos-ugc-moderation-migration.sql
--   models/osionos-user-events-migration.sql
BEGIN;
SET lock_timeout = '5s';
DROP TRIGGER IF EXISTS ai_enqueue_page_ins ON public.osionos_pages;
DROP TRIGGER IF EXISTS ai_enqueue_page_upd ON public.osionos_pages;
DROP TRIGGER IF EXISTS ai_sync_page_acl_trg ON public.osionos_pages;
DROP TRIGGER IF EXISTS ai_delete_page_chunks_trg ON public.osionos_pages;
DROP TRIGGER IF EXISTS osionos_membership_cutoff_update ON public.osionos_workspace_members;
DROP TRIGGER IF EXISTS osionos_membership_cutoff_delete ON public.osionos_workspace_members;
DROP TRIGGER IF EXISTS osionos_pages_version_trg ON public.osionos_pages;
DROP TRIGGER IF EXISTS ai_jobs_enqueue_feed_comments_insert ON public.osionos_feed_comments;
DROP TRIGGER IF EXISTS ai_jobs_enqueue_feed_comments_update ON public.osionos_feed_comments;
DROP TRIGGER IF EXISTS ai_jobs_enqueue_page_comments_insert ON public.osionos_page_comments;
DROP TRIGGER IF EXISTS ai_jobs_enqueue_page_comments_update ON public.osionos_page_comments;
DROP TRIGGER IF EXISTS ai_events_capture_feed_likes ON public.osionos_feed_likes;
DROP TRIGGER IF EXISTS ai_events_capture_feed_reactions ON public.osionos_feed_reactions;
DROP TRIGGER IF EXISTS ai_events_capture_feed_shares ON public.osionos_feed_shares;
DROP TRIGGER IF EXISTS ai_events_capture_feed_comments ON public.osionos_feed_comments;
DROP TRIGGER IF EXISTS ai_events_capture_page_comments ON public.osionos_page_comments;
DROP TRIGGER IF EXISTS ai_events_capture_page_favorites ON public.osionos_page_favorites;
DROP TRIGGER IF EXISTS ai_events_capture_connections ON public.osionos_connections;
COMMIT;
-- DO blocks that run dynamic SQL (a trigger created there is NOT covered above):
--   (none above = no dynamic CREATE TRIGGER found)
