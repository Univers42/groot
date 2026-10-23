-- Knowledge packs: a curated, tenant-free set of documents, indexed once in a
-- dedicated system workspace and retrieved next to the workspace of an agent
-- (P5c; conditions C34, C38, C43, C45).
--
-- What this file adds, and what it does not:
--   - `ai_packs` is the pack: the slug an agent names in its knowledge list, a
--     title, a description and a status. `retired` is an operator UPDATE: a
--     retired pack is not reachable by the retrieval, and its rows are kept;
--   - `ai_pack_docs` is one source file of a pack: its repo-relative path and
--     the sha256 of its bytes. The import CLI re-embeds a document only when
--     the hash moved, so a re-run with no change calls no embedder;
--   - `ai_chunks.source_kind` admits 'pack', so the chunks of a pack live in
--     the SAME index as the pages, in the system workspace (D20: one index,
--     many scopes);
--   - the AFTER DELETE trigger takes the chunks of a document with the
--     document, so the delete of a pack cascades all the way down.
--
-- The pack text is quoted data, never instructions (C38): the retrieval puts
-- it inside a <source collection="pack"> block, and the base prompt already
-- names <source> as data. The chunk rows carry no ACL: a pack is tenant-free,
-- and the only gates are the pack status and the list an agent carries (C45).
--
-- Idempotent: CREATE TABLE IF NOT EXISTS, a trigger that is dropped and
-- recreated, a policy that is dropped and recreated, and a DO block that reads
-- the live CHECK and does NOTHING when it already admits 'pack' — the replay
-- of this file takes no lock on ai_chunks. Replay-proved by the service gate,
-- which applies every AI migration twice.
--
-- Ordering: after osionos-ai-rag-migration.sql (ai_chunks and its partitions).

SET lock_timeout = '5s';

-- -----------------------------------------------------------------------------
-- 1. ai_packs — the curated pack
-- -----------------------------------------------------------------------------
-- The slug is the wire name: the agent's `knowledge` list and the retrieval
-- filter both carry it, so the regex is the contract and the UNIQUE is the
-- identity. The title and the description are display text, bounded because
-- they end up in a citation frame.
CREATE TABLE IF NOT EXISTS public.ai_packs (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug        TEXT NOT NULL,
    title       TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    status      TEXT NOT NULL DEFAULT 'published',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ai_packs_slug_key UNIQUE (slug),
    CONSTRAINT ai_packs_slug_check
        CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
    CONSTRAINT ai_packs_title_check
        CHECK (char_length(title) BETWEEN 1 AND 120),
    CONSTRAINT ai_packs_description_check
        CHECK (char_length(description) <= 500),
    CONSTRAINT ai_packs_status_check
        CHECK (status IN ('published', 'retired'))
);

COMMENT ON TABLE public.ai_packs IS
    'A curated, tenant-free knowledge pack (P5c). Indexed once in the system '
    'workspace (OSIONOS_AI_SYSTEM_WORKSPACE_ID); an agent lists the slugs it '
    'may read. Retiring is an operator UPDATE to status = ''retired''.';

COMMENT ON COLUMN public.ai_packs.slug IS
    'The wire name of the pack: the agent knowledge list and the retrieval '
    'filter carry it. Lower-case, 2 to 63 characters, digits and dashes.';

