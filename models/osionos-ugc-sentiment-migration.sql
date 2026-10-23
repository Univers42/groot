-- AI sentiment (M6, slice 1): the opt-in switch, the score store and the queue
-- feed for the comments of a workspace that turned it on.
--
-- WHAT THIS IS
--   1. public.ai_sentiment_settings: one row per workspace, enabled = false by
--      default (C138). Only the bridge writes it, after a live admin check.
--   2. public.ai_sentiment: one score per page comment (label, confidence, the
--      pinned model, the sha of the scored text). It has NO author column
--      (C140): a score can only be joined to a person through the live
--      comment, never read per person from this table.
--   3. The triggers that queue a 'sentiment' job on public.ai_jobs when a
--      comment of an opted-in workspace is written, and the triggers that
--      remove every derived row with its source (C143).
--   4. public.ai_sentiment_erase_user(uuid), dispatched from ai_erase_user().
--
-- THE FILE NAME
--   Named osionos-ugc-* so the runner's alphabetical pass applies it AFTER
--   osionos-comments-migration.sql and osionos-ai-jobs-migration.sql, the two
--   tables it triggers on / writes to. scripts/verify/ai-sentiment.sh (check a0)
--   reads the runner's order and fails when the file moves.
--
-- CAVEAT: the backfill window is the last 365 days of comment created_at; an
--   older comment is scored only when it is edited. Turning the switch off and
--   on again re-queues the window and re-scores it.
--
-- Idempotent: every statement is IF NOT EXISTS / CREATE OR REPLACE /
-- DROP TRIGGER IF EXISTS.

