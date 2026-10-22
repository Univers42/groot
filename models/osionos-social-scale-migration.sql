-- osionos-social-scale-migration.sql — colleague edges at join time, feed counts in one call.
--
-- WHY
--   GET /api/connections reconciled the colleague roster on EVERY call:
--   bridge-social.mjs:89-104 read every co-member of the caller through one
--   nested embed (up to 200 workspaces x 500 co-members = 100 000 rows,
--   bridge-social-core.mjs:226-245) and posted up to 500 'accepted'/'colleague'
--   edges (bridge-social-core.mjs:294-304, COLLEAGUE_INSERT_CAP = 500). No SQL
--   created those edges: models/osionos-social-migration.sql:62 carries only the
--   `source` CHECK. The feed numbers were read as rows and counted in JS, 3-4
--   queries per post card (bridge-feed.mjs:145-153 likes, :174-180 comments —
--   whose own comment says to switch — and :307-309 shares).
--
-- WHAT IT CREATES
--   1. public.osionos_colleague_edges_on_join() and the trigger
--      osionos_workspace_members_colleague_edges_trg: an AFTER INSERT trigger on
--      public.osionos_workspace_members that writes the colleague edges when a
--      member joins — in the database, where every join path passes (invite
--      accept, admin add, the sign-in upsert RPC).
--   2. A one-time backfill for the members who joined before the trigger existed.
--   3. public.osionos_feed_page_counts(page, viewer): the four feed numbers in
--      one call.
--
-- THE SEMANTICS DELTA (read this before comparing the trigger with the bridge)
--   The bridge today pairs up to 500 co-members per workspace across up to 200
--   of the CALLER's workspaces (SHARED_WORKSPACES_LIMIT = 200,
--   COMEMBERS_PER_WORKSPACE_LIMIT = 500, bridge-social-core.mjs:226-231). The
--   trigger is per WORKSPACE: it cannot reproduce the per-caller 200-workspace
--   cap, and it skips a workspace above 200 members, so a workspace of 201-500
--   members loses the auto-edges. This is deliberate: one join stays at 199
--   inserts, and no call ever fans out to 100 000 rows.
--   Caveat: the 200-member threshold is counted AT JOIN TIME, so a workspace
--   that later grows past it keeps the edges it already made.
--
-- THE EDGES ARE THE BRIDGE'S EDGES — every rule and the line it comes from
--   requester_id = the member who joined   (bridge-social-core.mjs:297: requester_id: userId,
--                                            the caller is the requester there, the joiner here)
--   addressee_id = the peer                 (bridge-social-core.mjs:298: addressee_id: peer)
--   status = 'accepted'                     (bridge-social-core.mjs:299)
--   source = 'colleague'                    (bridge-social-core.mjs:300)
--   responded_at = now()                    (bridge-social-core.mjs:301)
--   no intro_message                        (bridge-social-core.mjs:296-302 sends no intro_message)
--   one edge per peer, an existing pair is kept
--                                           (bridge-social-core.mjs:294 + :303: on_conflict=pair_key
--                                            with ignore-duplicates, the same ON CONFLICT DO NOTHING)
--   a BLOCKED pair gets an edge too         (bridge-social-core.mjs:284-285 inserts for every peer
--                                            with no edge, blocked or not; bridge-social.mjs:108-110
--                                            says so in words: "a co-member blocked before any edge
--                                            existed still gets an accepted row from the insert",
--                                            and only the read hides it — bridge-social.mjs:115)
--   the source column the list returns      (bridge-social.mjs:129: source: row.source ?? 'manual')
--
-- WHO MAY JOIN A WORKSPACE
--   The trigger is SECURITY INVOKER: it runs with the rights of the caller, and
--   the only role that inserts a workspace member is service_role (the bridge),
--   which holds ALL on public.osionos_workspace_members
--   (models/osionos-bridge-migration.sql:212) and on public.osionos_connections
--   (models/osionos-social-migration.sql:196). No other role reaches either
--   table: the `privileged` row of scripts/verify/models-grants/checks.sql
--   counts every anon and authenticated privilege on an osionos_% relation,
--   and its `feed_counts_exec_grants` row proves the same for this file's
--   function.
--
-- Idempotent: a second run creates no trigger, no backfill row and no grant.
-- (check g of scripts/verify/models-grants.sh)

BEGIN;

-- Caveat: a busy table makes this file fail (the whole transaction rolls back)
-- instead of waiting; the next boot retries it. 5 s is a budget, not a promise —
-- the same budget the account foundation takes (osionos-account-foundation-migration.sql:78),
-- whose Caveat says a replay behind a longer-held lock fails the boot loudly
-- rather than queueing every join behind it.
SET LOCAL lock_timeout = '5s';

