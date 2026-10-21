-- Private workspace RAG index: chunk table, change-capture queue, synchronous
-- permission sync triggers. The assistant answers from this index with hybrid
-- search (full text + pgvector) INSIDE our Postgres.
--
-- Idempotent: every CREATE is IF NOT EXISTS / DROP ... IF EXISTS-shaped;
-- applied twice against a throwaway pgvector 0.8.0 / PG16 container to prove it.
--
-- Style + RLS service-role-only pattern copied from osionos-ai-migration.sql.
-- Real osionos_pages columns from osionos-bridge-migration.sql (id, workspace_id,
-- owner_id, visibility, collaborators, archived_at, title, content).
-- Page trigger precedent from osionos-tasks-migration.sql.
-- pgvector/HNSW precedent from osionos-social-migration.sql.
-- Shared block walker (osionos_page_blocks, osionos_page_text) from
-- osionos-page-search-migration.sql.
-- "Can read" predicate from bridge-page-read.mjs: visibility in
-- {private,shared,public} (anything else, NULL included, is 'private'),
-- owner_id, collaborators[] entries with {userId, role != null}.

CREATE EXTENSION IF NOT EXISTS vector;

-- -----------------------------------------------------------------------------
-- 1. ai_chunks — partitioned by workspace_id (16 hash partitions)
-- -----------------------------------------------------------------------------
-- PRIMARY KEY includes workspace_id so it can be the partition key.
-- UNIQUE (workspace_id, source_kind, source_id, ord) prevents duplicate chunks.
-- ACL columns (owner_id, visibility, collaborator_ids) are COPIES from the
-- source page — used ONLY for pre-filtering in the vector/tsvector scan.
-- The service RE-CHECKS every candidate page with the bridge's predicate
-- (bridge-page-read.mjs) before returning it. This avoids a stale-copy window
-- for permission changes: the AFTER UPDATE trigger on visibility/collaborators/
-- owner/workspace syncs these columns SYNCHRONOUSLY in the same transaction.
-- 'simple' dictionary for tsvector: multilingual workspaces; no stemming
-- assumptions. The bridge uses 'simple' for display_name/username search too
-- (osionos-social-migration.sql:23-24).

CREATE TABLE IF NOT EXISTS public.ai_chunks (
    id              BIGINT GENERATED ALWAYS AS IDENTITY,
    workspace_id    UUID NOT NULL,
    source_kind     TEXT NOT NULL CHECK (source_kind IN ('page', 'db_row')),
    source_id       UUID NOT NULL,
    block_id        TEXT,
    ord             INT NOT NULL,                          -- chunk order in the source
    title           TEXT NOT NULL DEFAULT '',
    heading_path    TEXT NOT NULL DEFAULT '',
    content         TEXT NOT NULL,
    content_hash    BYTEA NOT NULL,
    owner_id        UUID,
    visibility      TEXT,
    collaborator_ids UUID[] NOT NULL DEFAULT '{}',
    embedding       HALFVEC(384),
    embedding_model TEXT,
    tsv             TSVECTOR GENERATED ALWAYS AS (
                        TO_TSVECTOR('simple', title || ' ' || heading_path || ' ' || content)
                      ) STORED,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (workspace_id, id),
    UNIQUE (workspace_id, source_kind, source_id, ord)
) PARTITION BY HASH (workspace_id);

-- 16 hash partitions (p00 .. p15)
DO $$
DECLARE
    i INT;
    part_name TEXT;
BEGIN
    FOR i IN 0..15 LOOP
        part_name := 'ai_chunks_p' || LPAD(i::TEXT, 2, '0');
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = part_name) THEN
            EXECUTE format('CREATE TABLE public.%I PARTITION OF public.ai_chunks FOR VALUES WITH (MODULUS 16, REMAINDER %s)', part_name, i);
        END IF;
    END LOOP;
END $$;

-- HNSW index for vector similarity (cosine). m=16, ef_construction=64 —
-- good recall for 384-dim embeddings without excessive build time.
-- Precedent: osionos-social-migration.sql:39-40 (hnsw on bio_embedding).
CREATE INDEX IF NOT EXISTS ai_chunks_embedding_hnsw
    ON public.ai_chunks USING hnsw (embedding HALFVEC_COSINE_OPS)
    WITH (m = 16, ef_construction = 64);

