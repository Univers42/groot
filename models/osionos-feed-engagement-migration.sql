-- Feed engagement (multi-emoji reactions, richer/threaded comments, sharing)
-- for the osionos social feed. Extends the feed tables from
-- osionos-chat-migration.sql (osionos_feed_likes / osionos_feed_comments).
--
-- Same discipline as osionos-chat-migration.sql: fully idempotent DDL
-- (CREATE TABLE / ADD COLUMN IF NOT EXISTS, DROP POLICY IF EXISTS before
-- CREATE POLICY), RLS enabled everywhere, authenticated SELECT (mirrors
-- osionos_feed_comments_select_all), and service_role for ALL — every write
-- goes through the service-role bridge, which forces user_id to the session.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Multi-emoji reactions on a feed post (a page). One row per (page, user, emoji);
-- a user can hold several distinct emoji on the same post.
CREATE TABLE IF NOT EXISTS public.osionos_feed_reactions (
  page_id UUID NOT NULL,
  user_id UUID NOT NULL,
  emoji TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (page_id, user_id, emoji)
);

-- Richer comments: track edits (updated_at) and one level of threaded replies
-- (parent_id → same table; cascade delete removes replies with their parent).
ALTER TABLE public.osionos_feed_comments
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE public.osionos_feed_comments
  ADD COLUMN IF NOT EXISTS parent_id UUID REFERENCES public.osionos_feed_comments(id) ON DELETE CASCADE;

-- Shares of a feed post to a profile / copied link / DM.
CREATE TABLE IF NOT EXISTS public.osionos_feed_shares (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  page_id UUID NOT NULL,
  user_id UUID NOT NULL,
  target TEXT NOT NULL CHECK (target IN ('profile', 'link', 'dm')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS osionos_feed_reactions_page_emoji_idx ON public.osionos_feed_reactions(page_id, emoji);
CREATE INDEX IF NOT EXISTS osionos_feed_comments_parent_idx ON public.osionos_feed_comments(parent_id);
CREATE INDEX IF NOT EXISTS osionos_feed_shares_page_idx ON public.osionos_feed_shares(page_id);

ALTER TABLE public.osionos_feed_reactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_feed_shares ENABLE ROW LEVEL SECURITY;

-- Authenticated read access mirrors osionos_feed_comments_select_all: any signed-in
-- user can read the aggregate reaction/share signal on a post.
DROP POLICY IF EXISTS osionos_feed_reactions_select_all ON public.osionos_feed_reactions;
CREATE POLICY osionos_feed_reactions_select_all ON public.osionos_feed_reactions
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS osionos_feed_shares_select_all ON public.osionos_feed_shares;
CREATE POLICY osionos_feed_shares_select_all ON public.osionos_feed_shares
  FOR SELECT TO authenticated USING (true);

-- Writes go only through the service-role bridge (it forces user_id = session).
DROP POLICY IF EXISTS osionos_feed_reactions_service_role_all ON public.osionos_feed_reactions;
CREATE POLICY osionos_feed_reactions_service_role_all ON public.osionos_feed_reactions
  FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS osionos_feed_shares_service_role_all ON public.osionos_feed_shares;
CREATE POLICY osionos_feed_shares_service_role_all ON public.osionos_feed_shares
  FOR ALL TO service_role USING (true) WITH CHECK (true);

GRANT SELECT ON public.osionos_feed_reactions TO authenticated;
GRANT SELECT ON public.osionos_feed_shares TO authenticated;
GRANT ALL ON public.osionos_feed_reactions TO service_role;
GRANT ALL ON public.osionos_feed_shares TO service_role;

-- Feed engagement notifications: the shared osionos_notifications inbox (defined in
-- osionos-engagement-migration.sql) constrains `type` to the chat set; widen it so
-- the bridge can notify a post owner when someone reacts/comments/shares. Idempotent
-- (drop-then-add), and guarded so it no-ops if the table hasn't been created yet.
DO $$
BEGIN
  IF to_regclass('public.osionos_notifications') IS NOT NULL THEN
    ALTER TABLE public.osionos_notifications DROP CONSTRAINT IF EXISTS osionos_notifications_type_check;
    ALTER TABLE public.osionos_notifications ADD CONSTRAINT osionos_notifications_type_check
      CHECK (type IN ('mention','dm','reply','reaction','connection','system',
                      'feed_reaction','feed_comment','feed_share'));
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