-- The trigger makes a join take public.osionos_workspace_members and then
-- public.osionos_connections. This replay takes the two in the SAME order, so a
-- replay and a join can never deadlock (40P01): whoever holds the members table
-- first makes the other wait, and the other holds nothing the first wants.
-- SHARE ROW EXCLUSIVE blocks the writes the trigger does (RowExclusive) for the
-- duration of the backfill.
-- Caveat: the lock is held for the whole file, so a long backfill holds both
-- tables against every join for that long.
LOCK TABLE public.osionos_workspace_members, public.osionos_connections IN SHARE ROW EXCLUSIVE MODE;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. The trigger function — the colleague edges, written where the join happens
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.osionos_colleague_edges_on_join() RETURNS trigger
  LANGUAGE plpgsql
  SECURITY INVOKER
  SET search_path = pg_catalog, public AS $fn$
DECLARE
  v_members integer;
BEGIN
  -- A colleague edge is a convenience; a join is not. The body runs in an inner
  -- block so a failing edge insert cannot fail the join: the exception is
  -- caught, a WARNING names the workspace and the SQLSTATE, and the join
  -- commits. The catch list is NARROW on purpose — unique_violation,
  -- foreign_key_violation, check_violation and not_null_violation are the four
  -- failures an edge insert can have. Anything else propagates: a broken trigger
  -- must be loud, not silent forever.
  BEGIN
    -- The member count is taken INSIDE the trigger, so the threshold is the
    -- workspace's size at join time. NEW is already in the table (AFTER INSERT),
    -- so the count includes the member who just joined and one join inserts at
    -- most 199 edges.
    SELECT count(*)::integer INTO v_members
      FROM public.osionos_workspace_members
     WHERE workspace_id = NEW.workspace_id;
    IF v_members > 200 THEN
      RETURN NEW;
    END IF;
    -- One set-based INSERT, never a per-peer loop: the peers are the other
    -- members of the workspace, the requester is the member who joined, and
    -- ON CONFLICT (pair_key) DO NOTHING keeps a pair that already has an edge
    -- (any status, either direction) exactly as it is — the bridge's
    -- on_conflict=pair_key with ignore-duplicates (bridge-social-core.mjs:294,
    -- :303). The bridge caps the batch at 500 peers (COLLEAGUE_INSERT_CAP,
    -- bridge-social-core.mjs:228); here the cap is the workspace size.
    INSERT INTO public.osionos_connections (requester_id, addressee_id, status, source, responded_at)
    SELECT NEW.user_id, m.user_id, 'accepted', 'colleague', now()
      FROM public.osionos_workspace_members m
     WHERE m.workspace_id = NEW.workspace_id
       AND m.user_id <> NEW.user_id
    ON CONFLICT (pair_key) DO NOTHING;
  EXCEPTION
    WHEN unique_violation OR foreign_key_violation OR check_violation OR not_null_violation THEN
      RAISE WARNING 'osionos: colleague edges skipped for workspace % (SQLSTATE %)',
        NEW.workspace_id, SQLSTATE;
  END;
  RETURN NEW;
END;
$fn$;

REVOKE ALL ON FUNCTION public.osionos_colleague_edges_on_join() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.osionos_colleague_edges_on_join() TO service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. The trigger, and the one-time backfill for the members that predate it
-- ─────────────────────────────────────────────────────────────────────────────
-- The backfill runs ONLY on the boot that first creates the trigger: the guard
-- tests pg_trigger BEFORE the CREATE TRIGGER, and the whole block (trigger +
-- backfill) is skipped when the trigger is already there. A replay inserts
-- nothing.
DO $do$
DECLARE
  v_inserted bigint := 0;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE tgrelid = 'public.osionos_workspace_members'::regclass
       AND tgname = 'osionos_workspace_members_colleague_edges_trg'
       AND NOT tgisinternal
  ) THEN
    CREATE TRIGGER osionos_workspace_members_colleague_edges_trg
      AFTER INSERT ON public.osionos_workspace_members
      FOR EACH ROW EXECUTE FUNCTION public.osionos_colleague_edges_on_join();

    -- The edges the trigger cannot create retroactively: every pair of members
    -- of every workspace with at most 200 members.
    -- The orientation is the trigger's: the requester is the member who joined
    -- LATER (public.osionos_workspace_members.created_at), and a tie on
    -- created_at is broken by the greater user_id — the member whose join would
    -- have fired the trigger. The backfill has no caller, so it takes the
    -- orientation from the join order instead.
    -- ON CONFLICT (pair_key) DO NOTHING is what makes a replay insert nothing:
    -- a pair that already has an edge keeps it, whatever its status or its
    -- direction.
    -- Caveat: the backfill is quadratic per workspace. A database with 1 000
    -- workspaces of 200 members inserts about 20 million rows; it runs once,
    -- on the boot that creates the trigger, and the NOTICE says how many.
    WITH small_workspaces AS (
      SELECT workspace_id
        FROM public.osionos_workspace_members
       GROUP BY workspace_id
      HAVING count(*) <= 200
    ), members AS (
      SELECT m.workspace_id, m.user_id, m.created_at
        FROM public.osionos_workspace_members m
        JOIN small_workspaces s ON s.workspace_id = m.workspace_id
    ), pairs AS (
      SELECT a.workspace_id,
             a.user_id AS user_a, a.created_at AS created_a,
             b.user_id AS user_b, b.created_at AS created_b
        FROM members a
        JOIN members b
          ON b.workspace_id = a.workspace_id
         AND b.user_id > a.user_id
    ), oriented AS (
      SELECT workspace_id,
             CASE WHEN (created_b, user_b) > (created_a, user_a) THEN user_b ELSE user_a END AS requester_id,
             CASE WHEN (created_b, user_b) > (created_a, user_a) THEN user_a ELSE user_b END AS addressee_id
        FROM pairs
    )
    INSERT INTO public.osionos_connections (requester_id, addressee_id, status, source, responded_at)
    SELECT requester_id, addressee_id, 'accepted', 'colleague', now()
      FROM oriented
    ON CONFLICT (pair_key) DO NOTHING;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    RAISE NOTICE 'osionos social scale: backfill inserted % colleague edge(s)', v_inserted;
  END IF;
