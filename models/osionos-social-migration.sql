-- Social graph for the osionos bridge: global directory + search, LinkedIn-style
-- connections, WhatsApp-style groups, read/seen receipts, block/report, and
-- 3-state workspace visibility + join requests ("Collaboration" space).
--
-- Same discipline as osionos-bridge/chat migrations: idempotent DDL, RLS enabled
-- everywhere, service_role FOR ALL (the bridge talks PostgREST with the service
-- key and enforces membership itself), authenticated SELECT for defence in depth,
-- gen_random_uuid() pks. Depends on osionos-bridge + osionos-chat migrations.

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;   -- literal name/username trigram search
CREATE EXTENSION IF NOT EXISTS vector;    -- semantic bio/headline search (pgvector 0.8.0)

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Global directory — extend the existing identity row (no new directory table)
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.osionos_bridge_identities
  ADD COLUMN IF NOT EXISTS username TEXT,
  ADD COLUMN IF NOT EXISTS directory_opt_out BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS bio_embedding vector(384),
  ADD COLUMN IF NOT EXISTS search_doc tsvector
    GENERATED ALWAYS AS (
      setweight(to_tsvector('simple',  coalesce(display_name, '')), 'A') ||
      setweight(to_tsvector('simple',  coalesce(username, '')), 'A') ||
      setweight(to_tsvector('english', coalesce(profile->>'bio', '')), 'B') ||
      setweight(to_tsvector('english', coalesce(profile->>'headline', '')), 'B') ||
      setweight(to_tsvector('simple',  coalesce(profile->>'location', '')), 'C')
    ) STORED;

CREATE UNIQUE INDEX IF NOT EXISTS osionos_identities_username_uidx
  ON public.osionos_bridge_identities (lower(username)) WHERE username IS NOT NULL;
CREATE INDEX IF NOT EXISTS osionos_identities_search_gin
  ON public.osionos_bridge_identities USING gin (search_doc);
CREATE INDEX IF NOT EXISTS osionos_identities_name_trgm
  ON public.osionos_bridge_identities USING gin (display_name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS osionos_identities_username_trgm
  ON public.osionos_bridge_identities USING gin (username gin_trgm_ops);
-- hnsw needs no training data and tolerates incremental inserts (vs ivfflat).
CREATE INDEX IF NOT EXISTS osionos_identities_embed_hnsw
  ON public.osionos_bridge_identities USING hnsw (bio_embedding vector_cosine_ops);

CREATE OR REPLACE VIEW public.osionos_directory AS
  SELECT user_id, display_name, username,
         profile->>'bio' AS bio, profile->>'headline' AS headline,
         profile->'avatar' AS avatar, last_seen_at, directory_opt_out
  FROM public.osionos_bridge_identities
  WHERE directory_opt_out = false;
GRANT SELECT ON public.osionos_directory TO authenticated, service_role;

DROP POLICY IF EXISTS osionos_bridge_identities_select_directory ON public.osionos_bridge_identities;
CREATE POLICY osionos_bridge_identities_select_directory ON public.osionos_bridge_identities
  FOR SELECT TO authenticated USING (directory_opt_out = false);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Connections — directed request carrying an intro message; one row per pair
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.osionos_connections (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  requester_id UUID NOT NULL,
  addressee_id UUID NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'accepted', 'declined', 'withdrawn', 'blocked')),
  intro_message TEXT,
  source TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'colleague')),
  pair_key TEXT GENERATED ALWAYS AS (
    CASE WHEN requester_id < addressee_id
      THEN requester_id::text || ':' || addressee_id::text
      ELSE addressee_id::text || ':' || requester_id::text END
  ) STORED,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  responded_at TIMESTAMPTZ,
  CHECK (requester_id <> addressee_id),
  UNIQUE (pair_key)
);
CREATE INDEX IF NOT EXISTS osionos_connections_addressee_idx
  ON public.osionos_connections (addressee_id, status);
CREATE INDEX IF NOT EXISTS osionos_connections_requester_idx
  ON public.osionos_connections (requester_id, status);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Group chats — extend osionos_channels (no new message table)
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.osionos_channels DROP CONSTRAINT IF EXISTS osionos_channels_kind_check;
ALTER TABLE public.osionos_channels
  ADD CONSTRAINT osionos_channels_kind_check
  CHECK (kind IN ('text', 'dm', 'voice', 'video', 'group'));
ALTER TABLE public.osionos_channels
  ADD COLUMN IF NOT EXISTS avatar TEXT,
  ADD COLUMN IF NOT EXISTS description TEXT;
