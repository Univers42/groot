-- Communities for the osionos messenger — server-side groupings of chat
-- channels with their own membership/roles. Same discipline as
-- osionos-chat-migration.sql: idempotent DDL, RLS on, service_role FOR ALL,
-- authenticated member SELECT. The bridge talks PostgREST with the service key
-- and enforces membership itself; RLS is defence in depth.

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

-- Members of a community may read it.
DROP POLICY IF EXISTS osionos_communities_select_member ON public.osionos_communities;
CREATE POLICY osionos_communities_select_member ON public.osionos_communities
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM public.osionos_community_members m
            WHERE m.community_id = id AND m.user_id = auth.uid()));

DROP POLICY IF EXISTS osionos_community_members_select_own ON public.osionos_community_members;
CREATE POLICY osionos_community_members_select_own ON public.osionos_community_members
  FOR SELECT TO authenticated USING (user_id = auth.uid());

DROP POLICY IF EXISTS osionos_community_channels_select_member ON public.osionos_community_channels;
CREATE POLICY osionos_community_channels_select_member ON public.osionos_community_channels
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM public.osionos_community_members m
            WHERE m.community_id = osionos_community_channels.community_id
              AND m.user_id = auth.uid()));

DROP POLICY IF EXISTS osionos_communities_service_role_all ON public.osionos_communities;
CREATE POLICY osionos_communities_service_role_all ON public.osionos_communities
  FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS osionos_community_channels_service_role_all ON public.osionos_community_channels;
CREATE POLICY osionos_community_channels_service_role_all ON public.osionos_community_channels
  FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS osionos_community_members_service_role_all ON public.osionos_community_members;
CREATE POLICY osionos_community_members_service_role_all ON public.osionos_community_members
  FOR ALL TO service_role USING (true) WITH CHECK (true);

GRANT SELECT ON public.osionos_communities        TO authenticated;
GRANT SELECT ON public.osionos_community_channels  TO authenticated;
GRANT SELECT ON public.osionos_community_members   TO authenticated;
GRANT ALL    ON public.osionos_communities         TO service_role;
GRANT ALL    ON public.osionos_community_channels  TO service_role;
GRANT ALL    ON public.osionos_community_members   TO service_role;

NOTIFY pgrst, 'reload schema';
