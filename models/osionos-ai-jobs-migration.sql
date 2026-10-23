-- ai_jobs — the enrichment queue of the AI plane: moderation (M4 L1), sentiment
-- (M6) and image tagging (M7) run here, in the background, on local encoders.
--
-- THIS FILE OWNS THE TABLE. It was born in osionos-ugc-moderation-migration.sql
-- (M4, kind 'moderate' only); it moved here when M6 and M7 needed their kinds,
-- so the queue has ONE definition, and the AI service's test harness can apply
-- it without the comment tables. The UGC file keeps its enqueue triggers, which
-- write into this table.
--
-- THE FILE NAME IS AN ORDERING FACT: "osionos-ai-jobs-..." sorts before
-- "osionos-ugc-moderation-..." in the runner's alphabetical pass, so the table
-- exists before the triggers that fill it are created.
--
-- One row per (kind, subject): an edited subject is the same row re-queued,
-- with the sha256 of the new content and the attempts back at zero. The worker
-- (osionos services/osionos-ai/src/jobs) LEASES a row: a claim pushes run_after
-- out, so two replicas never take the same row and a crashed worker's job comes
-- back when the lease ends. A row is deleted only if enqueued_at did not move
-- while it ran; a re-enqueue during the run leaves it, and it runs again.
--
-- Caveat: a re-enqueue during a run makes the row claimable at once, so a second
-- replica can process the newer content while the first still holds the older;
-- the two results race. A handler writes its result keyed by content_sha256, so
-- the stale one is recognisable.
--
-- Idempotent: IF NOT EXISTS / OR REPLACE / DROP ... IF EXISTS, replayed on boot.

-- -----------------------------------------------------------------------------
-- 1. The table. priority: lower runs first. run_after: the lease and the backoff.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_jobs (
    kind           TEXT NOT NULL CHECK (kind IN ('moderate', 'sentiment', 'image_tag')),
    subject_kind   TEXT NOT NULL,
    subject_id     TEXT NOT NULL,
    workspace_id   UUID,
    priority       SMALLINT NOT NULL DEFAULT 5,
    run_after      TIMESTAMPTZ NOT NULL DEFAULT now(),
    attempts       INTEGER NOT NULL DEFAULT 0,
    last_error     TEXT CHECK (length(last_error) <= 500),
    content_sha256 TEXT,
    enqueued_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (kind, subject_kind, subject_id)
);

-- A table the UGC file created before this one existed has the 'moderate'-only
-- CHECK: it gets the kinds of today, by the same constraint name.
ALTER TABLE public.ai_jobs DROP CONSTRAINT IF EXISTS ai_jobs_kind_check;
ALTER TABLE public.ai_jobs ADD CONSTRAINT ai_jobs_kind_check
    CHECK (kind IN ('moderate', 'sentiment', 'image_tag'));

COMMENT ON TABLE public.ai_jobs IS
    'The enrichment queue (moderate, sentiment, image_tag). One row per subject '
    'and kind: the primary key coalesces the queue, so an edited subject is the '
    'same row re-queued. content_sha256 is the sha256 of the content the subject '
    'was queued for. Notifies channel ai_jobs with the kind. service_role only.';

-- The worker's read: what is due, most urgent first.
CREATE INDEX IF NOT EXISTS ai_jobs_run_after_priority_idx
    ON public.ai_jobs (run_after, priority);

-- -----------------------------------------------------------------------------
-- 2. Enqueue from the service (the comment triggers have their own upsert, with
--    the same ON CONFLICT). A re-enqueue is new content: it runs now, from
--    attempt zero, and keeps the more urgent of the two priorities.
-- -----------------------------------------------------------------------------
-- The five-argument draft of this function (never merged) would make a
-- five-argument call ambiguous next to this one.
DROP FUNCTION IF EXISTS public.ai_enqueue_job(TEXT, TEXT, TEXT, UUID, SMALLINT);

CREATE OR REPLACE FUNCTION public.ai_enqueue_job(
    p_kind TEXT,
    p_subject_kind TEXT,
    p_subject_id TEXT,
    p_workspace_id UUID,
    p_priority SMALLINT DEFAULT 5,
    p_content_sha256 TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    INSERT INTO public.ai_jobs (kind, subject_kind, subject_id, workspace_id, priority, content_sha256)
    VALUES (p_kind, p_subject_kind, p_subject_id, p_workspace_id, p_priority, p_content_sha256)
    ON CONFLICT (kind, subject_kind, subject_id) DO UPDATE SET
        workspace_id   = EXCLUDED.workspace_id,
        priority       = LEAST(public.ai_jobs.priority, EXCLUDED.priority),
        content_sha256 = EXCLUDED.content_sha256,
        run_after      = now(),
        attempts       = 0,
        last_error     = NULL,
        enqueued_at    = clock_timestamp();
    PERFORM pg_notify('ai_jobs', p_kind);
END;
$$;

COMMENT ON FUNCTION public.ai_enqueue_job(TEXT, TEXT, TEXT, UUID, SMALLINT, TEXT) IS
    'Queues (or re-queues) one enrichment job; coalesces to one row per '
    '(kind, subject) and notifies channel ai_jobs with the kind. service_role only.';

-- -----------------------------------------------------------------------------
-- 3. RLS: service_role only. The catalog-wide revoke of
--    osionos-service-role-only-migration.sql matches osionos\_% only, so this
--    table closes itself, on every replay.
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_jobs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_jobs_service_role_all ON public.ai_jobs;
CREATE POLICY ai_jobs_service_role_all ON public.ai_jobs
    FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_jobs TO service_role;
REVOKE ALL ON public.ai_jobs FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.ai_enqueue_job(TEXT, TEXT, TEXT, UUID, SMALLINT, TEXT) TO service_role;
REVOKE ALL ON FUNCTION public.ai_enqueue_job(TEXT, TEXT, TEXT, UUID, SMALLINT, TEXT) FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
