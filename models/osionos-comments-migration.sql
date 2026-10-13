-- Block-anchored page comments. Reads/writes are bridge-mediated (service_role
-- scopes by verified page access). Same discipline as
-- osionos-engagement-migration.sql. Idempotent.
--
-- The bridge (service_role) is the only reader and writer; nobody else gets a grant.

CREATE TABLE IF NOT EXISTS public.osionos_page_comments (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  page_id     UUID NOT NULL REFERENCES public.osionos_pages(id) ON DELETE CASCADE,
  block_id    TEXT,
  author_id   UUID NOT NULL,
  content     TEXT NOT NULL,
  resolved_at TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS osionos_page_comments_page_idx
  ON public.osionos_page_comments (page_id, created_at);

-- Widen the notification type CHECK (cumulative list) for comment notifications.
DO $$ BEGIN
  ALTER TABLE public.osionos_notifications DROP CONSTRAINT IF EXISTS osionos_notifications_type_check;
  ALTER TABLE public.osionos_notifications ADD CONSTRAINT osionos_notifications_type_check
    CHECK (type IN ('mention','dm','reply','reaction','connection','system',
                    'feed_reaction','feed_comment','feed_share','task_due','page_comment'));
END $$;

ALTER TABLE public.osionos_page_comments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_page_comments_select_own ON public.osionos_page_comments;
DROP POLICY IF EXISTS osionos_page_comments_service_role_all ON public.osionos_page_comments;
CREATE POLICY osionos_page_comments_service_role_all ON public.osionos_page_comments
  FOR ALL TO service_role USING (true) WITH CHECK (true);
GRANT ALL    ON public.osionos_page_comments TO service_role;

NOTIFY pgrst, 'reload schema';
