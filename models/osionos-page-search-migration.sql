-- Full-text page search for the osionos editor: a generated tsvector + GIN index
-- on osionos_pages, mirroring the osionos_messages search_doc pattern
-- (osionos-message-search-migration.sql, queried via PostgREST `wfts`). Because
-- page content is a JSONB block tree (not a plain column), an IMMUTABLE walker
-- projects it to text for the generated column. Idempotent.
--
-- osionos_page_blocks() is SHARED INFRA: the tasks and page-links migrations
-- (osionos-tasks / osionos-page-links) reuse it in their AFTER triggers to walk
-- the same block tree — keep it a single source of truth.

-- Recursive block walker: every block object in a page's content, including
-- nested children. IMMUTABLE + PARALLEL SAFE so it is usable in a generated
-- column and in trigger extraction.
CREATE OR REPLACE FUNCTION public.osionos_page_blocks(doc jsonb)
RETURNS SETOF jsonb
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  WITH RECURSIVE walk(b) AS (
    SELECT jsonb_array_elements(CASE WHEN jsonb_typeof(doc) = 'array' THEN doc ELSE '[]'::jsonb END)
    UNION ALL
    SELECT jsonb_array_elements(w.b -> 'children')
    FROM walk w
    WHERE jsonb_typeof(w.b -> 'children') = 'array'
  )
  SELECT b FROM walk
$$;

-- Scalar text projection of a page's blocks (concatenated `content` strings).
CREATE OR REPLACE FUNCTION public.osionos_page_text(doc jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT coalesce(string_agg(b ->> 'content', ' '), '')
  FROM public.osionos_page_blocks(doc) AS b
  WHERE b ? 'content'
$$;

-- Title (weight A) + body text (weight B). Auto-maintained on every write;
-- ADD COLUMN backfills existing rows (STORED = table rewrite once).
ALTER TABLE public.osionos_pages
  ADD COLUMN IF NOT EXISTS search_doc tsvector
    GENERATED ALWAYS AS (
      setweight(to_tsvector('english', coalesce(title, '')), 'A')
      || setweight(to_tsvector('english', public.osionos_page_text(content)), 'B')
    ) STORED;

CREATE INDEX IF NOT EXISTS osionos_pages_search_gin
  ON public.osionos_pages USING gin (search_doc);

NOTIFY pgrst, 'reload schema';
