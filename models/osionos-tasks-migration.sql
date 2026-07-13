-- Task index for osionos to_do blocks: a projection table maintained by an AFTER
-- trigger on osionos_pages, so it stays correct across EVERY write path (bridge,
-- electron, seeders). Reuses public.osionos_page_blocks() from
-- osionos-page-search-migration.sql (the shared JSONB walker). Powers the
-- "My Tasks" view and the due-date reminder scan. Idempotent.

-- Never let a hand-crafted dueAt string break a page save: parse-or-NULL.
CREATE OR REPLACE FUNCTION public.osionos_safe_ts(t text)
RETURNS timestamptz LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN nullif(t, '')::timestamptz;
EXCEPTION WHEN others THEN
  RETURN NULL;
END;
$$;

CREATE TABLE IF NOT EXISTS public.osionos_tasks (
  page_id      UUID NOT NULL REFERENCES public.osionos_pages(id) ON DELETE CASCADE,
  block_id     TEXT NOT NULL,
  workspace_id UUID NOT NULL,
  owner_id     UUID,
  content      TEXT NOT NULL DEFAULT '',
  checked      BOOLEAN NOT NULL DEFAULT false,
  due_at       TIMESTAMPTZ,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (page_id, block_id)
);
-- Reminder scan + My Tasks "due" queries: open tasks by owner, ordered by due date.
CREATE INDEX IF NOT EXISTS osionos_tasks_due_idx
  ON public.osionos_tasks (owner_id, due_at) WHERE NOT checked;

-- Rebuild a page's tasks from its block tree on every content write.
CREATE OR REPLACE FUNCTION public.osionos_pages_tasks_sync()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM public.osionos_tasks WHERE page_id = NEW.id;
  INSERT INTO public.osionos_tasks (page_id, block_id, workspace_id, owner_id, content, checked, due_at, updated_at)
  SELECT NEW.id, b ->> 'id', NEW.workspace_id, NEW.owner_id,
         coalesce(b ->> 'content', ''),
         CASE WHEN b ->> 'checked' IN ('true', 'false') THEN (b ->> 'checked')::boolean ELSE false END,
         public.osionos_safe_ts(b ->> 'dueAt'), now()
  FROM public.osionos_page_blocks(NEW.content) AS b
  WHERE b ->> 'type' = 'to_do' AND b ? 'id';
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS osionos_pages_tasks_trg ON public.osionos_pages;
CREATE TRIGGER osionos_pages_tasks_trg
  AFTER INSERT OR UPDATE OF content ON public.osionos_pages
  FOR EACH ROW EXECUTE FUNCTION public.osionos_pages_tasks_sync();

-- One-time backfill for pages that already exist.
INSERT INTO public.osionos_tasks (page_id, block_id, workspace_id, owner_id, content, checked, due_at, updated_at)
SELECT p.id, b ->> 'id', p.workspace_id, p.owner_id,
       coalesce(b ->> 'content', ''),
       CASE WHEN b ->> 'checked' IN ('true', 'false') THEN (b ->> 'checked')::boolean ELSE false END,
       public.osionos_safe_ts(b ->> 'dueAt'), now()
FROM public.osionos_pages p, public.osionos_page_blocks(p.content) AS b
WHERE b ->> 'type' = 'to_do' AND b ? 'id'
ON CONFLICT (page_id, block_id) DO NOTHING;

-- Widen the notification type CHECK (cumulative list) for due reminders.
DO $$ BEGIN
  ALTER TABLE public.osionos_notifications DROP CONSTRAINT IF EXISTS osionos_notifications_type_check;
  ALTER TABLE public.osionos_notifications ADD CONSTRAINT osionos_notifications_type_check
    CHECK (type IN ('mention','dm','reply','reaction','connection','system',
                    'feed_reaction','feed_comment','feed_share','task_due'));
END $$;

ALTER TABLE public.osionos_tasks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_tasks_select_own ON public.osionos_tasks;
CREATE POLICY osionos_tasks_select_own ON public.osionos_tasks
  FOR SELECT TO authenticated USING (owner_id = auth.uid());
DROP POLICY IF EXISTS osionos_tasks_service_role_all ON public.osionos_tasks;
CREATE POLICY osionos_tasks_service_role_all ON public.osionos_tasks
  FOR ALL TO service_role USING (true) WITH CHECK (true);
GRANT SELECT ON public.osionos_tasks TO authenticated;
GRANT ALL    ON public.osionos_tasks TO service_role;

NOTIFY pgrst, 'reload schema';
