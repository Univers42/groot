-- The rollback of models/osionos-ugc-moderation-migration.sql (the soft
-- moderation state, the append-only audit and the moderation queue).
--
-- THE RUNNER NEVER PICKS THIS FILE UP
--   The runner's glob is "${MODELS_DIR}"/*.sql
--   (scripts/apply-models-migrations.sh:289 in apply), and this file lives in
--   the models/rollback/ subdirectory, which that glob does not reach. The
--   ledger runner scripts/apply-models.sh globs the same way. A rollback is
--   run by hand, or by the service slice that owns the slice.
--
-- ORDER
--   The triggers first (a trigger on a dropped table would fail), then the
--   functions, then the tables, then the columns and the index. Dropping the
--   tables drops the columns of the comments with them — no: the two comment
--   tables are NOT dropped, only their two columns and their partial index.
--
-- IDEMPOTENT: every statement is IF EXISTS shaped, so it can be applied twice.
--
-- WHAT A ROLLBACK COSTS
--   The soft state: the two moderation columns and the partial index go, and
--   every comment becomes visible again — a held comment is shown to the
--   readers that filter on it, and a removed one comes back. The CONTENT of
--   the comments was never touched, so nothing is lost: the rollback undoes
--   the state, not the words.
--   The audit: every ai_moderation_events row is dropped with the table. An
--   audit that is gone is an audit that cannot answer. The erase of a user
--   that already happened is not undone.
--   The queue: the table is osionos-ai-jobs-migration.sql's and stays; its
--   'moderate' rows are deleted. The subjects that were never checked are
--   still unchecked; the re-apply re-queues nothing, because the queue is fed
--   by the WRITES, not by the migration.
--
--   The events file stays valid after this rollback: its ai_erase_user()
--   calls ai_moderation_erase_user() dynamically, and the call is skipped
--   when the function is not there.

-- The enqueue triggers, on the tables they observe.
DROP TRIGGER IF EXISTS ai_jobs_enqueue_feed_comments_insert ON public.osionos_feed_comments;
DROP TRIGGER IF EXISTS ai_jobs_enqueue_feed_comments_update ON public.osionos_feed_comments;
DROP TRIGGER IF EXISTS ai_jobs_enqueue_page_comments_insert ON public.osionos_page_comments;
DROP TRIGGER IF EXISTS ai_jobs_enqueue_page_comments_update ON public.osionos_page_comments;

-- The append-only triggers, on the audit.
DROP TRIGGER IF EXISTS ai_moderation_events_append_only ON public.ai_moderation_events;
DROP TRIGGER IF EXISTS ai_moderation_events_no_truncate ON public.ai_moderation_events;

-- The trigger functions.
DROP FUNCTION IF EXISTS public.ai_jobs_enqueue_feed_comments();
DROP FUNCTION IF EXISTS public.ai_jobs_enqueue_page_comments();

-- The service functions.
DROP FUNCTION IF EXISTS public.ai_moderation_erase_user(UUID);
DROP FUNCTION IF EXISTS public.ai_moderation_events_prune(interval);

-- The third new object: the append-only guard.
DROP FUNCTION IF EXISTS public.ai_moderation_events_guard();

-- The new table, and this file's rows of the queue.
DROP TABLE IF EXISTS public.ai_moderation_events;
DO $$
BEGIN
    IF to_regclass('public.ai_jobs') IS NOT NULL THEN
        DELETE FROM public.ai_jobs WHERE kind = 'moderate';
    END IF;
END $$;

-- The partial indexes, then the two columns on each comment table. The
-- content of a comment was never touched by the migration, so this is the
-- whole cost of the rollback on the comments.
DROP INDEX IF EXISTS public.osionos_feed_comments_moderation_state_idx;
DROP INDEX IF EXISTS public.osionos_page_comments_moderation_state_idx;

ALTER TABLE public.osionos_feed_comments
  DROP COLUMN IF EXISTS moderation_state,
  DROP COLUMN IF EXISTS moderation_changed_at;

ALTER TABLE public.osionos_page_comments
  DROP COLUMN IF EXISTS moderation_state,
  DROP COLUMN IF EXISTS moderation_changed_at;
