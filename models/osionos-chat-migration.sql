-- Chat / DMs / profiles / feed interactions for the osionos bridge.
-- Same discipline as osionos-bridge-migration.sql: idempotent DDL, RLS enabled
-- everywhere, service_role policies (the bridge talks PostgREST with the
-- service key and enforces membership itself), gen_random_uuid() pks.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Profile payload (avatar dataUrl, bio, ...) lives on the existing identity row.
ALTER TABLE public.osionos_bridge_identities
  ADD COLUMN IF NOT EXISTS profile JSONB NOT NULL DEFAULT '{}'::jsonb;

CREATE TABLE IF NOT EXISTS public.osionos_channels (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES public.osionos_workspaces(id) ON DELETE CASCADE,
  kind TEXT NOT NULL DEFAULT 'text' CHECK (kind IN ('text', 'dm', 'voice', 'video')),
  name TEXT NOT NULL DEFAULT 'general',
  topic TEXT,
  created_by UUID,
  is_private BOOLEAN NOT NULL DEFAULT false,
  abac JSONB NOT NULL DEFAULT '{}'::jsonb,
  -- Deterministic find-or-create key for DMs: 'dm:<uuid-lo>:<uuid-hi>' (sorted).
  dm_key TEXT UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.osionos_channel_members (
  channel_id UUID NOT NULL REFERENCES public.osionos_channels(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  role TEXT NOT NULL DEFAULT 'member',
  joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (channel_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.osionos_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id UUID NOT NULL REFERENCES public.osionos_channels(id) ON DELETE CASCADE,
  author_id UUID NOT NULL,
  content TEXT NOT NULL DEFAULT '',
  attachments JSONB NOT NULL DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  edited_at TIMESTAMPTZ,
  deleted_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS public.osionos_message_reactions (
  message_id UUID NOT NULL REFERENCES public.osionos_messages(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  emoji TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id, emoji)
);

CREATE TABLE IF NOT EXISTS public.osionos_feed_likes (
  page_id UUID NOT NULL,
  user_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (page_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.osionos_feed_comments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  page_id UUID NOT NULL,
  author_id UUID NOT NULL,
  content TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS osionos_channels_workspace_idx ON public.osionos_channels(workspace_id, kind);
CREATE INDEX IF NOT EXISTS osionos_channel_members_user_idx ON public.osionos_channel_members(user_id);
CREATE INDEX IF NOT EXISTS osionos_messages_channel_created_idx ON public.osionos_messages(channel_id, created_at);
CREATE INDEX IF NOT EXISTS osionos_message_reactions_message_idx ON public.osionos_message_reactions(message_id);
CREATE INDEX IF NOT EXISTS osionos_feed_likes_page_idx ON public.osionos_feed_likes(page_id);
CREATE INDEX IF NOT EXISTS osionos_feed_comments_page_idx ON public.osionos_feed_comments(page_id, created_at);

ALTER TABLE public.osionos_channels ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_channel_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_message_reactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_feed_likes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_feed_comments ENABLE ROW LEVEL SECURITY;

-- Authenticated read access mirrors the bridge's own checks (defence in depth):
-- channel rows for members of the channel or its workspace (public text only).
DROP POLICY IF EXISTS osionos_channels_select_member ON public.osionos_channels;
CREATE POLICY osionos_channels_select_member ON public.osionos_channels
  FOR SELECT TO authenticated USING (
    EXISTS (
      SELECT 1 FROM public.osionos_channel_members cm
      WHERE cm.channel_id = id AND cm.user_id = auth.uid()
    )
    OR (
      NOT is_private AND kind <> 'dm'
      AND EXISTS (
        SELECT 1 FROM public.osionos_workspace_members wm
        WHERE wm.workspace_id = public.osionos_channels.workspace_id AND wm.user_id = auth.uid()
      )
    )
  );

DROP POLICY IF EXISTS osionos_channel_members_select_own ON public.osionos_channel_members;
CREATE POLICY osionos_channel_members_select_own ON public.osionos_channel_members
  FOR SELECT TO authenticated USING (user_id = auth.uid());

DROP POLICY IF EXISTS osionos_messages_select_member ON public.osionos_messages;
CREATE POLICY osionos_messages_select_member ON public.osionos_messages
  FOR SELECT TO authenticated USING (
    EXISTS (
      SELECT 1 FROM public.osionos_channel_members cm
      WHERE cm.channel_id = public.osionos_messages.channel_id AND cm.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS osionos_message_reactions_select_member ON public.osionos_message_reactions;
CREATE POLICY osionos_message_reactions_select_member ON public.osionos_message_reactions
  FOR SELECT TO authenticated USING (
    EXISTS (
      SELECT 1 FROM public.osionos_messages m
      JOIN public.osionos_channel_members cm ON cm.channel_id = m.channel_id
      WHERE m.id = message_id AND cm.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS osionos_feed_likes_select_all ON public.osionos_feed_likes;
CREATE POLICY osionos_feed_likes_select_all ON public.osionos_feed_likes
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS osionos_feed_comments_select_all ON public.osionos_feed_comments;
CREATE POLICY osionos_feed_comments_select_all ON public.osionos_feed_comments
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS osionos_channels_service_role_all ON public.osionos_channels;
CREATE POLICY osionos_channels_service_role_all ON public.osionos_channels
  FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS osionos_channel_members_service_role_all ON public.osionos_channel_members;
CREATE POLICY osionos_channel_members_service_role_all ON public.osionos_channel_members
  FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS osionos_messages_service_role_all ON public.osionos_messages;
CREATE POLICY osionos_messages_service_role_all ON public.osionos_messages
  FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS osionos_message_reactions_service_role_all ON public.osionos_message_reactions;
CREATE POLICY osionos_message_reactions_service_role_all ON public.osionos_message_reactions
  FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS osionos_feed_likes_service_role_all ON public.osionos_feed_likes;
CREATE POLICY osionos_feed_likes_service_role_all ON public.osionos_feed_likes
  FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS osionos_feed_comments_service_role_all ON public.osionos_feed_comments;
CREATE POLICY osionos_feed_comments_service_role_all ON public.osionos_feed_comments
  FOR ALL TO service_role USING (true) WITH CHECK (true);

GRANT SELECT ON public.osionos_channels TO authenticated;
GRANT SELECT ON public.osionos_channel_members TO authenticated;
GRANT SELECT ON public.osionos_messages TO authenticated;
GRANT SELECT ON public.osionos_message_reactions TO authenticated;
GRANT SELECT ON public.osionos_feed_likes TO authenticated;
GRANT SELECT ON public.osionos_feed_comments TO authenticated;
GRANT ALL ON public.osionos_channels TO service_role;
GRANT ALL ON public.osionos_channel_members TO service_role;
GRANT ALL ON public.osionos_messages TO service_role;
GRANT ALL ON public.osionos_message_reactions TO service_role;
GRANT ALL ON public.osionos_feed_likes TO service_role;
GRANT ALL ON public.osionos_feed_comments TO service_role;

NOTIFY pgrst, 'reload schema';