-- GIN index on the generated tsvector for full-text search.
CREATE INDEX IF NOT EXISTS ai_chunks_tsv_gin
    ON public.ai_chunks USING gin (tsv);

-- Lookup by (workspace_id, source_id) — used by the worker to delete a
-- page's chunks and by the ACL sync trigger.
CREATE INDEX IF NOT EXISTS ai_chunks_ws_source_idx
    ON public.ai_chunks (workspace_id, source_id);

COMMENT ON TABLE public.ai_chunks IS
    'RAG chunks for the AI assistant. Partitioned by workspace_id (16 ways). '
    'ACL columns are denormalized copies for pre-filter ONLY — the service '
    're-verifies every hit with bridge-page-read.mjs predicates. '
    'tsvector uses ''simple'' dictionary (multilingual, no stemming assumptions).';

COMMENT ON COLUMN public.ai_chunks.content_hash IS
    'SHA-256 of the chunk content; the worker uses it to skip unchanged chunks.';

COMMENT ON COLUMN public.ai_chunks.embedding IS
    '384-dim half-precision vector (e.g. all-MiniLM-L6-v2). HALFVEC saves 50% space vs vector.';

COMMENT ON COLUMN public.ai_chunks.collaborator_ids IS
    'UUID[] of collaborator user_ids whose entry has a non-null role — ANY '
    'non-null role counts ("" , 0, false, an object), exactly like '
    'bridge-page-read.mjs isPageCollaborator (role != null). '
    'Updated synchronously by ai_sync_page_acl trigger.';

COMMENT ON COLUMN public.ai_chunks.visibility IS
    'The page visibility, NORMALIZED (ai_page_visibility): private, shared or '
    'public — never NULL, never an unknown value. The indexer must store the '
    'same normalized value as the ai_sync_page_acl trigger.';

-- -----------------------------------------------------------------------------
-- 2. ai_index_queue — change-capture queue, coalesced to one row per page
-- -----------------------------------------------------------------------------
-- priority is the LANE of the row: 0 is an edit a person just made, 1 is bulk
-- work (the initial backfill, a re-embed after a model swap). The worker
-- claims the edits first (order by priority, dirty_at), so a person never
-- waits behind a whole workspace.
CREATE TABLE IF NOT EXISTS public.ai_index_queue (
    page_id     UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    priority    SMALLINT NOT NULL DEFAULT 0,
    dirty_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    attempts    INT NOT NULL DEFAULT 0,
    last_error  TEXT
);

-- A queue that was created before the lanes existed gets the column: the rows
-- that are already there are edits (0) until a bulk statement says otherwise.
ALTER TABLE public.ai_index_queue
    ADD COLUMN IF NOT EXISTS priority SMALLINT NOT NULL DEFAULT 0;

-- The claim reads the lanes first, then the age of the row. The index on
-- (dirty_at) alone is replaced by this one.
DROP INDEX IF EXISTS public.ai_index_queue_dirty_idx;
CREATE INDEX IF NOT EXISTS ai_index_queue_priority_dirty_idx
    ON public.ai_index_queue (priority, dirty_at);

COMMENT ON TABLE public.ai_index_queue IS
    'Pages that need (re)indexing. One row per page — INSERT ... ON CONFLICT '
    'coalesces rapid edits. priority is the lane: 0 an edit of a person, 1 bulk '
    'work (backfill, re-embed). The worker picks up by (priority, dirty_at), '
    'resets attempts on re-queue, deletes row on success.';

COMMENT ON COLUMN public.ai_index_queue.priority IS
    'The lane of the row: 0 (default) an edit a person just made, 1 bulk work '
    '(the initial backfill, a re-embed after a model swap). An edit PROMOTES a '
    'queued bulk row to 0; a bulk enqueue never demotes an edit.';

