-- Graph vectors: ONE vector per page, written by the indexer, read at read time
-- for "related pages" and "suggested links".
--
-- G1 stores NO semantic edges. A "related" neighbour is not a stored row: it is
-- computed per viewer from these vectors, over the viewer's readable pages in
-- the source page's workspace (C102, C105). That closes the count channel (a
-- stored top-8 filtered by readability reveals how many hidden similar pages
-- exist) and the staleness channel (a new page is suggested as soon as its
-- vector is written, with no re-index of the source).
--
-- The graph VIEW's `link` edges come from the existing osionos_page_links
-- (C103): no second extractor, no stored link row. `parent`, `relation` and
-- `tag` stay live from osionos_pages, as bridge-graph.mjs already does.
--
-- Idempotent: every CREATE is IF NOT EXISTS / OR REPLACE; applied twice against
-- a throwaway pgvector 0.8.0 / PG16 container to prove it.
--
-- Partitioning is the same shape as ai_chunks (osionos-ai-rag-migration.sql):
-- the PRIMARY KEY leads with workspace_id because it is the hash partition key,
-- and a workspace move drops the old partition's row in the page write's own
-- transaction (see ai_sync_page_acl / ai_delete_page_chunks in the RAG
-- migration). The HNSW index is created on the parent, so every partition gets
-- its own child index.

CREATE EXTENSION IF NOT EXISTS vector;

-- -----------------------------------------------------------------------------
-- 1. ai_page_vectors — partitioned by workspace_id (16 hash partitions)
-- -----------------------------------------------------------------------------
-- The embedding is the L2-normalised, token-length-weighted mean of the page's
-- chunk vectors (src/indexer/page.ts). There is no ACL copy here: the read is
-- access-checked twice, once by the SQL pre-filter on the live osionos_pages row
-- and once by the bridge's canReadPageRowAsMember (C99).
CREATE TABLE IF NOT EXISTS public.ai_page_vectors (
    workspace_id    UUID NOT NULL,
    page_id         UUID NOT NULL,
    embedding       HALFVEC(384),
    embedding_model TEXT,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (workspace_id, page_id)
) PARTITION BY HASH (workspace_id);

-- 16 hash partitions (p00 .. p15)
DO $$
DECLARE
    i INT;
    part_name TEXT;
BEGIN
    FOR i IN 0..15 LOOP
        part_name := 'ai_page_vectors_p' || LPAD(i::TEXT, 2, '0');
        IF to_regclass('public.' || part_name) IS NULL THEN
            EXECUTE format('CREATE TABLE public.%I PARTITION OF public.ai_page_vectors FOR VALUES WITH (MODULUS 16, REMAINDER %s)', part_name, i);
        END IF;
        -- A partition is a table of its own: it can be read directly, and it inherits neither
        -- the parent's grants nor its RLS flag. Closed like the parent, on every replay.
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', part_name);
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', part_name);
    END LOOP;
END $$;

-- HNSW index for vector similarity (cosine), one child per partition.
CREATE INDEX IF NOT EXISTS ai_page_vectors_embedding_hnsw
    ON public.ai_page_vectors USING hnsw (embedding HALFVEC_COSINE_OPS)
    WITH (m = 16, ef_construction = 64);

-- The lifecycle delete is by page_id across every partition (a page that moved
-- workspace leaves its row behind in the old partition).
CREATE INDEX IF NOT EXISTS ai_page_vectors_page_idx
    ON public.ai_page_vectors (page_id);

COMMENT ON TABLE public.ai_page_vectors IS
    'One embedding per page (the L2-normalised, token-weighted mean of its '
    'chunks). Partitioned by workspace_id (16 ways). Read at read time for '
    'related pages and suggested links (C102/C105); no semantic edges are '
    'stored. No ACL copy: the reader joins the live osionos_pages row and '
    're-checks with bridge-page-read.mjs.';