-- -----------------------------------------------------------------------------
-- 1. The tables.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_sentiment_settings (
    workspace_id UUID PRIMARY KEY,
    enabled      BOOLEAN NOT NULL DEFAULT false,
    updated_by   UUID,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.ai_sentiment_settings IS
    'Per-workspace opt-in for AI sentiment (C138). No row = off. Written only '
    'by the bridge after a live owner/admin check. service_role only.';

CREATE TABLE IF NOT EXISTS public.ai_sentiment (
    subject_kind   TEXT NOT NULL CHECK (subject_kind IN ('page_comment')),
    subject_id     TEXT NOT NULL CHECK (length(subject_id) <= 80),
    workspace_id   UUID NOT NULL,
    label          TEXT NOT NULL CHECK (label IN ('negative', 'neutral', 'positive')),
    confidence     REAL NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
    model          TEXT NOT NULL CHECK (length(model) <= 200),
    revision       TEXT CHECK (length(revision) <= 80),
    content_sha256 TEXT NOT NULL CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
    scored_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (subject_kind, subject_id)
);

CREATE INDEX IF NOT EXISTS ai_sentiment_workspace_scored_idx
    ON public.ai_sentiment (workspace_id, scored_at);

COMMENT ON TABLE public.ai_sentiment IS
    'One sentiment score per page comment. NO author column (C140). Derived '
    'data: deleted with the comment, with the workspace switch and with the '
    'author''s erasure (C143). service_role only (C145).';

-- -----------------------------------------------------------------------------
-- 2. Service-role-only storage (C145), as ai_moderation_events.
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_sentiment_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ai_sentiment_settings_service_role_all ON public.ai_sentiment_settings;
CREATE POLICY ai_sentiment_settings_service_role_all ON public.ai_sentiment_settings
    FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_sentiment_settings TO service_role;
REVOKE ALL ON public.ai_sentiment_settings FROM PUBLIC, anon, authenticated;

ALTER TABLE public.ai_sentiment ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ai_sentiment_service_role_all ON public.ai_sentiment;
CREATE POLICY ai_sentiment_service_role_all ON public.ai_sentiment
    FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_sentiment TO service_role;
REVOKE ALL ON public.ai_sentiment FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3. The enqueue on osionos_page_comments (C146): same shape as
--    ai_jobs_enqueue_page_comments() of the moderation file.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_jobs_enqueue_sentiment_page_comments()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_enqueued INTEGER := 0;
BEGIN
    IF coalesce(current_setting('osionos.ai_jobs', true), '') = 'off' THEN
        RETURN NULL;
    END IF;
    BEGIN
        IF TG_OP = 'UPDATE' THEN
            INSERT INTO public.ai_jobs (kind, subject_kind, subject_id, workspace_id, content_sha256)
            SELECT 'sentiment', 'page_comment', n.id::text, p.workspace_id,
                   encode(sha256(convert_to(n.content, 'UTF8')), 'hex')
              FROM new_rows n
              JOIN old_rows o ON o.id = n.id
              JOIN public.osionos_pages p ON p.id = n.page_id
              JOIN public.ai_sentiment_settings s ON s.workspace_id = p.workspace_id AND s.enabled
             WHERE o.content IS DISTINCT FROM n.content
               AND p.archived_at IS NULL
            ON CONFLICT (kind, subject_kind, subject_id) DO UPDATE
               SET content_sha256 = EXCLUDED.content_sha256,
                   run_after      = now(),
                   attempts       = 0,
                   last_error     = NULL,
                   enqueued_at    = now();
        ELSE
            INSERT INTO public.ai_jobs (kind, subject_kind, subject_id, workspace_id, content_sha256)
            SELECT 'sentiment', 'page_comment', n.id::text, p.workspace_id,
                   encode(sha256(convert_to(n.content, 'UTF8')), 'hex')
              FROM new_rows n
              JOIN public.osionos_pages p ON p.id = n.page_id
              JOIN public.ai_sentiment_settings s ON s.workspace_id = p.workspace_id AND s.enabled
             WHERE p.archived_at IS NULL
            ON CONFLICT (kind, subject_kind, subject_id) DO UPDATE
               SET content_sha256 = EXCLUDED.content_sha256,
                   run_after      = now(),
                   attempts       = 0,
                   last_error     = NULL,
                   enqueued_at    = now();
        END IF;
        GET DIAGNOSTICS v_enqueued = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'ai_jobs sentiment enqueue skipped: %', SQLERRM;
        v_enqueued := 0;
    END;
    IF v_enqueued > 0 THEN
        PERFORM pg_notify('ai_jobs', 'sentiment');
    END IF;
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS ai_jobs_enqueue_sentiment_page_comments_insert ON public.osionos_page_comments;
CREATE TRIGGER ai_jobs_enqueue_sentiment_page_comments_insert
    AFTER INSERT ON public.osionos_page_comments
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.ai_jobs_enqueue_sentiment_page_comments();

DROP TRIGGER IF EXISTS ai_jobs_enqueue_sentiment_page_comments_update ON public.osionos_page_comments;
CREATE TRIGGER ai_jobs_enqueue_sentiment_page_comments_update
    AFTER UPDATE ON public.osionos_page_comments
    REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.ai_jobs_enqueue_sentiment_page_comments();

COMMENT ON FUNCTION public.ai_jobs_enqueue_sentiment_page_comments() IS
    'Queues a page comment for sentiment, only when its workspace opted in '
    '(C138) and its page is not archived. An edit re-queues only when the '
    'content changed. Honours osionos.ai_jobs = off; a failure is a WARNING '
    'and never fails the comment (C146).';

-- -----------------------------------------------------------------------------
-- 4. A deleted comment takes its score and its pending job with it (C143).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_sentiment_forget_page_comments()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    DELETE FROM public.ai_sentiment s
     USING old_rows o
     WHERE s.subject_kind = 'page_comment' AND s.subject_id = o.id::text;
    DELETE FROM public.ai_jobs j
     USING old_rows o
     WHERE j.kind = 'sentiment' AND j.subject_kind = 'page_comment' AND j.subject_id = o.id::text;
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS ai_sentiment_forget_page_comments_delete ON public.osionos_page_comments;
CREATE TRIGGER ai_sentiment_forget_page_comments_delete
    AFTER DELETE ON public.osionos_page_comments
    REFERENCING OLD TABLE AS old_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.ai_sentiment_forget_page_comments();

-- -----------------------------------------------------------------------------
-- 5. The switch: on = backfill the last 365 days; off (or row deleted) = every
--    derived row and pending job of the workspace goes, in the same
--    transaction (C143). The delete is NOT inside an exception handler: if it
--    fails, the switch-off fails, rather than leaving scores behind.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_sentiment_settings_switch()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_ws        UUID;
    v_was_on    BOOLEAN := false;
    v_is_on     BOOLEAN := false;
    v_enqueued  INTEGER := 0;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_was_on := OLD.enabled;
        v_ws := OLD.workspace_id;
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_is_on := NEW.enabled;
        v_ws := NEW.workspace_id;
    END IF;

    IF v_was_on AND NOT v_is_on THEN
        DELETE FROM public.ai_sentiment WHERE workspace_id = v_ws;
        DELETE FROM public.ai_jobs WHERE kind = 'sentiment' AND workspace_id = v_ws;
    ELSIF v_is_on AND NOT v_was_on
          AND coalesce(current_setting('osionos.ai_jobs', true), '') <> 'off' THEN
        BEGIN
            INSERT INTO public.ai_jobs (kind, subject_kind, subject_id, workspace_id, content_sha256)
            SELECT 'sentiment', 'page_comment', c.id::text, p.workspace_id,
                   encode(sha256(convert_to(c.content, 'UTF8')), 'hex')
              FROM public.osionos_page_comments c
              JOIN public.osionos_pages p ON p.id = c.page_id
             WHERE p.workspace_id = v_ws
               AND p.archived_at IS NULL
               AND c.created_at > now() - interval '365 days'
            ON CONFLICT (kind, subject_kind, subject_id) DO UPDATE
               SET content_sha256 = EXCLUDED.content_sha256,
                   run_after      = now(),
                   attempts       = 0,
                   last_error     = NULL,
                   enqueued_at    = now();
            GET DIAGNOSTICS v_enqueued = ROW_COUNT;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'ai_jobs sentiment backfill skipped: %', SQLERRM;
            v_enqueued := 0;
        END;
        IF v_enqueued > 0 THEN
            PERFORM pg_notify('ai_jobs', 'sentiment');
        END IF;
    END IF;
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS ai_sentiment_settings_switch ON public.ai_sentiment_settings;
CREATE TRIGGER ai_sentiment_settings_switch
    AFTER INSERT OR UPDATE OR DELETE ON public.ai_sentiment_settings
    FOR EACH ROW
    EXECUTE FUNCTION public.ai_sentiment_settings_switch();

COMMENT ON FUNCTION public.ai_sentiment_settings_switch() IS
    'enabled -> true: queues the live comments of the workspace''s non-archived '
    'pages from the last 365 days. enabled -> false or row deleted: deletes the '
    'workspace''s ai_sentiment rows and sentiment jobs in the same transaction '
    '(C143).';

-- -----------------------------------------------------------------------------
-- 6. The erasure of an author (C143), dispatched from ai_erase_user().
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_sentiment_erase_user(p_user UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    n INTEGER;
BEGIN
    DELETE FROM public.ai_sentiment s
     USING public.osionos_page_comments c
     WHERE s.subject_kind = 'page_comment'
       AND s.subject_id = c.id::text
       AND c.author_id = p_user;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;

REVOKE ALL ON FUNCTION public.ai_sentiment_erase_user(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ai_sentiment_erase_user(UUID) TO service_role;

COMMENT ON FUNCTION public.ai_sentiment_erase_user(UUID) IS
    'Deletes the sentiment rows of the page comments the user authored and '
    'returns the count. Idempotent.';

NOTIFY pgrst, 'reload schema';
