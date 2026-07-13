-- Public page publishing: an explicit SNAPSHOT of a page (content copied at
-- publish time, never a live-table read). The unauthenticated public GET reads
-- ONLY this table. service_role-only (the bridge mediates every access); no
-- authenticated/anon grant. Idempotent. Feature is flag-gated OFF at the bridge
-- (OSIONOS_PUBLISH_ENABLED) — this table is inert until then.

CREATE TABLE IF NOT EXISTS public.osionos_published_pages (
  token        TEXT PRIMARY KEY DEFAULT encode(gen_random_bytes(16), 'hex'),
  page_id      UUID NOT NULL UNIQUE REFERENCES public.osionos_pages(id) ON DELETE CASCADE,
  owner_id     UUID NOT NULL,
  title        TEXT NOT NULL,
  icon         TEXT,
  content      JSONB NOT NULL,
  published_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.osionos_published_pages ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_published_pages_service_role_all ON public.osionos_published_pages;
CREATE POLICY osionos_published_pages_service_role_all ON public.osionos_published_pages
  FOR ALL TO service_role USING (true) WITH CHECK (true);
GRANT ALL ON public.osionos_published_pages TO service_role;

NOTIFY pgrst, 'reload schema';
