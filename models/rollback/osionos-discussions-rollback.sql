-- The rollback of models/osionos-discussions-migration.sql (suggested edits,
-- replies and reactions on page comments, #228).
--
-- THE RUNNER NEVER PICKS THIS FILE UP
--   The runner's glob is "${MODELS_DIR}"/*.sql and this file lives in the
--   models/rollback/ subdirectory, which that glob does not reach. A rollback is
--   run by hand, by the deploy owner.
--
-- ORDER
--   Run it AFTER osionos-ugc-moderation-rollback.sql when both are rolled back
--   (the reverse of the apply order). The moderation and events triggers read the
--   new columns through to_jsonb(row), so they keep working with the columns gone.
--   Here: the triggers, then the functions, then the reactions table, then the
--   indexes, the constraints and the columns.
--
-- IDEMPOTENT: every statement is IF EXISTS shaped, so it can be applied twice.
--
-- WHAT A ROLLBACK COSTS
--   Every reaction is dropped with its table. Replies and suggestions stay as
--   rows, but lose what made them so: a reply becomes a root comment and a
--   suggestion a plain comment whose proposed text and verdict are gone. Text
--   already accepted into a page stays in the page — the splice was a page write.
--   A soft-deleted comment (content '') comes back as an empty comment.

SET lock_timeout = '5s';

DROP TRIGGER IF EXISTS osionos_page_comments_guard_write_trg ON public.osionos_page_comments;
DROP TRIGGER IF EXISTS osionos_page_comments_guard_delete_trg ON public.osionos_page_comments;

DROP FUNCTION IF EXISTS public.osionos_decide_suggestion(UUID, UUID, TEXT, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS public.osionos_block_path(JSONB, TEXT);
DROP FUNCTION IF EXISTS public.osionos_suggestion_rebase(JSONB, JSONB, TEXT);
DROP FUNCTION IF EXISTS public.osionos_suggestion_apply(TEXT, JSONB);
DROP FUNCTION IF EXISTS public.osionos_suggestion_anchor_at(TEXT, INT, INT);
DROP FUNCTION IF EXISTS public.osionos_suggestions_overlap(JSONB, JSONB);
DROP FUNCTION IF EXISTS public.osionos_suggestion_reanchor(TEXT, JSONB);
DROP FUNCTION IF EXISTS public.osionos_page_comments_guard_write();
DROP FUNCTION IF EXISTS public.osionos_page_comments_guard_delete();

DROP TABLE IF EXISTS public.osionos_page_comment_reactions;

DROP INDEX IF EXISTS public.osionos_page_comments_open_suggestions_idx;
DROP INDEX IF EXISTS public.osionos_page_comments_parent_idx;

ALTER TABLE public.osionos_page_comments
  DROP CONSTRAINT IF EXISTS osionos_page_comments_kind_check,
  DROP CONSTRAINT IF EXISTS osionos_page_comments_status_check,
  DROP CONSTRAINT IF EXISTS osionos_page_comments_suggestion_shape_check,
  DROP CONSTRAINT IF EXISTS osionos_page_comments_reply_kind_check,
  DROP CONSTRAINT IF EXISTS osionos_page_comments_decided_check,
  DROP CONSTRAINT IF EXISTS osionos_page_comments_anchor_check,
  DROP CONSTRAINT IF EXISTS osionos_page_comments_suggestion_check;

ALTER TABLE public.osionos_page_comments
  DROP COLUMN IF EXISTS parent_id,
  DROP COLUMN IF EXISTS kind,
  DROP COLUMN IF EXISTS anchor,
  DROP COLUMN IF EXISTS suggestion,
  DROP COLUMN IF EXISTS status,
  DROP COLUMN IF EXISTS decided_by,
  DROP COLUMN IF EXISTS decided_at,
  DROP COLUMN IF EXISTS deleted_at,
  DROP COLUMN IF EXISTS updated_at;

-- The erasure registry rows for these columns (osionos-account-erasure-migration.sql)
-- are skipped by the erase while the columns are absent (to_regclass / pg_attribute
-- miss), and come back into use on a re-apply.

NOTIFY pgrst, 'reload schema';
