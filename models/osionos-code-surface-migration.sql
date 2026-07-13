-- ============================================================================
-- osionos IDE / Dev-Mode: allow surface='code' on osionos_pages.
--
-- A code file is a line-based source document (Python, C++, Go, …) rendered by
-- the CodeMirror editor instead of the block editor. It rides the EXISTING page
-- storage: `surface='code'`, title = file name (`main.py`), body stored as a
-- single `code` block in `content` — so sync/ACL/tree are all untouched. This is
-- the additive DB half: it only widens the surface CHECK, no data change.
--
-- The prior live CHECK allowed ('page','agent','home','folder','wiki','app')
-- ('app' was added by a later migration than the wiki one). This widens it
-- additively to add 'code' — no data loss, reversible (drop 'code' to revert).
-- Idempotent: safe to replay.
-- ============================================================================

ALTER TABLE public.osionos_pages DROP CONSTRAINT IF EXISTS osionos_pages_surface_check;

ALTER TABLE public.osionos_pages ADD CONSTRAINT osionos_pages_surface_check
  CHECK (surface IS NULL OR surface IN ('page', 'agent', 'home', 'folder', 'wiki', 'app', 'code'));
