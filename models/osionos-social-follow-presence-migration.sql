-- osionos-social-follow-presence-migration.sql — the follow graph, the four
-- presence states and the user-set status (P2-3-root).
--
-- WHY THIS FILE EXISTS
--   The social graph has connections (symmetric, accepted/pending) and blocks, but
--   no asymmetric follow; presence is a heartbeat key with no state the user
--   chooses; a profile carries no status. The bridge needs one table per concern
--   and ONE round trip for the counts (the feed_page_counts pattern), not a count
--   query per list row.
--
-- WHAT IT CREATES
--   public.osionos_follows       (follower_id, followee_id) edges; PK is the
--                                 idempotency key, two keyset indexes serve the
--                                 followers and the following lists
--   public.osionos_presence      one row per user, created by the first heartbeat;
--                                 the default state is 'online' (a default of
--                                 'invisible' would hide everyone)
--   osionos_profiles.status_*    emoji, text, expiry and "busy"; expiry is lazy
--                                 (a reader ignores a status whose expiry passed)
--   osionos_follow_counts()      one row: followers, following, does the viewer follow
--   a BEFORE INSERT trigger      refuses a follow when either side blocked the other
--
-- WHO REACHES WHAT
--   service_role          everything (the bridge).
--   osionos_account_user  its own follow edges (SELECT), its own presence row
--                         (SELECT, UPDATE of state and text), its own status columns.
--   anon, authenticated   nothing.
--
-- WHERE IT RUNS
--   scripts/apply-models-migrations.sh lists it in ORDERED_LAST after the
--   profession file: osionos-account-profiles-migration.sql revokes and re-grants
--   the account role's profile columns on every boot, so the status grants below
--   must come after it; and before the service-role-only pass, which must not take
--   back what this file grants.
--
-- Idempotent: a second run moves no grant, policy, role attribute or index
-- (check g of scripts/verify/models-grants.sh).

BEGIN;

-- Caveat: a busy table makes this file fail (the whole transaction rolls back)
-- instead of waiting; the next run retries it. 5 s is a budget, not a promise.
SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
  IF to_regclass('public.osionos_profiles') IS NULL THEN
    RAISE EXCEPTION 'public.osionos_profiles is missing — osionos-account-profiles-migration.sql must run first';
  END IF;
  IF to_regclass('public.osionos_user_blocks') IS NULL THEN
    RAISE EXCEPTION 'public.osionos_user_blocks is missing — osionos-social-migration.sql must run first';
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS public.osionos_follows (
  follower_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  followee_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (follower_id, followee_id),
  CHECK (follower_id <> followee_id)
);

-- Both lists page by keyset on (created_at DESC, other_id DESC), and the counts
-- read the same indexes: every column the query touches is in the index, so the
-- count is an index-only scan and a list page stops after `limit` entries.
CREATE INDEX IF NOT EXISTS osionos_follows_followee_idx
  ON public.osionos_follows (followee_id, created_at DESC, follower_id DESC);
CREATE INDEX IF NOT EXISTS osionos_follows_follower_idx
  ON public.osionos_follows (follower_id, created_at DESC, followee_id DESC);

CREATE TABLE IF NOT EXISTS public.osionos_presence (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  state TEXT NOT NULL DEFAULT 'online'
    CHECK (state IN ('online','away','dnd','invisible')),
  custom_text TEXT CHECK (custom_text IS NULL OR char_length(custom_text) <= 120),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The CREATE TABLE hook of grobase (012) arms realtime_notify() on a new public
-- table, and the realtime socket has no grant check: drop it here, not only in
-- realtime-cdc-off, because this file may run without that pass.
DROP TRIGGER IF EXISTS osionos_follows_realtime_trigger ON public.osionos_follows;
DROP TRIGGER IF EXISTS osionos_presence_realtime_trigger ON public.osionos_presence;

-- The block rule lives in the database so no writer can skip it: a block in
-- either direction refuses the follow. The bridge maps 23514/follow_blocked to
-- 403. SECURITY INVOKER: the inserter is service_role, which may read the blocks.
-- Caveat: a block committed in the same instant as the follow is not seen (no
-- lock on the blocks table), so that follow survives until the next unfollow.
CREATE OR REPLACE FUNCTION public.osionos_follows_block_guard() RETURNS trigger
  LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.osionos_user_blocks b
              WHERE (b.blocker_id = NEW.followee_id AND b.blocked_id = NEW.follower_id)
                 OR (b.blocker_id = NEW.follower_id AND b.blocked_id = NEW.followee_id)) THEN
    RAISE EXCEPTION 'follow_blocked' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$$;