-- -----------------------------------------------------------------------------
-- 3. Helper: extract collaborator UUIDs from the collaborators JSONB
-- -----------------------------------------------------------------------------
-- IMMUTABLE so it can be used in trigger bodies without volatility concerns.
-- Ignores malformed entries (null, non-object, missing userId, non-uuid userId,
-- missing role, JSON-null role) instead of failing the page write — matches
-- bridge-page-read.mjs isPageCollaborator which silently skips bad entries.
--
-- The rule is the BRIDGE's rule, rule for rule:
--   - a non-array collaborators (object, scalar, null) is an empty list, like
--     the bridge's `Array.isArray(row?.collaborators) ? row.collaborators : []`.
--     jsonb_array_elements on a non-array RAISES, and a raised trigger kills
--     the page write;
--   - an entry counts when it is an object, its 'role' key exists with a
--     non-null JSON value (ANY non-null value counts — "", 0, false, an
--     object), and its 'userId' is the caller's id. A missing role or a JSON
--     null role does NOT count: the bridge's `entry.role != null` is false for
--     undefined and for null. A role that is not a non-empty STRING would
--     hide a page the bridge lets the user read;
--   - user ids are uuids, so a non-uuid userId string can never equal one:
--     the uuid shape test IS the id test (uuids are case-insensitive here).

CREATE OR REPLACE FUNCTION public.ai_collaborator_ids(collaborators JSONB)
RETURNS UUID[]
LANGUAGE SQL
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT COALESCE(ARRAY_AGG(DISTINCT user_id), '{}'::UUID[])
    FROM (
        SELECT (entry->>'userId')::UUID AS user_id
        FROM JSONB_ARRAY_ELEMENTS(
                 CASE WHEN jsonb_typeof(collaborators) = 'array'
                      THEN collaborators
                      ELSE '[]'::JSONB
                 END) AS entry
        WHERE entry IS NOT NULL
          AND jsonb_typeof(entry) = 'object'
          AND entry ? 'userId'
          -- user ids are uuids: a non-uuid string can never equal a user id
          AND entry->>'userId' ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
          AND entry ? 'role'
          AND jsonb_typeof(entry->'role') <> 'null'
    ) AS ids;
$$;

COMMENT ON FUNCTION public.ai_collaborator_ids(JSONB) IS
    'Extracts UUID[] of collaborator user_ids whose entry has a non-null role '
    '(ANY non-null role counts, like the bridge''s role != null). A non-array '
    'collaborators is an empty list. Silently skips malformed entries '
    '(matches bridge-page-read.mjs isPageCollaborator).';

-- -----------------------------------------------------------------------------
-- 3b. Helper: normalize a page visibility the way the bridge does
-- -----------------------------------------------------------------------------
-- bridge-page-read.mjs pageVisibility(): anything that is not one of
-- {private, shared, public} — NULL included — is 'private'. The chunks store
-- the NORMALIZED value, so the pre-filter and the bridge can never disagree
-- about the same page. The indexer MUST normalize the same way when it
-- writes a chunk (see ai_sync_page_acl below).

CREATE OR REPLACE FUNCTION public.ai_page_visibility(visibility TEXT)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN visibility IN ('private', 'shared', 'public') THEN visibility
        ELSE 'private'
    END;
$$;

COMMENT ON FUNCTION public.ai_page_visibility(TEXT) IS
    'Normalizes a page visibility like bridge-page-read.mjs pageVisibility(): '
    'anything that is not private/shared/public — NULL included — is ''private''.';

-- -----------------------------------------------------------------------------
-- 4. Trigger: enqueue page for (re)indexing on content/title/workspace/archive changes
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_enqueue_page()
RETURNS TRIGGER
LANGUAGE PLPGSQL
AS $$
BEGIN
    -- Coalesce: one queue row per page. Reset attempts/error on re-queue.
    -- An EDIT is lane 0, and it PROMOTES a row that is waiting in the bulk
    -- lane: least(existing, new) is 0 whatever the row was. A person never
    -- waits behind a backfill.
    INSERT INTO public.ai_index_queue (page_id, workspace_id, priority, dirty_at, attempts, last_error)
    VALUES (NEW.id, NEW.workspace_id, 0, NOW(), 0, NULL)
    ON CONFLICT (page_id) DO UPDATE SET
        dirty_at = NOW(),
        workspace_id = EXCLUDED.workspace_id,
        priority = LEAST(public.ai_index_queue.priority, EXCLUDED.priority),
        attempts = 0,
        last_error = NULL;

    -- Notify the worker (LISTEN/NOTIFY) so it can pick up immediately.
    PERFORM PG_NOTIFY('ai_index', NEW.ID::TEXT);

    RETURN NEW;
END;
$$;

-- AFTER INSERT: new page needs indexing
DROP TRIGGER IF EXISTS ai_enqueue_page_ins ON public.osionos_pages;
CREATE TRIGGER ai_enqueue_page_ins
    AFTER INSERT ON public.osionos_pages
    FOR EACH ROW EXECUTE FUNCTION public.ai_enqueue_page();