-- -----------------------------------------------------------------------------
-- 2. The edge-read RPCs: arrays in the body, never in a URL
-- -----------------------------------------------------------------------------
-- The graph's link edges and backlinks read osionos_page_links by source/target
-- id sets. C99: "array parameters in the body (not in.(…) URLs)" — the arrays
-- ride in the POST body, so the read never builds a filter URL that Kong's 4 KB
-- header buffer would truncate. One module (scripts/bridge-graph-edges.mjs)
-- calls these two functions; the ACL decision is made on the live page rows
-- below, never on the edge row's workspace_id.
--
-- Both functions take at most 1000 ids per array (MAX_IDS_PER_CALL of
-- scripts/bridge-graph-edges.mjs, which cuts a bigger set into calls of that
-- size) and answer nothing above it. Both link arrays NULL answers nothing: it
-- would be every link of the database.

CREATE OR REPLACE FUNCTION public.osionos_bridge_graph_links(
    p_source_ids UUID[] DEFAULT NULL,
    p_target_ids UUID[] DEFAULT NULL
)
RETURNS SETOF public.osionos_page_links
LANGUAGE SQL
STABLE
AS $$
    SELECT l.*
    FROM public.osionos_page_links l
    WHERE (p_source_ids IS NOT NULL OR p_target_ids IS NOT NULL)
      AND coalesce(cardinality(p_source_ids), 0) <= 1000
      AND coalesce(cardinality(p_target_ids), 0) <= 1000
      AND (p_source_ids IS NULL OR l.source_page_id = ANY(p_source_ids))
      AND (p_target_ids IS NULL OR l.target_page_id = ANY(p_target_ids))
    ORDER BY l.source_page_id, l.target_page_id;
$$;

COMMENT ON FUNCTION public.osionos_bridge_graph_links(UUID[], UUID[]) IS
    'The inline [[page:]] link rows whose source or target is in the given id '
    'sets. The arrays ride in the body (C99); the caller checks both endpoints '
    'against the live osionos_pages rows.';

-- The page rows behind a set of ids, for the surfaces that read endpoints by id
-- (backlinks). The columns are exactly what the read rule needs; the content
-- JSONB never crosses the wire.
CREATE OR REPLACE FUNCTION public.osionos_bridge_pages_by_ids(p_ids UUID[])
RETURNS TABLE (
    id            UUID,
    workspace_id  UUID,
    owner_id      UUID,
    visibility    TEXT,
    collaborators JSONB,
    title         TEXT,
    icon          TEXT,
    archived_at   TIMESTAMPTZ
)
LANGUAGE SQL
STABLE
AS $$
    SELECT p.id, p.workspace_id, p.owner_id, p.visibility, p.collaborators, p.title, p.icon, p.archived_at
    FROM public.osionos_pages p
    WHERE coalesce(cardinality(p_ids), 0) <= 1000
      AND p.id = ANY(p_ids)
    ORDER BY p.id;
$$;

COMMENT ON FUNCTION public.osionos_bridge_pages_by_ids(UUID[]) IS
    'The live metadata rows of the given page ids, for a surface that reads '
    'endpoints by id (backlinks). No content: the read rule and the caller '
    'project what they need.';

-- -----------------------------------------------------------------------------
-- 3. RLS: service_role only
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_page_vectors ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_page_vectors_service_role_all ON public.ai_page_vectors;
CREATE POLICY ai_page_vectors_service_role_all
    ON public.ai_page_vectors FOR ALL
    TO service_role USING (TRUE) WITH CHECK (TRUE);

GRANT ALL ON public.ai_page_vectors TO service_role;
REVOKE ALL ON public.ai_page_vectors FROM PUBLIC, ANON, AUTHENTICATED;

GRANT EXECUTE ON FUNCTION public.osionos_bridge_graph_links(UUID[], UUID[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.osionos_bridge_pages_by_ids(UUID[]) TO service_role;
REVOKE ALL ON FUNCTION public.osionos_bridge_graph_links(UUID[], UUID[]) FROM PUBLIC, ANON, AUTHENTICATED;
REVOKE ALL ON FUNCTION public.osionos_bridge_pages_by_ids(UUID[]) FROM PUBLIC, ANON, AUTHENTICATED;

NOTIFY pgrst, 'reload schema';
