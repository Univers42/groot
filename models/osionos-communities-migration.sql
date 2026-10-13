-- Communities for the osionos messenger — server-side groupings of chat
-- channels with their own membership/roles. Same discipline as
-- osionos-chat-migration.sql: idempotent DDL, RLS on, service_role FOR ALL.
-- The bridge (service_role) is the only reader and writer; it talks PostgREST
-- with the service key and enforces membership itself.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.osionos_communities (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL DEFAULT 'Community',
  avatar      TEXT,
  description TEXT,
  creator_id  UUID NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.osionos_community_channels (
  community_id UUID NOT NULL REFERENCES public.osionos_communities(id) ON DELETE CASCADE,
  channel_id   UUID NOT NULL REFERENCES public.osionos_channels(id) ON DELETE CASCADE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (community_id, channel_id)
);

CREATE TABLE IF NOT EXISTS public.osionos_community_members (
  community_id UUID NOT NULL REFERENCES public.osionos_communities(id) ON DELETE CASCADE,
  user_id      UUID NOT NULL,
  role         TEXT NOT NULL DEFAULT 'member',
  joined_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (community_id, user_id)
);

CREATE INDEX IF NOT EXISTS osionos_community_members_user_idx
  ON public.osionos_community_members (user_id);
CREATE INDEX IF NOT EXISTS osionos_community_channels_channel_idx
  ON public.osionos_community_channels (channel_id);

ALTER TABLE public.osionos_communities         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_community_channels  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_community_members   ENABLE ROW LEVEL SECURITY;

-- The bridge (service_role) is the only reader and writer; nobody else gets a grant.
DROP POLICY IF EXISTS osionos_communities_select_member ON public.osionos_communities;

DROP POLICY IF EXISTS osionos_community_members_select_own ON public.osionos_community_members;

DROP POLICY IF EXISTS osionos_community_channels_select_member ON public.osionos_community_channels;

DROP POLICY IF EXISTS osionos_communities_service_role_all ON public.osionos_communities;
CREATE POLICY osionos_communities_service_role_all ON public.osionos_communities
  FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS osionos_community_channels_service_role_all ON public.osionos_community_channels;
CREATE POLICY osionos_community_channels_service_role_all ON public.osionos_community_channels
  FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS osionos_community_members_service_role_all ON public.osionos_community_members;
CREATE POLICY osionos_community_members_service_role_all ON public.osionos_community_members
  FOR ALL TO service_role USING (true) WITH CHECK (true);

GRANT ALL    ON public.osionos_communities         TO service_role;
GRANT ALL    ON public.osionos_community_channels  TO service_role;
GRANT ALL    ON public.osionos_community_members   TO service_role;

NOTIFY pgrst, 'reload schema';