-- AFTER UPDATE OF title, content, workspace_id, archived_at: only when those
-- columns actually change. archived_at is in the list because archiving a
-- page must reach the index too: the chunks of an archived page stay in the
-- index until the worker deletes them, so without this an archived page would
-- keep answering searches until some other edit re-queued it. Un-archiving
-- re-queues it, and the worker re-indexes it.
DROP TRIGGER IF EXISTS ai_enqueue_page_upd ON public.osionos_pages;
CREATE TRIGGER ai_enqueue_page_upd
    AFTER UPDATE OF title, content, workspace_id, archived_at ON public.osionos_pages
    FOR EACH ROW
    WHEN (OLD.title IS DISTINCT FROM NEW.title
       OR OLD.content IS DISTINCT FROM NEW.content
       OR OLD.workspace_id IS DISTINCT FROM NEW.workspace_id
       OR OLD.archived_at IS DISTINCT FROM NEW.archived_at)
    EXECUTE FUNCTION public.ai_enqueue_page();

COMMENT ON FUNCTION public.ai_enqueue_page() IS
    'Queues a page for (re)indexing. Coalesces rapid edits to one row. '
    'Always lane 0 (an edit of a person), and it PROMOTES a row that waits in '
    'the bulk lane. Notifies worker via pg_notify(''ai_index'', page_id). '
    'Fires on INSERT and on UPDATE of title/content/workspace_id/archived_at '
    'when changed. Archived pages are queued too (the worker deletes their '
    'chunks); un-archiving re-indexes them.';

-- -----------------------------------------------------------------------------
-- 5. Trigger: synchronous ACL sync on visibility/collaborators/owner/workspace
-- -----------------------------------------------------------------------------
-- The chunks carry COPIES of the page's ACL fields. visibility is stored
-- NORMALIZED (public.ai_page_visibility — the bridge's pageVisibility(), so
-- NULL or any unknown value becomes 'private'). The INDEXER MUST store the
-- same normalized value when it writes a chunk: a raw visibility would make
-- the pre-filter and the bridge disagree about the same page.

CREATE OR REPLACE FUNCTION public.ai_sync_page_acl()
RETURNS TRIGGER
LANGUAGE PLPGSQL
AS $$
BEGIN
    -- The page moved to another workspace: its chunks are still filed under
    -- the OLD workspace, where a member of that workspace alone would match
    -- them in the pre-filter. The worker only re-files them on its next tick
    -- (up to 10 s later), so drop them HERE, in this same transaction. The
    -- enqueue trigger has already re-queued the page under its new
    -- workspace, so the worker re-creates the chunks there.
    IF OLD.workspace_id IS DISTINCT FROM NEW.workspace_id THEN
        DELETE FROM public.ai_chunks
        WHERE workspace_id = OLD.workspace_id
          AND source_kind = 'page'
          AND source_id = NEW.id;
    END IF;

    UPDATE public.ai_chunks
    SET visibility = PUBLIC.AI_PAGE_VISIBILITY(NEW.visibility),
        owner_id = NEW.owner_id,
        collaborator_ids = PUBLIC.AI_COLLABORATOR_IDS(NEW.collaborators),
        updated_at = NOW()
    WHERE workspace_id = NEW.workspace_id
      AND source_kind = 'page'
      AND source_id = NEW.id;

    RETURN NEW;
END;
$$;

-- AFTER UPDATE OF visibility, collaborators, owner_id, workspace_id: only when
-- those change
DROP TRIGGER IF EXISTS ai_sync_page_acl_trg ON public.osionos_pages;
CREATE TRIGGER ai_sync_page_acl_trg
    AFTER UPDATE OF visibility, collaborators, owner_id, workspace_id ON public.osionos_pages
    FOR EACH ROW
    WHEN (OLD.visibility IS DISTINCT FROM NEW.visibility
       OR OLD.collaborators IS DISTINCT FROM NEW.collaborators
       OR OLD.owner_id IS DISTINCT FROM NEW.owner_id
       OR OLD.workspace_id IS DISTINCT FROM NEW.workspace_id)
    EXECUTE FUNCTION public.ai_sync_page_acl();