-- role stays free-text default 'member'; constrain new writes without failing legacy rows
ALTER TABLE public.osionos_channel_members DROP CONSTRAINT IF EXISTS osionos_channel_members_role_check;
ALTER TABLE public.osionos_channel_members
  ADD CONSTRAINT osionos_channel_members_role_check
  CHECK (role IN ('owner', 'admin', 'member')) NOT VALID;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Read / delivered / seen receipts (typing is ephemeral — no table)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.osionos_message_receipts (
  message_id UUID NOT NULL REFERENCES public.osionos_messages(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  status TEXT NOT NULL DEFAULT 'delivered' CHECK (status IN ('delivered', 'seen')),
  delivered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  seen_at TIMESTAMPTZ,
  PRIMARY KEY (message_id, user_id)
);
CREATE INDEX IF NOT EXISTS osionos_message_receipts_user_idx
  ON public.osionos_message_receipts (user_id, status);

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Block + report
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.osionos_user_blocks (
  blocker_id UUID NOT NULL,
  blocked_id UUID NOT NULL,
  reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (blocker_id, blocked_id),
  CHECK (blocker_id <> blocked_id)
);
CREATE INDEX IF NOT EXISTS osionos_user_blocks_blocked_idx
  ON public.osionos_user_blocks (blocked_id);

CREATE TABLE IF NOT EXISTS public.osionos_user_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id UUID NOT NULL,
  subject_user_id UUID,
  subject_kind TEXT NOT NULL DEFAULT 'user'
    CHECK (subject_kind IN ('user', 'message', 'channel', 'workspace')),
  subject_id TEXT,
  category TEXT NOT NULL DEFAULT 'other',
  details TEXT,
  status TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'reviewing', 'resolved', 'dismissed')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS osionos_user_reports_status_idx
  ON public.osionos_user_reports (status, created_at DESC);

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Workspace 3-state visibility + join requests ("Collaboration")
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.osionos_workspaces
  ADD COLUMN IF NOT EXISTS visibility TEXT NOT NULL DEFAULT 'confidential'
    CHECK (visibility IN ('confidential', 'request_to_join', 'public'));
CREATE INDEX IF NOT EXISTS osionos_workspaces_visibility_idx
  ON public.osionos_workspaces (visibility) WHERE visibility <> 'confidential';

CREATE TABLE IF NOT EXISTS public.osionos_join_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES public.osionos_workspaces(id) ON DELETE CASCADE,
  requester_id UUID NOT NULL,
  message TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'denied')),
  decided_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  decided_at TIMESTAMPTZ,
  UNIQUE (workspace_id, requester_id)
);
CREATE INDEX IF NOT EXISTS osionos_join_requests_workspace_idx
  ON public.osionos_join_requests (workspace_id, status);

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. RLS — enable + authenticated-read (defence in depth) + service_role FOR ALL
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.osionos_connections      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_message_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_user_blocks      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_user_reports     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_join_requests    ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS osionos_connections_select_party ON public.osionos_connections;
CREATE POLICY osionos_connections_select_party ON public.osionos_connections
  FOR SELECT TO authenticated USING (requester_id = auth.uid() OR addressee_id = auth.uid());

DROP POLICY IF EXISTS osionos_receipts_select_party ON public.osionos_message_receipts;
CREATE POLICY osionos_receipts_select_party ON public.osionos_message_receipts
  FOR SELECT TO authenticated USING (
    user_id = auth.uid() OR EXISTS (
      SELECT 1 FROM public.osionos_messages m
      WHERE m.id = message_id AND m.author_id = auth.uid()));

DROP POLICY IF EXISTS osionos_blocks_select_own ON public.osionos_user_blocks;
CREATE POLICY osionos_blocks_select_own ON public.osionos_user_blocks
  FOR SELECT TO authenticated USING (blocker_id = auth.uid());

DROP POLICY IF EXISTS osionos_reports_select_own ON public.osionos_user_reports;
CREATE POLICY osionos_reports_select_own ON public.osionos_user_reports
  FOR SELECT TO authenticated USING (reporter_id = auth.uid());

DROP POLICY IF EXISTS osionos_join_requests_select_party ON public.osionos_join_requests;
CREATE POLICY osionos_join_requests_select_party ON public.osionos_join_requests
  FOR SELECT TO authenticated USING (
    requester_id = auth.uid() OR EXISTS (
      SELECT 1 FROM public.osionos_workspaces w
      WHERE w.id = workspace_id AND w.owner_id = auth.uid()));

DROP POLICY IF EXISTS osionos_connections_service_role_all ON public.osionos_connections;
CREATE POLICY osionos_connections_service_role_all ON public.osionos_connections
  FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS osionos_receipts_service_role_all ON public.osionos_message_receipts;
CREATE POLICY osionos_receipts_service_role_all ON public.osionos_message_receipts
  FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS osionos_blocks_service_role_all ON public.osionos_user_blocks;
CREATE POLICY osionos_blocks_service_role_all ON public.osionos_user_blocks
  FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS osionos_reports_service_role_all ON public.osionos_user_reports;
CREATE POLICY osionos_reports_service_role_all ON public.osionos_user_reports
  FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS osionos_join_requests_service_role_all ON public.osionos_join_requests;
CREATE POLICY osionos_join_requests_service_role_all ON public.osionos_join_requests
  FOR ALL TO service_role USING (true) WITH CHECK (true);

GRANT SELECT ON public.osionos_connections, public.osionos_message_receipts,
               public.osionos_user_blocks, public.osionos_user_reports,
               public.osionos_join_requests TO authenticated;
GRANT ALL ON public.osionos_connections, public.osionos_message_receipts,
             public.osionos_user_blocks, public.osionos_user_reports,
             public.osionos_join_requests TO service_role;

NOTIFY pgrst, 'reload schema';
