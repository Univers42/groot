-- Message media attachments for the osionos messenger.
-- Bytes live in the grobase storage plane (MinIO via mini-baas-storage-router,
-- bucket 'chat', keyed by content sha256, owner-prefixed {ownerId}/{sha256}.{ext}).
-- This table is the metadata/ownership/dedup record + the per-conversation gallery
-- source. The denormalized copy also rides osionos_messages.attachments JSONB (which
-- the bridge already round-trips). Same discipline as osionos-chat-migration.sql:
-- idempotent DDL, RLS on, service_role FOR ALL, authenticated member SELECT.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.osionos_message_attachments (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id    UUID NOT NULL REFERENCES public.osionos_messages(id) ON DELETE CASCADE,
  channel_id    UUID NOT NULL REFERENCES public.osionos_channels(id) ON DELETE CASCADE,
  owner_id      UUID NOT NULL,                       -- the author (owner-attachment)
  type          TEXT NOT NULL CHECK (type IN ('image','video','audio','file','url')),
  bucket        TEXT NOT NULL DEFAULT 'chat',
  object_key    TEXT,                                -- '{sha256}.{ext}' in MinIO; NULL for type='url'
  sha256        TEXT,                                -- content hash (dedup key)
  url           TEXT,                                -- external link (type='url') or null
  display_name  TEXT NOT NULL DEFAULT '',
  size          BIGINT NOT NULL DEFAULT 0,
  content_type  TEXT NOT NULL DEFAULT 'application/octet-stream',
  metadata      JSONB NOT NULL DEFAULT '{}'::jsonb,  -- width/height/durationMs/waveform/preview
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (message_id, object_key)                    -- idempotent commit per object
);

CREATE INDEX IF NOT EXISTS osionos_msg_attach_channel_idx
  ON public.osionos_message_attachments (channel_id, created_at DESC);   -- gallery
CREATE INDEX IF NOT EXISTS osionos_msg_attach_message_idx
  ON public.osionos_message_attachments (message_id);
CREATE INDEX IF NOT EXISTS osionos_msg_attach_owner_idx
  ON public.osionos_message_attachments (owner_id);
CREATE INDEX IF NOT EXISTS osionos_msg_attach_sha_idx
  ON public.osionos_message_attachments (owner_id, sha256);              -- dedup lookup

ALTER TABLE public.osionos_message_attachments ENABLE ROW LEVEL SECURITY;

-- Channel members may read attachments (mirrors osionos_messages_select_member).
DROP POLICY IF EXISTS osionos_msg_attach_select_member ON public.osionos_message_attachments;
CREATE POLICY osionos_msg_attach_select_member ON public.osionos_message_attachments
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM public.osionos_channel_members cm
            WHERE cm.channel_id = osionos_message_attachments.channel_id
              AND cm.user_id = auth.uid()));

DROP POLICY IF EXISTS osionos_msg_attach_service_role_all ON public.osionos_message_attachments;
CREATE POLICY osionos_msg_attach_service_role_all ON public.osionos_message_attachments
  FOR ALL TO service_role USING (true) WITH CHECK (true);

GRANT SELECT ON public.osionos_message_attachments TO authenticated;
GRANT ALL    ON public.osionos_message_attachments TO service_role;

NOTIFY pgrst, 'reload schema';
