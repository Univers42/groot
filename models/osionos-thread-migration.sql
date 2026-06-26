-- Threads: promote single-level replies into flat (Slack-style) threads.
-- thread_root_id collapses any reply chain onto the original root; reply_count
-- is maintained by a trigger (race-free; also decrements on soft-delete).
-- reply_to_id stays as the in-thread quote. Backfills existing replies.
-- Idempotent. The trigger is scoped `OF deleted_at` so the reply_count UPDATE it
-- performs does NOT re-fire it (no recursion).

ALTER TABLE public.osionos_messages
  ADD COLUMN IF NOT EXISTS thread_root_id uuid REFERENCES public.osionos_messages(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS reply_count int NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS osionos_messages_thread_root_idx
  ON public.osionos_messages (thread_root_id, created_at);

-- Backfill: existing single-level replies become flat threads.
UPDATE public.osionos_messages SET thread_root_id = reply_to_id
  WHERE reply_to_id IS NOT NULL AND thread_root_id IS NULL;

-- Recompute reply_count on roots (idempotent — only writes where it differs).
UPDATE public.osionos_messages r SET reply_count = sub.c
  FROM (SELECT thread_root_id AS id, count(*) AS c FROM public.osionos_messages
        WHERE thread_root_id IS NOT NULL AND deleted_at IS NULL GROUP BY thread_root_id) sub
  WHERE r.id = sub.id AND r.reply_count <> sub.c;

CREATE OR REPLACE FUNCTION public.osionos_thread_count() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' AND NEW.thread_root_id IS NOT NULL THEN
    UPDATE public.osionos_messages SET reply_count = reply_count + 1 WHERE id = NEW.thread_root_id;
  ELSIF TG_OP = 'UPDATE' AND NEW.thread_root_id IS NOT NULL
        AND OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
    UPDATE public.osionos_messages SET reply_count = GREATEST(reply_count - 1, 0) WHERE id = NEW.thread_root_id;
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS osionos_thread_count_trg ON public.osionos_messages;
CREATE TRIGGER osionos_thread_count_trg
  AFTER INSERT OR UPDATE OF deleted_at ON public.osionos_messages
  FOR EACH ROW EXECUTE FUNCTION public.osionos_thread_count();

NOTIFY pgrst, 'reload schema';
