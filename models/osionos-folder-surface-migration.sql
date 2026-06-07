-- ============================================================================
-- osionos folders: allow surface='folder' on osionos_pages.
--
-- A folder is a page flagged surface='folder' (it groups children and never opens
-- on click). The original CHECK only allowed ('page','agent','home'), so folder
-- writes were rejected/dropped and folders never persisted server-side. This
-- widens the CHECK additively — no data loss, reversible.
-- ============================================================================

ALTER TABLE public.osionos_pages DROP CONSTRAINT IF EXISTS osionos_pages_surface_check;

ALTER TABLE public.osionos_pages ADD CONSTRAINT osionos_pages_surface_check
  CHECK (surface IS NULL OR surface IN ('page', 'agent', 'home', 'folder'));
