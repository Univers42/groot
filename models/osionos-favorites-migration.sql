-- osionos favorites + persisted sidebar order. Same discipline as
-- osionos-engagement-migration.sql: idempotent DDL, RLS on, own-row SELECT +
-- service_role FOR ALL (the bridge scopes every query by the verified session
-- user; RLS is defence in depth).

-- Persisted sibling order for the sidebar tree. The client (reorderSibling) and
-- the bridge (sort_order mapping on read/create/update) were already wired; this
-- column completes the path so order survives a cache clear / new machine.
-- NOTE: already present on the drifted dev DB — IF NOT EXISTS makes it a no-op
-- there and adds it on a fresh clone.
ALTER TABLE public.osionos_pages
  ADD COLUMN IF NOT EXISTS sort_order DOUBLE PRECISION;

-- ── Favorites: per (user, page) star ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.osionos_page_favorites (
  user_id    UUID NOT NULL,
  page_id    UUID NOT NULL REFERENCES public.osionos_pages(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, page_id)
);

ALTER TABLE public.osionos_page_favorites ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_page_favorites_select_own ON public.osionos_page_favorites;
CREATE POLICY osionos_page_favorites_select_own ON public.osionos_page_favorites
  FOR SELECT TO authenticated USING (user_id = auth.uid());
DROP POLICY IF EXISTS osionos_page_favorites_service_role_all ON public.osionos_page_favorites;
CREATE POLICY osionos_page_favorites_service_role_all ON public.osionos_page_favorites
  FOR ALL TO service_role USING (true) WITH CHECK (true);
GRANT SELECT ON public.osionos_page_favorites TO authenticated;
GRANT ALL    ON public.osionos_page_favorites TO service_role;

NOTIFY pgrst, 'reload schema';
