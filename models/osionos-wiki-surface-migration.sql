-- ============================================================================
-- osionos wikis: allow surface='wiki' on osionos_pages.
--
-- A wiki is a governed knowledge root (Notion-style): unlike a folder it
-- OPENS onto its own content (an index/dashboard page), and like a folder it
-- groups children in the sidebar. Articles inside a wiki carry governance
-- properties (owner, verification status, last-verified date, domain) in the
-- `properties` jsonb. The previous CHECK allowed ('page','agent','home',
-- 'folder'); this widens it additively — no data loss, reversible.
-- ============================================================================

ALTER TABLE public.osionos_pages DROP CONSTRAINT IF EXISTS osionos_pages_surface_check;

ALTER TABLE public.osionos_pages ADD CONSTRAINT osionos_pages_surface_check
  CHECK (surface IS NULL OR surface IN ('page', 'agent', 'home', 'folder', 'wiki'));
