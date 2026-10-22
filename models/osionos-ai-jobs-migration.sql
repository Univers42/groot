-- ai_jobs — the enrichment queue of the AI plane: moderation (M4 L1), sentiment
-- (M6) and image tagging (M7) run here, in the background, on local encoders.
--
-- One row per (kind, subject): a subject edited ten times while its job waits is
-- classified once. ai_index_queue is NOT reused: it is keyed by page and
-- debounced for typing, and these subjects are comments, posts, rows, media.
--
-- The worker leases rather than locks: a claim pushes run_after out by the lease
-- in one UPDATE … FOR UPDATE SKIP LOCKED, so two replicas never take the same row
-- and a crashed worker's job comes back when the lease ends. A job is deleted
-- only if enqueued_at did not move while it ran (the indexer's dirty_at rule):
-- a re-enqueue during the run leaves the row, and the subject is done again.
--
-- Caveat: a re-enqueue during a run makes the row claimable at once, so a second
-- replica can process the newer version while the first still holds the older
-- one; the two results race. Handlers must write their result keyed by the
-- content hash they classified, so the stale one is recognisable.
--
-- Idempotent: every CREATE is IF NOT EXISTS / OR REPLACE.

-- -----------------------------------------------------------------------------
-- 1. The table
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_jobs (
    kind          TEXT NOT NULL CHECK (kind IN ('moderate', 'sentiment', 'image_tag')),
    subject_kind  TEXT NOT NULL CHECK (subject_kind ~ '^[a-z_]{1,32}$'),
    subject_id    TEXT NOT NULL CHECK (length(subject_id) BETWEEN 1 AND 200),
    workspace_id  UUID,
    -- 0 = a person is waiting on the result (a fresh comment), 1 = bulk (a backfill).
    priority      SMALLINT NOT NULL DEFAULT 1 CHECK (priority IN (0, 1)),
    run_after     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- clock_timestamp(), not NOW(): two enqueues in one transaction still differ.
    enqueued_at   TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    attempts      INT NOT NULL DEFAULT 0,
    -- An error class and message, never the subject's content.
    last_error    TEXT CHECK (last_error IS NULL OR length(last_error) <= 500),
    PRIMARY KEY (kind, subject_kind, subject_id)
);

CREATE INDEX IF NOT EXISTS ai_jobs_claim_idx
    ON public.ai_jobs (kind, priority, run_after);

COMMENT ON TABLE public.ai_jobs IS
    'Enrichment queue (moderate, sentiment, image_tag), coalesced to one row per '
    '(kind, subject). Filled by ai_enqueue_job, drained by the osionos-ai jobs '
    'worker with a lease. Notifies on channel ai_jobs with the kind as payload.';

-- -----------------------------------------------------------------------------
-- 2. Enqueue
-- -----------------------------------------------------------------------------
-- A re-enqueue is new content: it runs now, from attempt zero, and keeps the more
-- urgent of the two lanes.
CREATE OR REPLACE FUNCTION public.ai_enqueue_job(
    p_kind TEXT,
    p_subject_kind TEXT,
    p_subject_id TEXT,
    p_workspace_id UUID,
    p_priority SMALLINT DEFAULT 1
) RETURNS VOID
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    INSERT INTO public.ai_jobs (kind, subject_kind, subject_id, workspace_id, priority)
    VALUES (p_kind, p_subject_kind, p_subject_id, p_workspace_id, p_priority)
    ON CONFLICT (kind, subject_kind, subject_id) DO UPDATE SET
        workspace_id = EXCLUDED.workspace_id,
        priority     = LEAST(public.ai_jobs.priority, EXCLUDED.priority),
        run_after    = NOW(),
        enqueued_at  = clock_timestamp(),
        attempts     = 0,
        last_error   = NULL;
    PERFORM pg_notify('ai_jobs', p_kind);
END;
$$;

COMMENT ON FUNCTION public.ai_enqueue_job(TEXT, TEXT, TEXT, UUID, SMALLINT) IS
    'Queues (or re-queues) one enrichment job; coalesces to one row per '
    '(kind, subject) and notifies channel ai_jobs with the kind.';

-- -----------------------------------------------------------------------------
-- 3. RLS: service_role only
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_jobs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_jobs_service_role_all ON public.ai_jobs;
CREATE POLICY ai_jobs_service_role_all
    ON public.ai_jobs FOR ALL
    TO service_role USING (TRUE) WITH CHECK (TRUE);

GRANT ALL ON public.ai_jobs TO service_role;
REVOKE ALL ON public.ai_jobs FROM PUBLIC, ANON, AUTHENTICATED;

GRANT EXECUTE ON FUNCTION public.ai_enqueue_job(TEXT, TEXT, TEXT, UUID, SMALLINT) TO service_role;
REVOKE ALL ON FUNCTION public.ai_enqueue_job(TEXT, TEXT, TEXT, UUID, SMALLINT) FROM PUBLIC, ANON, AUTHENTICATED;

NOTIFY pgrst, 'reload schema';
