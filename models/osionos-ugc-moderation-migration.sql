-- UGC moderation: the soft state of a comment, the append-only audit of every
-- moderation decision, and the queue the classifier reads.
--
-- WHAT THIS IS
--   Three things, in one file, because they are one decision:
--     1. the SOFT state of a comment (public.osionos_feed_comments and
--        public.osionos_page_comments): moderation_state, never a delete;
--     2. the AUDIT (public.ai_moderation_events): every decision, append-only;
--     3. the QUEUE's triggers: they fill public.ai_jobs (the table is
--        osionos-ai-jobs-migration.sql's) with the subjects the classifier has
--        not looked at yet, coalescing one row per subject and kind.
--
-- WHY THE STATE IS SOFT (C86)
--   The delete paths of both comment tables are HARD and CASCADE:
--   osionos_feed_comments.parent_id -> osionos_feed_comments(id) ON DELETE
--   CASCADE (models/osionos-feed-engagement-migration.sql:26-27) and
--   osionos_page_comments.page_id -> osionos_pages(id) ON DELETE CASCADE
--   (models/osionos-comments-migration.sql:9). A moderation delete would take
--   the replies with it, and the audit would lose the decision that explains
--   the missing comment. So moderation NEVER deletes: it writes
--   moderation_state, and the content is never touched.
--
--   The state is exactly reversible: 'visible' -> 'held' -> 'removed' ->
--   'visible' changes two columns and nothing else. The content of a removed
--   comment is byte-identical to the content of a visible one.
--
-- WHO READS THE STATE
--   NOT YET. The readers that hide a held comment from a feed and from a page
--   are the BRIDGE SLICE (C87): they filter on moderation_state. This file
--   only WRITES the state; a reader that ignores the column still shows a
--   held comment. That is the next slice, not this one.
--
-- WHAT THE AUDIT IS (C92)
--   public.ai_moderation_events is APPEND-ONLY: a BEFORE UPDATE OR DELETE
--   trigger and a BEFORE TRUNCATE trigger raise unless the erasure switch is
--   on. A decision is never rewritten and never quietly disappears. The only
--   DELETE is inside ai_moderation_erase_user() and ai_moderation_events_prune()
--   — the two a person asked for.
--
-- WHAT THE QUEUE IS (C88, C89, C94)
--   One row per subject and kind: (kind, subject_kind, subject_id) is the
--   primary key, so a second comment on the same subject is an UPDATE of the
--   same row, not a second row. The row carries the sha256 of the content it
--   was queued for, so a worker can tell "the content I checked is the content
--   that is there now" from "the content changed under me" without reading
--   the comment.
--
--   THE SCOPE IS PUBLIC CONTENT ONLY (C94). A subject is queued only when its
--   page is readable by the public: the page is public, or the page is private
--   and its WORKSPACE is public. A private page of a confidential workspace
--   is never queued: an automated scan of a confidential workspace's content
--   is out of scope, and the trigger must not become a way to read it.
--
--   AN EDIT NEVER RE-HOLDS A COMMENT (C89). The enqueue trigger writes the
--   queue and nothing else: it never touches moderation_state. An edited HELD
--   comment stays HELD until it is re-checked; the edit only re-queues it.
--
-- THE FILE NAME IS AN ORDERING FACT (read the runner's ORDERING note)
--   This file is models/osionos-ugc-moderation-migration.sql, NOT
--   models/osionos-ai-moderation-migration.sql: it has to sort AFTER the
--   tables it reads and triggers on — osionos-chat-migration.sql
--   (osionos_feed_comments), osionos-comments-migration.sql
--   (osionos_page_comments), osionos-favorites-migration.sql and
--   osionos-feed-engagement-migration.sql — and after the tables it JOINS:
--   osionos_pages (osionos-bridge-migration.sql, ORDERED_FIRST) and
--   osionos_workspaces.visibility (osionos-social-migration.sql, ORDERED_FIRST).
--   A trigger on a table that does not exist yet is a hard error, so the order
--   is a correctness fact, not a style choice. The alphabetical pass is the
--   only slot both runners share (scripts/apply-models-migrations.sh and the
--   ledger runner scripts/apply-models.sh).
--
--   "osionos-ugc-..." sorts after "osionos-feed-...", "osionos-favorites-...",
--   "osionos-comments-..." and "osionos-chat-...", and before
--   "osionos-user-events-..." (u-g < u-s). That last one does not matter for
--   the order of the tables: the events file creates no table this file reads.
--   But the events file's ai_erase_user() calls ai_moderation_erase_user()
--   DYNAMICALLY, so the two files work in either order and each of them works
--   alone.
--
-- THE PRUNER'S RUNNER IS NOT WRITTEN YET
--   public.ai_moderation_events_prune(p_keep interval default '365 days')
--   deletes the rows older than the retention. The named runner that calls it
--   once a day is a LATER SERVICE SLICE. Until it exists, no row is ever
--   pruned and the audit only grows. The same words as the events file, for
--   the same reason: a later slice MUST write that runner, or the audit grows
--   without bound.
--
-- IDEMPOTENT
--   Every statement is IF NOT EXISTS / DROP ... IF EXISTS / CREATE OR REPLACE
--   shaped, so the file is replayed on every boot. It never deletes or
--   rewrites a row of ai_moderation_events, never deletes or rewrites a
--   comment, and never deletes a job row: the queue is coalesced by an UPSERT.

-- -----------------------------------------------------------------------------
-- 1. The soft state, on BOTH comment tables (C86).
--
--    Two columns, one of them the state itself, the other the moment the state
--    last changed. moderation_changed_at is written by the service that decides
--    (a later slice): this file only carries the column.
--
--    The CHECK is on the column, so a state outside the three names is
--    refused with 23514 — the same refusal a reader would rely on.
--
--    The index is PARTIAL: it holds the rows that are not 'visible', which is
--    the small set (a held or a removed comment). The visible majority costs
--    nothing in the index.
-- -----------------------------------------------------------------------------
ALTER TABLE public.osionos_feed_comments
  ADD COLUMN IF NOT EXISTS moderation_state TEXT NOT NULL DEFAULT 'visible'
    CHECK (moderation_state IN ('visible','held','removed')),
  ADD COLUMN IF NOT EXISTS moderation_changed_at TIMESTAMPTZ;

ALTER TABLE public.osionos_page_comments
  ADD COLUMN IF NOT EXISTS moderation_state TEXT NOT NULL DEFAULT 'visible'
    CHECK (moderation_state IN ('visible','held','removed')),
  ADD COLUMN IF NOT EXISTS moderation_changed_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS osionos_feed_comments_moderation_state_idx
  ON public.osionos_feed_comments (moderation_state) WHERE moderation_state <> 'visible';

CREATE INDEX IF NOT EXISTS osionos_page_comments_moderation_state_idx
  ON public.osionos_page_comments (moderation_state) WHERE moderation_state <> 'visible';

COMMENT ON COLUMN public.osionos_feed_comments.moderation_state IS
    'The soft moderation state of the comment: visible, held or removed. '
    'Moderation never deletes a comment — the delete paths of this table '
    'cascade to the replies. The readers that hide a held comment are the '
    'bridge slice (C87), which is NOT written yet.';
COMMENT ON COLUMN public.osionos_page_comments.moderation_state IS
    'The soft moderation state of the comment: visible, held or removed. '
    'Moderation never deletes a comment. The readers that hide a held comment '
    'are the bridge slice (C87), which is NOT written yet.';

-- -----------------------------------------------------------------------------
-- 2. The audit (C92): public.ai_moderation_events.
--
--    The columns exactly as the brief names them. No text payload: a row says
--    WHO did WHAT to WHICH subject, in which workspace, at which layer, with
--    which scores and which policy — not what the subject said. The content of
--    a moderated subject is a sha256, not a copy: the audit can prove which
--    content was judged without keeping the content.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_moderation_events (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts             TIMESTAMPTZ NOT NULL DEFAULT now(),
    subject_kind   TEXT NOT NULL CHECK (subject_kind IN ('feed_comment','page_comment','message','profile','page')),
    subject_id     TEXT NOT NULL CHECK (length(subject_id) <= 80),
    workspace_id   UUID,
    author_id      UUID,
    layer          TEXT NOT NULL CHECK (layer IN ('l0','l1','l2','report','admin')),
    actor_id       UUID,
    action         TEXT NOT NULL CHECK (action IN ('allow','warn','hold','remove','restore','mute','view')),
    mode           TEXT CHECK (mode IN ('off','log','hold','on')),
    scores         JSONB CHECK (scores IS NULL OR jsonb_typeof(scores) = 'object'),
    policy_hash    TEXT CHECK (policy_hash ~ '^[0-9a-f]{64}$'),
    content_sha256 TEXT CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
    reason         TEXT CHECK (length(reason) <= 200)
);

COMMENT ON TABLE public.ai_moderation_events IS
    'The append-only audit of every moderation decision. A row says which '
    'subject was judged, by which layer, with which action and which scores — '
    'never the content itself, only its sha256. UPDATE, DELETE and TRUNCATE '
    'are refused by a trigger: the only DELETE is the erasure and the prune.';

-- The two reads the audit answers: everything that happened to a subject, and
-- everything that happened to an author.
CREATE INDEX IF NOT EXISTS ai_moderation_events_subject_ts_idx
    ON public.ai_moderation_events (subject_kind, subject_id, ts DESC);
CREATE INDEX IF NOT EXISTS ai_moderation_events_author_ts_idx
    ON public.ai_moderation_events (author_id, ts DESC);

-- -----------------------------------------------------------------------------
-- 3. The append-only guard (C92).
--
--    A BEFORE UPDATE OR DELETE ... FOR EACH ROW trigger and a BEFORE TRUNCATE
--    ... FOR EACH STATEMENT trigger. Both raise unless the erasure switch
--    (SET osionos.moderation_erase = 'on') is on for the transaction, which
--    only ai_moderation_erase_user() and ai_moderation_events_prune() turn
--    on.
--
--    The trigger, not the GRANT, is what makes the table append-only: the
--    grant below is SELECT and INSERT, and a session that holds more (a boot
--    that granted everything by default) still cannot rewrite a decision.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_moderation_events_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF coalesce(current_setting('osionos.moderation_erase', true), '') = 'on' THEN
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        END IF;
        IF TG_OP = 'UPDATE' THEN
            RETURN NEW;
        END IF;
        -- TRUNCATE: a statement trigger's return value is ignored, and NEW is
        -- not assigned in one.
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'ai_moderation_events is append-only: % is refused (set osionos.moderation_erase = ''on'' to erase)', TG_OP;
END $$;

DROP TRIGGER IF EXISTS ai_moderation_events_append_only ON public.ai_moderation_events;
CREATE TRIGGER ai_moderation_events_append_only
    BEFORE UPDATE OR DELETE ON public.ai_moderation_events
    FOR EACH ROW
    EXECUTE FUNCTION public.ai_moderation_events_guard();

DROP TRIGGER IF EXISTS ai_moderation_events_no_truncate ON public.ai_moderation_events;
CREATE TRIGGER ai_moderation_events_no_truncate
    BEFORE TRUNCATE ON public.ai_moderation_events
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.ai_moderation_events_guard();

COMMENT ON FUNCTION public.ai_moderation_events_guard() IS
    'Refuses an UPDATE, a DELETE and a TRUNCATE of ai_moderation_events, '
    'unless the transaction turned osionos.moderation_erase on. The audit is '
    'append-only: a decision is never rewritten and never quietly disappears.';

-- -----------------------------------------------------------------------------
-- 4. The queue (C88): public.ai_jobs — its TABLE is osionos-ai-jobs-migration.sql's.
--
--    One row per subject and kind; an edited comment is the same row re-queued
--    with the sha of the new content and the attempts back at zero. The table,
--    its index, its kinds and its grants live in osionos-ai-jobs-migration.sql,
--    which sorts before this file: this file only FILLS the queue (section 5).
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 5. The enqueue triggers (C88, C89, C94).
--
--    ONE FUNCTION PER TABLE, SECURITY DEFINER with a fixed search_path, the
--    osionos.ai_jobs = 'off' switch first, and ONE BEGIN ... EXCEPTION WHEN
--    OTHERS THEN RAISE WARNING ... END block around the upsert — one per
--    statement, never one per row. A broken queue is a warning; the user's
--    comment goes through.
--
--    TWO STATEMENT-LEVEL TRIGGERS PER TABLE: AFTER INSERT ... REFERENCING NEW
--    TABLE AS new_rows, and AFTER UPDATE ... REFERENCING OLD TABLE AS old_rows
--    NEW TABLE AS new_rows.
--
--    The UPDATE trigger has NO column list, and that is not an oversight:
--    PostgreSQL forbids transition tables on a trigger with a column list
--    ("AFTER UPDATE OF content ... REFERENCING" is an error). The function
--    filters the change itself, with o.content IS DISTINCT FROM n.content.
--
--    One function per table, two triggers: the function branches on TG_OP, and
--    the branch that the current trigger does not have a transition table for
--    is never reached — so its statement is never planned against a missing
--    table. That is why the events file's rule ("one function per table")
--    holds here too.
--
--    The scope: a subject is queued only when its page is readable by the
--    public. The JOIN on osionos_pages also skips a GHOST page id (a feed
--    row that names a page with no row) — skipped, never a NULL failure.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_jobs_enqueue_feed_comments()
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
            SELECT 'moderate', 'feed_comment', n.id::text, p.workspace_id,
                   encode(sha256(convert_to(n.content, 'UTF8')), 'hex')
              FROM new_rows n
              JOIN old_rows o ON o.id = n.id
              JOIN public.osionos_pages p ON p.id = n.page_id
              JOIN public.osionos_workspaces w ON w.id = p.workspace_id
             WHERE o.content IS DISTINCT FROM n.content
               AND p.archived_at IS NULL
               AND (p.visibility = 'public' OR w.visibility = 'public')
            ON CONFLICT (kind, subject_kind, subject_id) DO UPDATE
               SET content_sha256 = EXCLUDED.content_sha256,
                   run_after      = now(),
                   attempts       = 0,
                   last_error     = NULL,
                   enqueued_at    = now();
        ELSE
            INSERT INTO public.ai_jobs (kind, subject_kind, subject_id, workspace_id, content_sha256)
            SELECT 'moderate', 'feed_comment', n.id::text, p.workspace_id,
                   encode(sha256(convert_to(n.content, 'UTF8')), 'hex')
              FROM new_rows n
              JOIN public.osionos_pages p ON p.id = n.page_id
              JOIN public.osionos_workspaces w ON w.id = p.workspace_id
             WHERE p.archived_at IS NULL
               AND (p.visibility = 'public' OR w.visibility = 'public')
            ON CONFLICT (kind, subject_kind, subject_id) DO UPDATE
               SET content_sha256 = EXCLUDED.content_sha256,
                   run_after      = now(),
                   attempts       = 0,
                   last_error     = NULL,
                   enqueued_at    = now();
        END IF;
        GET DIAGNOSTICS v_enqueued = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'ai_jobs enqueue skipped: %', SQLERRM;
        v_enqueued := 0;
    END;
    -- ONE notification per statement that enqueued something: a worker wakes
    -- once for a bulk insert, not once per row.
    IF v_enqueued > 0 THEN
        PERFORM pg_notify('ai_jobs', 'moderate');
    END IF;
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS ai_jobs_enqueue_feed_comments_insert ON public.osionos_feed_comments;
CREATE TRIGGER ai_jobs_enqueue_feed_comments_insert
    AFTER INSERT ON public.osionos_feed_comments
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.ai_jobs_enqueue_feed_comments();

DROP TRIGGER IF EXISTS ai_jobs_enqueue_feed_comments_update ON public.osionos_feed_comments;
CREATE TRIGGER ai_jobs_enqueue_feed_comments_update
    AFTER UPDATE ON public.osionos_feed_comments
    REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.ai_jobs_enqueue_feed_comments();

-- A suggested edit (#228, osionos-discussions-migration.sql) is moderated on
-- what it shows: the comment, the proposed insert and the quoted text, so a PATCH
-- of the insert re-queues (S8). to_jsonb(row) reads the columns only where they
-- exist, so this file still applies, and still hashes plain comments to the same
-- digest, on a database without them.
CREATE OR REPLACE FUNCTION public.ai_jobs_enqueue_page_comments()
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
            SELECT 'moderate', 'page_comment', n.id::text, p.workspace_id,
                   encode(sha256(convert_to(n.content
                       || coalesce(to_jsonb(n) -> 'suggestion' ->> 'insert', '')
                       || coalesce(to_jsonb(n) -> 'anchor' ->> 'quote', ''), 'UTF8')), 'hex')
              FROM new_rows n
              JOIN old_rows o ON o.id = n.id
              JOIN public.osionos_pages p ON p.id = n.page_id
              JOIN public.osionos_workspaces w ON w.id = p.workspace_id
             WHERE (o.content IS DISTINCT FROM n.content
                    OR to_jsonb(o) -> 'suggestion' IS DISTINCT FROM to_jsonb(n) -> 'suggestion')
               AND p.archived_at IS NULL
               AND (p.visibility = 'public' OR w.visibility = 'public')
            ON CONFLICT (kind, subject_kind, subject_id) DO UPDATE
               SET content_sha256 = EXCLUDED.content_sha256,
                   run_after      = now(),
                   attempts       = 0,
                   last_error     = NULL,
                   enqueued_at    = now();
        ELSE
            INSERT INTO public.ai_jobs (kind, subject_kind, subject_id, workspace_id, content_sha256)
            SELECT 'moderate', 'page_comment', n.id::text, p.workspace_id,
                   encode(sha256(convert_to(n.content
                       || coalesce(to_jsonb(n) -> 'suggestion' ->> 'insert', '')
                       || coalesce(to_jsonb(n) -> 'anchor' ->> 'quote', ''), 'UTF8')), 'hex')
              FROM new_rows n
              JOIN public.osionos_pages p ON p.id = n.page_id
              JOIN public.osionos_workspaces w ON w.id = p.workspace_id
             WHERE p.archived_at IS NULL
               AND (p.visibility = 'public' OR w.visibility = 'public')
            ON CONFLICT (kind, subject_kind, subject_id) DO UPDATE
               SET content_sha256 = EXCLUDED.content_sha256,
                   run_after      = now(),
                   attempts       = 0,
                   last_error     = NULL,
                   enqueued_at    = now();
        END IF;
        GET DIAGNOSTICS v_enqueued = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'ai_jobs enqueue skipped: %', SQLERRM;
        v_enqueued := 0;
    END;
    IF v_enqueued > 0 THEN
        PERFORM pg_notify('ai_jobs', 'moderate');
    END IF;
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS ai_jobs_enqueue_page_comments_insert ON public.osionos_page_comments;
CREATE TRIGGER ai_jobs_enqueue_page_comments_insert
    AFTER INSERT ON public.osionos_page_comments
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.ai_jobs_enqueue_page_comments();

DROP TRIGGER IF EXISTS ai_jobs_enqueue_page_comments_update ON public.osionos_page_comments;
CREATE TRIGGER ai_jobs_enqueue_page_comments_update
    AFTER UPDATE ON public.osionos_page_comments
    REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.ai_jobs_enqueue_page_comments();

COMMENT ON FUNCTION public.ai_jobs_enqueue_feed_comments() IS
    'Queues a feed comment for moderation: one row per subject, coalesced. '
    'Only a comment on a page readable by the public is queued (C94) — a '
    'private page of a confidential workspace is never queued. An edit '
    're-queues the subject and NEVER touches moderation_state (C89). A failure '
    'is a WARNING: the comment never fails because of the queue.';
COMMENT ON FUNCTION public.ai_jobs_enqueue_page_comments() IS
    'Queues a page comment for moderation: one row per subject, coalesced. '
    'Only a comment on a page readable by the public is queued (C94) — a '
    'private page of a confidential workspace is never queued. An edit '
    're-queues the subject and NEVER touches moderation_state (C89). A failure '
    'is a WARNING: the comment never fails because of the queue.';

-- -----------------------------------------------------------------------------
-- 6. The grants: service_role only.
--
--    ai_moderation_events is APPEND-ONLY, so it gets SELECT and INSERT and
--    nothing else — NOT the GRANT ALL pattern of the other files. The trigger
--    above is what actually makes it append-only; the grant only says what the
--    service needs.
--
--    ai_jobs closes itself in osionos-ai-jobs-migration.sql, its owner.
--
--    The catalog-wide revoke of osionos-service-role-only-migration.sql
--    matches osionos\_% only, so the ai_* relations have to close themselves —
--    and they do it here, on every replay.
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_moderation_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_moderation_events_service_role_all ON public.ai_moderation_events;
CREATE POLICY ai_moderation_events_service_role_all ON public.ai_moderation_events
    FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

GRANT SELECT, INSERT ON public.ai_moderation_events TO service_role;

REVOKE ALL ON public.ai_moderation_events FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 7. The erasure and the prune (C92).
--
--    ai_moderation_erase_user(p_user): deletes the rows the user AUTHORED and
--    nulls the rows where the user was the ACTOR. The difference matters: an
--    admin's erasure must not rewrite the decision they took — it takes the
--    name away and keeps the decision, so the audit still says what was
--    decided about the subject.
--
--    ai_moderation_events_prune(p_keep): the retention. It is the SAME switch
--    and the SAME guard trigger: the prune is a delete, and the guard refuses
--    every delete that did not ask for it.
--
--    Both are SECURITY DEFINER and executable by service_role only.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_moderation_erase_user(p_user UUID)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
-- The erase switch is on for THIS CALL only (a function SET clause is restored
-- on return): set_config(…, true) would leave it on for the rest of the caller's
-- transaction, where a later UPDATE of the audit would pass the guard.
SET osionos.moderation_erase = 'on'
AS $$
DECLARE
    n BIGINT;
BEGIN
    DELETE FROM public.ai_moderation_events WHERE author_id = p_user;
    GET DIAGNOSTICS n = ROW_COUNT;
    -- An admin's erasure keeps the decision, not the name.
    UPDATE public.ai_moderation_events SET actor_id = NULL WHERE actor_id = p_user;
    RETURN n;
END $$;

COMMENT ON FUNCTION public.ai_moderation_erase_user(UUID) IS
    'Erases the moderation rows of the user: the rows the user AUTHORED are '
    'deleted, the rows where the user was the ACTOR keep the decision and '
    'lose the name (actor_id becomes NULL). Returns the number of deleted '
    'rows. Idempotent: a second call deletes 0.';

CREATE OR REPLACE FUNCTION public.ai_moderation_events_prune(p_keep INTERVAL DEFAULT '365 days')
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
SET osionos.moderation_erase = 'on'
AS $$
DECLARE
    n BIGINT;
BEGIN
    DELETE FROM public.ai_moderation_events WHERE ts < now() - p_keep;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;

COMMENT ON FUNCTION public.ai_moderation_events_prune(interval) IS
    'Deletes the moderation rows older than the retention (default 365 days) '
    'and returns the number of deleted rows. The daily runner that calls this '
    'is a LATER SERVICE SLICE and is not written yet: until it exists, no row '
    'is ever pruned and the audit only grows.';

REVOKE ALL ON FUNCTION public.ai_moderation_erase_user(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_moderation_events_prune(interval) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ai_moderation_erase_user(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.ai_moderation_events_prune(interval) TO service_role;

-- A trigger function cannot be called directly, but PUBLIC's default EXECUTE
-- on it is closed anyway: the same service_role-only rule for every function
-- this file creates.
REVOKE ALL ON FUNCTION public.ai_moderation_events_guard() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_jobs_enqueue_feed_comments() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_jobs_enqueue_page_comments() FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