COMMENT ON COLUMN public.ai_packs.status IS
    '''published'' answers the retrieval; ''retired'' keeps the rows and takes '
    'the pack out of every answer.';

-- -----------------------------------------------------------------------------
-- 2. ai_pack_docs — one source file of a pack
-- -----------------------------------------------------------------------------
-- `path` is relative to the osionos repository root, and the pack COPIES no
-- document: the repo is the one source of truth. The sha256 is the hex of the
-- file, and the import CLI compares it before it embeds anything.
CREATE TABLE IF NOT EXISTS public.ai_pack_docs (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pack_id        UUID NOT NULL REFERENCES public.ai_packs (id) ON DELETE CASCADE,
    path           TEXT NOT NULL,
    title          TEXT NOT NULL,
    content_sha256 TEXT NOT NULL,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ai_pack_docs_pack_path_key UNIQUE (pack_id, path)
);

COMMENT ON TABLE public.ai_pack_docs IS
    'One source file of a knowledge pack: its repo-relative path, its title and '
    'the sha256 of its bytes. The import re-embeds a document only when the hash '
    'moved; the delete of a pack cascades to the documents and to their chunks.';

-- -----------------------------------------------------------------------------
-- 3. The chunks go with their document
-- -----------------------------------------------------------------------------
-- A document is not a page: it has no row in osionos_pages and no RAG trigger
-- to take its chunks. This AFTER DELETE trigger is that trigger, and it runs on
-- the delete of a pack too, through the ON DELETE CASCADE of ai_pack_docs.
CREATE OR REPLACE FUNCTION public.ai_pack_docs_drop_chunks()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM public.ai_chunks
     WHERE source_kind = 'pack' AND source_id = OLD.id;
    RETURN OLD;
END;
$$;

COMMENT ON FUNCTION public.ai_pack_docs_drop_chunks() IS
    'Takes the pack chunks of a document with the document row. The delete of a '
    'pack cascades to its documents, and this trigger carries the cascade to the '
    'chunks (there is no osionos_pages row to trigger it).';

DROP TRIGGER IF EXISTS ai_pack_docs_drop_chunks ON public.ai_pack_docs;
CREATE TRIGGER ai_pack_docs_drop_chunks
    AFTER DELETE ON public.ai_pack_docs
    FOR EACH ROW
    EXECUTE FUNCTION public.ai_pack_docs_drop_chunks();

-- -----------------------------------------------------------------------------
-- 4. ai_chunks.source_kind admits 'pack'
-- -----------------------------------------------------------------------------
-- The constraint was declared inline by osionos-ai-rag-migration.sql, so its
-- name is the one Postgres chose. Join the real name into the block rather than
-- assume it: on a fresh database the server's auto-name is stable, but a
-- deployment that renamed it (or a future file that adds another CHECK on the
-- column) must still converge.
--
-- The second run does NOTHING: the definition already carries 'pack', so no
-- table lock is taken. On the first run, DROP/ADD takes ACCESS EXCLUSIVE and
-- this DO block holds that lock until the block commits. VALIDATE therefore
-- scans every partition while reads and writes remain blocked by that lock.
-- NOT VALID avoids scanning during ADD, but it does not make the validation
-- safe for online use in this transaction-wrapped migration. Apply this first
-- run in a maintenance window on a large ai_chunks table.
DO $$
DECLARE
    old_name   TEXT;
    old_def    TEXT;
    new_name   TEXT := 'ai_chunks_source_kind_check';
    not_valid  BOOLEAN := FALSE;
    wanted     TEXT := 'CHECK (source_kind IN (''page'', ''db_row'', ''pack''))';
BEGIN
    SELECT c.conname, pg_get_constraintdef(c.oid)
      INTO old_name, old_def
      FROM pg_constraint c
     WHERE c.conrelid = 'public.ai_chunks'::regclass
       AND c.contype = 'c'
       AND pg_get_constraintdef(c.oid) LIKE '%source_kind%'
     ORDER BY c.conname
     LIMIT 1;

    -- Already widened (the replay): the definition names 'pack'. No lock.
    IF old_name IS NOT NULL AND old_def LIKE '%''pack''%' THEN
        RETURN;
    END IF;

    IF old_name IS NOT NULL THEN
        EXECUTE format('ALTER TABLE public.ai_chunks DROP CONSTRAINT %I', old_name);
    END IF;

    -- Another constraint may already hold the canonical name on a converged
    -- database; the DROP above took the old one, so a name collision here means
    -- a different CHECK and must not be overwritten.
    IF EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'public.ai_chunks'::regclass AND conname = new_name
    ) THEN
        new_name := 'ai_chunks_source_kind_pack_check';
    END IF;

    BEGIN
        EXECUTE format(
            'ALTER TABLE public.ai_chunks ADD CONSTRAINT %I %s NOT VALID',
            new_name, wanted
        );
        not_valid := TRUE;
        RAISE NOTICE 'osionos-ai-packs: ai_chunks source_kind CHECK added NOT VALID';
    EXCEPTION WHEN feature_not_supported THEN
        -- Caveat: PostgreSQL refused NOT VALID on this partitioned table, so
        -- this plain ADD scans every partition of ai_chunks once, under the
        -- ACCESS EXCLUSIVE lock of the ADD (reads are blocked while it runs).
        EXECUTE format(
            'ALTER TABLE public.ai_chunks ADD CONSTRAINT %I %s',
            new_name, wanted
        );
        RAISE NOTICE 'osionos-ai-packs: NOT VALID refused on ai_chunks, plain ADD used';
    END;

    IF not_valid THEN
        EXECUTE format('ALTER TABLE public.ai_chunks VALIDATE CONSTRAINT %I', new_name);
    END IF;
END
$$;

-- -----------------------------------------------------------------------------
-- 5. RLS: service_role only (exactly like the neighbouring ai_* tables)
-- -----------------------------------------------------------------------------
-- The packs are not PostgREST data: no workspace, no user, no policy for
-- anon/authenticated. The service reads them through service_role, and the
-- import CLI runs as the one that applies the migrations.
ALTER TABLE public.ai_packs      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_pack_docs  ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_packs_service_role_all ON public.ai_packs;
CREATE POLICY ai_packs_service_role_all
    ON public.ai_packs FOR ALL
    TO service_role USING (TRUE) WITH CHECK (TRUE);

DROP POLICY IF EXISTS ai_pack_docs_service_role_all ON public.ai_pack_docs;
CREATE POLICY ai_pack_docs_service_role_all
    ON public.ai_pack_docs FOR ALL
    TO service_role USING (TRUE) WITH CHECK (TRUE);

GRANT ALL ON public.ai_packs      TO service_role;
GRANT ALL ON public.ai_pack_docs  TO service_role;

-- ai_* tables are outside the osionos_* catalog pass: close PostgREST's roles
-- here, not pattern-matched elsewhere.
REVOKE ALL ON public.ai_packs      FROM PUBLIC, ANON, AUTHENTICATED;
REVOKE ALL ON public.ai_pack_docs  FROM PUBLIC, ANON, AUTHENTICATED;

-- The trigger function is called by the table's triggers, never by a caller:
-- no PostgREST role may execute it directly.
REVOKE ALL ON FUNCTION public.ai_pack_docs_drop_chunks() FROM PUBLIC, ANON, AUTHENTICATED;
GRANT EXECUTE ON FUNCTION public.ai_pack_docs_drop_chunks() TO service_role;

-- -----------------------------------------------------------------------------
-- 6. Reload the PostgREST schema cache
-- -----------------------------------------------------------------------------
RESET lock_timeout;

NOTIFY pgrst, 'reload schema';
