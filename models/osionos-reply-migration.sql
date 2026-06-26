-- Reply-to (quote) support for the osionos messenger.
-- A message may point at an earlier message in the same channel; the quoted
-- snippet is resolved at read time (no denormalized copy). ON DELETE SET NULL so
-- deleting the original just drops the quote, never the reply.
ALTER TABLE public.osionos_messages
  ADD COLUMN IF NOT EXISTS reply_to_id uuid REFERENCES public.osionos_messages(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS osionos_messages_reply_to_idx
  ON public.osionos_messages(reply_to_id);

NOTIFY pgrst, 'reload schema';
