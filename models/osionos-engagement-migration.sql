-- osionos engagement migration — per-channel read marks (unread tracking).
-- Built incrementally per milestone (mentions / notifications / push land in
-- their own migrations). Same discipline as osionos-social-migration.sql:
-- idempotent DDL, RLS on, own-row SELECT + service_role FOR ALL (the bridge
-- talks PostgREST with the service key and scopes every query by the verified
-- session user; RLS is defence in depth).

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── Unread: per (user, channel) high-water read mark ─────────────────────────
CREATE TABLE IF NOT EXISTS public.osionos_channel_reads (
  user_id              UUID NOT NULL,
  channel_id           UUID NOT NULL REFERENCES public.osionos_channels(id) ON DELETE CASCADE,
  last_read_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_read_message_id UUID,
  PRIMARY KEY (user_id, channel_id)
);
CREATE INDEX IF NOT EXISTS osionos_channel_reads_channel_idx
  ON public.osionos_channel_reads (channel_id);

ALTER TABLE public.osionos_channel_reads ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_channel_reads_select_own ON public.osionos_channel_reads;
CREATE POLICY osionos_channel_reads_select_own ON public.osionos_channel_reads
  FOR SELECT TO authenticated USING (user_id = auth.uid());
DROP POLICY IF EXISTS osionos_channel_reads_service_role_all ON public.osionos_channel_reads;
CREATE POLICY osionos_channel_reads_service_role_all ON public.osionos_channel_reads
  FOR ALL TO service_role USING (true) WITH CHECK (true);
GRANT SELECT ON public.osionos_channel_reads TO authenticated;
GRANT ALL    ON public.osionos_channel_reads TO service_role;

-- Cheap unread counts (PostgREST can't GROUP BY): for each channel the caller
-- belongs to, count messages newer than their last_read_at, excluding their own
-- and soft-deleted. SECURITY DEFINER + scoped to p_user (the bridge passes the
-- verified session user) so it can never leak another user's membership.
CREATE OR REPLACE FUNCTION public.osionos_unread_counts(p_user UUID)
RETURNS TABLE(channel_id UUID, unread BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT m.channel_id, count(*)::bigint
  FROM public.osionos_channel_members cm
  JOIN public.osionos_messages m ON m.channel_id = cm.channel_id
  LEFT JOIN public.osionos_channel_reads r
    ON r.channel_id = cm.channel_id AND r.user_id = p_user
  WHERE cm.user_id = p_user
    AND m.author_id <> p_user
    AND m.deleted_at IS NULL
    AND m.created_at > coalesce(r.last_read_at, 'epoch'::timestamptz)
  GROUP BY m.channel_id
$$;
REVOKE ALL ON FUNCTION public.osionos_unread_counts(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.osionos_unread_counts(UUID) TO service_role;

-- ── @mentions: who was named in a message (channel-member-scoped) ────────────
CREATE TABLE IF NOT EXISTS public.osionos_message_mentions (
  message_id UUID NOT NULL REFERENCES public.osionos_messages(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL,
  channel_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);
CREATE INDEX IF NOT EXISTS osionos_message_mentions_user_idx
  ON public.osionos_message_mentions (user_id, channel_id);

ALTER TABLE public.osionos_message_mentions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_message_mentions_select_own ON public.osionos_message_mentions;
CREATE POLICY osionos_message_mentions_select_own ON public.osionos_message_mentions
  FOR SELECT TO authenticated USING (user_id = auth.uid());
DROP POLICY IF EXISTS osionos_message_mentions_service_role_all ON public.osionos_message_mentions;
CREATE POLICY osionos_message_mentions_service_role_all ON public.osionos_message_mentions
  FOR ALL TO service_role USING (true) WITH CHECK (true);
GRANT SELECT ON public.osionos_message_mentions TO authenticated;
GRANT ALL    ON public.osionos_message_mentions TO service_role;

-- ── Notification inbox (mention / dm / reply / reaction / connection) ─────────
CREATE TABLE IF NOT EXISTS public.osionos_notifications (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL,
  type       TEXT NOT NULL CHECK (type IN ('mention','dm','reply','reaction','connection','system')),
  actor_id   UUID,
  channel_id UUID,
  message_id UUID,
  preview    TEXT,
  read_at    TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS osionos_notifications_inbox_idx  ON public.osionos_notifications (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS osionos_notifications_unread_idx ON public.osionos_notifications (user_id) WHERE read_at IS NULL;

ALTER TABLE public.osionos_notifications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_notifications_select_own ON public.osionos_notifications;
CREATE POLICY osionos_notifications_select_own ON public.osionos_notifications
  FOR SELECT TO authenticated USING (user_id = auth.uid());
DROP POLICY IF EXISTS osionos_notifications_service_role_all ON public.osionos_notifications;
CREATE POLICY osionos_notifications_service_role_all ON public.osionos_notifications
  FOR ALL TO service_role USING (true) WITH CHECK (true);
GRANT SELECT ON public.osionos_notifications TO authenticated;
GRANT ALL    ON public.osionos_notifications TO service_role;

-- Unguessable per-user realtime inbox key (the gateway's subscribe authz is
-- permissive, so the per-user topic is keyed by this random token, never the
-- raw user id). Backfill existing identities; default new rows.
ALTER TABLE public.osionos_bridge_identities ADD COLUMN IF NOT EXISTS notify_token TEXT;
UPDATE public.osionos_bridge_identities SET notify_token = encode(gen_random_bytes(16), 'hex') WHERE notify_token IS NULL;
ALTER TABLE public.osionos_bridge_identities ALTER COLUMN notify_token SET DEFAULT encode(gen_random_bytes(16), 'hex');

NOTIFY pgrst, 'reload schema';