COMMENT ON FUNCTION public.ai_sync_page_acl() IS
    'Synchronously updates denormalized ACL columns in ai_chunks when a page''s '
    'visibility, collaborators, owner or workspace changes. Runs in the SAME '
    'transaction as the page write — a page made private can NEVER be '
    'retrieved from a stale copy. A page moved to another workspace loses its '
    'chunks from the old workspace in that same transaction. visibility is '
    'stored normalized (ai_page_visibility); the indexer must do the same. '
    'Uses ai_collaborator_ids() which ignores malformed entries.';

-- -----------------------------------------------------------------------------
-- 6. Trigger: delete chunks + queue row on page DELETE
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_delete_page_chunks()
RETURNS TRIGGER
LANGUAGE PLPGSQL
AS $$
BEGIN
    DELETE FROM public.ai_chunks
    WHERE workspace_id = OLD.workspace_id
      AND source_kind = 'page'
      AND source_id = OLD.id;

    DELETE FROM public.ai_index_queue WHERE page_id = OLD.id;

    RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS ai_delete_page_chunks_trg ON public.osionos_pages;
CREATE TRIGGER ai_delete_page_chunks_trg
    AFTER DELETE ON public.osionos_pages
    FOR EACH ROW EXECUTE FUNCTION public.ai_delete_page_chunks();

COMMENT ON FUNCTION public.ai_delete_page_chunks() IS
    'Removes a page''s chunks and its queue row on DELETE.';

-- -----------------------------------------------------------------------------
-- 7. Backfill: queue all non-archived pages for initial indexing
-- -----------------------------------------------------------------------------
-- Idempotent: ON CONFLICT DO NOTHING (queue has PK on page_id).
-- The backfill is BULK work: the rows it inserts are lane 1, so the edits of
-- a person (lane 0) are claimed first. A page that is already queued as an
-- edit keeps its lane: ON CONFLICT DO NOTHING never demotes it.
INSERT INTO public.ai_index_queue (page_id, workspace_id, priority)
SELECT id, workspace_id, 1
FROM public.osionos_pages
WHERE archived_at IS NULL
ON CONFLICT (page_id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 7b. Re-embed after a model swap: the whole index is bulk again
-- -----------------------------------------------------------------------------
-- The chunks carry the model that made them, so a new model means every chunk
-- has to be embedded again. The pages are queued as BULK (lane 1): a person
-- must not wait behind a whole workspace.
--
-- It is NOT part of the migration: it is run by hand, once, when the model
-- changes — the migration is applied to a live database, and re-queuing
-- everything on every apply would re-index the world.
--
--   INSERT INTO public.ai_index_queue (page_id, workspace_id, priority)
--   SELECT id, workspace_id, 1
--   FROM public.osionos_pages
--   WHERE archived_at IS NULL
--   ON CONFLICT (page_id) DO UPDATE SET
--       dirty_at = NOW(),
--       priority = LEAST(public.ai_index_queue.priority, 1),
--       attempts = 0,
--       last_error = NULL;
--
-- The same rule as the trigger: least(existing, 1) keeps an edit in lane 0.

-- -----------------------------------------------------------------------------
-- 8. RLS: service_role only (exactly like osionos-ai-migration.sql)
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_chunks       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_index_queue  ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_chunks_service_role_all       ON public.ai_chunks;
CREATE POLICY ai_chunks_service_role_all
    ON public.ai_chunks FOR ALL
    TO service_role USING (TRUE) WITH CHECK (TRUE);

DROP POLICY IF EXISTS ai_index_queue_service_role_all  ON public.ai_index_queue;
CREATE POLICY ai_index_queue_service_role_all
    ON public.ai_index_queue FOR ALL
    TO service_role USING (TRUE) WITH CHECK (TRUE);

GRANT ALL ON public.ai_chunks       TO service_role;
GRANT ALL ON public.ai_index_queue  TO service_role;

-- ai_* tables are outside the osionos_* catalog pass (see osionos-ai-migration.sql
-- header): close PostgREST's anon/authenticated roles here, not pattern-matched elsewhere.
REVOKE ALL ON public.ai_chunks       FROM PUBLIC, ANON, AUTHENTICATED;
REVOKE ALL ON public.ai_index_queue  FROM PUBLIC, ANON, AUTHENTICATED;

-- -----------------------------------------------------------------------------
-- 9. Reload PostgREST schema cache
-- -----------------------------------------------------------------------------
NOTIFY PGRST, 'reload schema';