REVOKE ALL ON FUNCTION public.osionos_follows_block_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS osionos_follows_block_guard ON public.osionos_follows;
CREATE TRIGGER osionos_follows_block_guard BEFORE INSERT ON public.osionos_follows
  FOR EACH ROW EXECUTE FUNCTION public.osionos_follows_block_guard();

-- One row, one round trip. SECURITY INVOKER with service-role EXECUTE only: the
-- counts are public numbers, but the bridge decides who may ask.
CREATE OR REPLACE FUNCTION public.osionos_follow_counts(p_user uuid, p_viewer uuid)
  RETURNS TABLE (follower_count bigint, following_count bigint, viewer_follows boolean)
  LANGUAGE sql STABLE SECURITY INVOKER SET search_path = pg_catalog, public AS $$
  SELECT (SELECT count(*) FROM public.osionos_follows WHERE followee_id = p_user),
         (SELECT count(*) FROM public.osionos_follows WHERE follower_id = p_user),
         EXISTS (SELECT 1 FROM public.osionos_follows
                  WHERE follower_id = p_viewer AND followee_id = p_user)
$$;
REVOKE ALL ON FUNCTION public.osionos_follow_counts(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.osionos_follow_counts(uuid, uuid) TO service_role;

-- The status columns. ADD COLUMN IF NOT EXISTS keeps the inline CHECKs from
-- being added twice on a replay.
ALTER TABLE public.osionos_profiles
  ADD COLUMN IF NOT EXISTS status_emoji TEXT
    CHECK (status_emoji IS NULL OR char_length(status_emoji) <= 8),
  ADD COLUMN IF NOT EXISTS status_text TEXT
    CHECK (status_text IS NULL OR char_length(status_text) <= 120),
  ADD COLUMN IF NOT EXISTS status_expires_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS status_busy BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE public.osionos_follows ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_presence ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.osionos_follows FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.osionos_presence FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.osionos_follows TO service_role;
GRANT ALL ON public.osionos_presence TO service_role;

-- The account role: column grants, the REVOKE first so a leftover table-level
-- grant does not survive a replay.
REVOKE ALL ON public.osionos_follows FROM osionos_account_user;
GRANT SELECT (follower_id, followee_id, created_at) ON public.osionos_follows TO osionos_account_user;
REVOKE ALL ON public.osionos_presence FROM osionos_account_user;
GRANT SELECT (user_id, state, custom_text, updated_at) ON public.osionos_presence TO osionos_account_user;
GRANT UPDATE (state, custom_text, updated_at) ON public.osionos_presence TO osionos_account_user;
GRANT SELECT (status_emoji, status_text, status_expires_at, status_busy),
      UPDATE (status_emoji, status_text, status_expires_at, status_busy)
  ON public.osionos_profiles TO osionos_account_user;

DROP POLICY IF EXISTS osionos_follows_service_role_all ON public.osionos_follows;
CREATE POLICY osionos_follows_service_role_all ON public.osionos_follows FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS osionos_follows_owner_read ON public.osionos_follows;
CREATE POLICY osionos_follows_owner_read ON public.osionos_follows FOR SELECT TO osionos_account_user
  USING (follower_id = (SELECT public.osionos_account_uid())
      OR followee_id = (SELECT public.osionos_account_uid()));
COMMENT ON TABLE public.osionos_follows IS 'osionos:account-plane';

DROP POLICY IF EXISTS osionos_presence_service_role_all ON public.osionos_presence;
CREATE POLICY osionos_presence_service_role_all ON public.osionos_presence FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS osionos_presence_owner_read ON public.osionos_presence;
CREATE POLICY osionos_presence_owner_read ON public.osionos_presence FOR SELECT TO osionos_account_user
  USING (user_id = (SELECT public.osionos_account_uid()));
DROP POLICY IF EXISTS osionos_presence_owner_update ON public.osionos_presence;
CREATE POLICY osionos_presence_owner_update ON public.osionos_presence FOR UPDATE TO osionos_account_user
  USING (user_id = (SELECT public.osionos_account_uid()))
  WITH CHECK (user_id = (SELECT public.osionos_account_uid()));
COMMENT ON TABLE public.osionos_presence IS 'osionos:account-plane';

COMMIT;

NOTIFY pgrst, 'reload schema';
