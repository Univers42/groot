-- Full-text message search for the osionos messenger: a generated tsvector +
-- GIN index on osionos_messages, mirroring the directory search_doc pattern in
-- osionos-social-migration.sql (queried via PostgREST `wfts`). Membership
-- scoping is enforced by the bridge (service role constrains channel_id to the
-- caller's accessible set); the existing member-SELECT RLS stays as defence in
-- depth. Idempotent.

ALTER TABLE public.osionos_messages
  ADD COLUMN IF NOT EXISTS search_doc tsvector
    GENERATED ALWAYS AS (to_tsvector('english', coalesce(content, ''))) STORED;

CREATE INDEX IF NOT EXISTS osionos_messages_search_gin
  ON public.osionos_messages USING gin (search_doc);

NOTIFY pgrst, 'reload schema';
