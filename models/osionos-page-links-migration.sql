-- Inline page links: [[page:<uuid>]] references harvested from block content by
-- an AFTER trigger on osionos_pages, powering the editor "Linked from" backlinks
-- panel. Reuses public.osionos_page_blocks() (osionos-page-search-migration.sql).
-- target_page_id has NO foreign key on purpose — a link may point at a page that
-- is not created yet or was deleted. Idempotent.

CREATE TABLE IF NOT EXISTS public.osionos_page_links (
  source_page_id UUID NOT NULL REFERENCES public.osionos_pages(id) ON DELETE CASCADE,
  target_page_id UUID NOT NULL,
  owner_id       UUID,
  workspace_id   UUID NOT NULL,
  PRIMARY KEY (source_page_id, target_page_id)
);
CREATE INDEX IF NOT EXISTS osionos_page_links_target_idx
  ON public.osionos_page_links (target_page_id);

-- Strict UUID layout in the regex → the ::uuid cast can never throw and break a
-- page save. Self-links are dropped.
CREATE OR REPLACE FUNCTION public.osionos_pages_links_sync()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM public.osionos_page_links WHERE source_page_id = NEW.id;
  INSERT INTO public.osionos_page_links (source_page_id, target_page_id, owner_id, workspace_id)
  SELECT DISTINCT NEW.id, (m[1])::uuid, NEW.owner_id, NEW.workspace_id
  FROM public.osionos_page_blocks(NEW.content) AS b,
       LATERAL regexp_matches(
         coalesce(b ->> 'content', ''),
         '\[\[page:([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\]\]',
         'g') AS m
  WHERE (m[1])::uuid <> NEW.id
  ON CONFLICT (source_page_id, target_page_id) DO NOTHING;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS osionos_pages_links_trg ON public.osionos_pages;
CREATE TRIGGER osionos_pages_links_trg
  AFTER INSERT OR UPDATE OF content ON public.osionos_pages
  FOR EACH ROW EXECUTE FUNCTION public.osionos_pages_links_sync();

-- One-time backfill for existing pages.
INSERT INTO public.osionos_page_links (source_page_id, target_page_id, owner_id, workspace_id)
SELECT DISTINCT p.id, (m[1])::uuid, p.owner_id, p.workspace_id
FROM public.osionos_pages p,
     public.osionos_page_blocks(p.content) AS b,
     LATERAL regexp_matches(
       coalesce(b ->> 'content', ''),
       '\[\[page:([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\]\]',
       'g') AS m
WHERE (m[1])::uuid <> p.id
ON CONFLICT (source_page_id, target_page_id) DO NOTHING;

ALTER TABLE public.osionos_page_links ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_page_links_select_own ON public.osionos_page_links;
CREATE POLICY osionos_page_links_select_own ON public.osionos_page_links
  FOR SELECT TO authenticated USING (owner_id = auth.uid());
DROP POLICY IF EXISTS osionos_page_links_service_role_all ON public.osionos_page_links;
CREATE POLICY osionos_page_links_service_role_all ON public.osionos_page_links
  FOR ALL TO service_role USING (true) WITH CHECK (true);
GRANT SELECT ON public.osionos_page_links TO authenticated;
GRANT ALL    ON public.osionos_page_links TO service_role;

NOTIFY pgrst, 'reload schema';