END
$do$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. The feed numbers, in one call
-- ─────────────────────────────────────────────────────────────────────────────
-- osionos_feed_page_counts replaces the three reads the bridge made per post
-- card (bridge-feed.mjs:145-153 likes, :174-180 comments, :307-309 shares) with
-- one call that returns the four numbers the card shows.
-- SECURITY INVOKER: it reads the feed tables with the caller's rights, and the
-- bridge is the only caller (service_role). It is not SECURITY DEFINER, so it
-- hands nobody the owner's reach.
-- No SET search_path on purpose: PostgreSQL refuses to inline a function that
-- carries one, and inlining is what lets the load harness see the index scans
-- this function must use (scripts/verify/account-load). Every relation in the
-- body is named with its schema, so the caller's search_path cannot change it.
-- The whole file is one transaction, so the counts and the indexes below land
-- together or not at all.
-- Caveat: the counts are the rows the feed tables hold, so a count on a page
-- the viewer may not read still answers — the bridge hides the page, not the
-- count.
DO $do$
BEGIN
  IF to_regclass('public.osionos_feed_likes') IS NOT NULL
     AND to_regclass('public.osionos_feed_comments') IS NOT NULL
     AND to_regclass('public.osionos_feed_shares') IS NOT NULL THEN
    -- Each count must be served by an index on page_id. The three tables carry
    -- one already (osionos_feed_likes_page_idx and osionos_feed_comments_page_idx
    -- from osionos-chat-migration.sql:73-74, osionos_feed_shares_page_idx from
    -- osionos-feed-engagement-migration.sql:41); these lines make the file
    -- self-sufficient, and they are the ones the load budget reads.
    -- Caveat: the comments index is (page_id, created_at) upstream, so the
    -- IF NOT EXISTS below keeps THAT index and never replaces it with a
    -- narrower one.
    EXECUTE 'CREATE INDEX IF NOT EXISTS osionos_feed_likes_page_idx ON public.osionos_feed_likes (page_id)';
    EXECUTE 'CREATE INDEX IF NOT EXISTS osionos_feed_comments_page_idx ON public.osionos_feed_comments (page_id)';
    EXECUTE 'CREATE INDEX IF NOT EXISTS osionos_feed_shares_page_idx ON public.osionos_feed_shares (page_id)';

    EXECUTE $fn$
      CREATE OR REPLACE FUNCTION public.osionos_feed_page_counts(p_page_id uuid, p_viewer uuid)
        RETURNS TABLE (likes bigint, liked_by_viewer boolean, comments bigint, shares bigint)
        LANGUAGE sql STABLE SECURITY INVOKER AS $body$
        SELECT
          (SELECT count(*) FROM public.osionos_feed_likes l WHERE l.page_id = p_page_id),
          (SELECT count(*) > 0 FROM public.osionos_feed_likes l WHERE l.page_id = p_page_id AND l.user_id = p_viewer),
          (SELECT count(*) FROM public.osionos_feed_comments c WHERE c.page_id = p_page_id),
          (SELECT count(*) FROM public.osionos_feed_shares s WHERE s.page_id = p_page_id);
        $body$
    $fn$;
  END IF;
END
$do$;

-- The function is service_role's alone: the bridge calls it, and no other role
-- may reach the feed tables (models/osionos-feed-engagement-migration.sql:46).
DO $do$
BEGIN
  IF to_regprocedure('public.osionos_feed_page_counts(uuid, uuid)') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON FUNCTION public.osionos_feed_page_counts(uuid, uuid) FROM PUBLIC';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.osionos_feed_page_counts(uuid, uuid) TO service_role';
  END IF;
END
$do$;

-- PostgREST caches the schema; the new function is invisible to it until it
-- reloads.
NOTIFY pgrst, 'reload schema';

COMMIT;

-- DOWN (manual, in reverse order). Only valid while no bridge reads the
-- objects: the edges the trigger wrote stay, and the function's callers get a
-- 404 until it is back.
--   DROP TRIGGER IF EXISTS osionos_workspace_members_colleague_edges_trg ON public.osionos_workspace_members;
--   DROP FUNCTION IF EXISTS public.osionos_colleague_edges_on_join();
--   REVOKE EXECUTE ON FUNCTION public.osionos_feed_page_counts(uuid, uuid) FROM service_role;
--   DROP FUNCTION IF EXISTS public.osionos_feed_page_counts(uuid, uuid);
