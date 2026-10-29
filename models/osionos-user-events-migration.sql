-- ai_events — the recommender's log of what the user did, captured by triggers
-- that never fail a write.
--
-- WHAT THIS IS
--   A recommender cannot recommend from nothing: it needs a log of what the user
--   did (liked, reacted, shared, commented, favorited, connected) and where. This
--   file creates that log — public.ai_events — the triggers that fill it from the
--   engagement tables, the per-user switches that decide whether a row is
--   captured at all, and the maintenance that ages the partitions out.
--
-- WHY THE TRIGGERS NEVER FAIL A WRITE
--   The capture runs in the user's own transaction, so a bug in it would fail the
--   user's like. Every capture function therefore wraps its INSERT in ONE
--   BEGIN ... EXCEPTION WHEN OTHERS THEN RAISE WARNING ... END block: a failure
--   is a WARNING, the write goes through, and the log loses the row. The same
--   holds for the opt-out: a user who turned the capture off is never traced.
--   The user's write is never the thing that breaks.
--
-- WHAT IS CAPTURED
--   osionos_feed_likes      -> 'like'      (statement level, one row per new like)
--   osionos_feed_reactions  -> 'react'
--   osionos_feed_shares     -> 'share'
--   osionos_feed_comments   -> 'comment'   (the author)
--   osionos_page_comments   -> 'comment'   (the author)
--   osionos_page_favorites  -> 'favorite'
--   osionos_connections     -> 'connect'   (row level, on the accept of a MANUAL request)
--   NOT captured: blocks, reports, osionos_page_action_events,
--   osionos_page_configurations, messages, and every DELETE.
--
-- THE RULES THE CAPTURE FOLLOWS
--   * A feed row may name a page id with no row (a "ghost"): the capture JOINs
--     public.osionos_pages, so a ghost is skipped — never a NULL failure.
--   * An archived page is skipped (archived_at IS NOT NULL).
--   * A colleague edge (source = 'colleague', bulk-inserted 500 rows per
--     statement) is NEVER captured: only a MANUAL connection that turns
--     accepted is, and it writes two rows — one per side, each honouring that
--     side's own opt-out.
--   * The per-user switch is public.ai_personalization_settings: a row with
--     capture_explicit = false stops that user's capture. No row = the defaults
--     (capture_explicit = true). The consent state lives where the bridge reads
--     it (C48).
--   * A session can turn the capture off for itself: SET osionos.ai_events =
--     'off'. Every capture function checks it first — the seeds, the migrations
--     and the erasure use it too.
--
-- THE FILE NAME IS AN ORDERING FACT (read the runner's ORDERING note)
--   This file is models/osionos-user-events-migration.sql, NOT
--   models/osionos-ai-events-migration.sql: it must sort AFTER the tables it
--   captures from — osionos-chat-migration.sql (osionos_feed_likes,
--   osionos_feed_comments), osionos-comments-migration.sql
--   (osionos_page_comments), osionos-favorites-migration.sql
--   (osionos_page_favorites), osionos-feed-engagement-migration.sql
--   (osionos_feed_reactions, osionos_feed_shares) and osionos-social-
--   migration.sql (osionos_connections). A trigger on a table that does not
--   exist yet is a hard error, so the order is a correctness fact, not a style
--   choice. The alphabetical pass is the only slot both runners share
--   (scripts/apply-models-migrations.sh and the ledger runner
--   scripts/apply-models.sh), and "osionos-ai-..." sorts before all of them.
--
-- PARTITIONS (C52)
--   public.ai_events is PARTITION BY RANGE (ts): ai_events_default (the DEFAULT
--   partition, always there) and ai_events_yYYYYMM for the current month and
--   the next two. The monthly partitions are created in a DO block from
--   date_trunc('month', now()), so a boot in a new month creates the new one.
--   A row whose ts has no partition lands in the DEFAULT partition. That is the
--   health signal, not an error: public.ai_events_default_rows() counts them
--   and public.ai_events_maintain() creates the missing months.
--
--   THE RUNNER FOR THE MONTHLY PARTITIONS IS NOT WRITTEN YET. The named runner
--   that calls public.ai_events_maintain() once a day is a later service slice.
--   Until it exists, the partition set only grows with the boots: a month
--   passes, its partition stays, and the data in it ages. The documented
--   maximum age of a row in a monthly partition is therefore about 210 days —
--   a partition is created at the start of its month, and ai_events_maintain()
--   drops it once its upper bound is older than the 180-day retention — plus
--   whatever the DEFAULT partition holds until that runner exists. A later
--   slice MUST write that runner; without it the log grows without bound.
--
-- IDEMPOTENT
--   Every statement is IF NOT EXISTS / DROP ... IF EXISTS / CREATE OR REPLACE
--   shaped, so the file is replayed on every boot. It never deletes or rewrites
--   a row of ai_events; the only DELETE is inside ai_erase_user(), which a
--   person asked for.

-- -----------------------------------------------------------------------------
-- 1. ai_personalization_settings — the server-side home of the opt-out and the
--    consent. No row = the defaults. The bridge reads it; the capture reads it.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_personalization_settings (
    user_id          UUID PRIMARY KEY,
    capture_explicit BOOLEAN NOT NULL DEFAULT true,
    beacon_consent   BOOLEAN NOT NULL DEFAULT false,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.ai_personalization_settings IS
    'The per-user personalization switches. capture_explicit = false stops the '
    'ai_events capture for that user; beacon_consent = true is the consent the '
    'beacon needs. No row = the defaults (capture_explicit = true, '
    'beacon_consent = false). The consent state lives here, where the bridge '
    'reads it (C48).';

-- -----------------------------------------------------------------------------
-- 2. ai_events — the log. Ids, enums, numbers and a timestamp only: no text
--    payload, no vector, no profile. A row says WHO did WHAT to WHICH item, in
--    which workspace, at which surface, and with which weight.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_events (
    id           BIGINT GENERATED ALWAYS AS IDENTITY,
    ts           TIMESTAMPTZ NOT NULL DEFAULT now(),
    user_id      UUID NOT NULL,
    item_kind    TEXT NOT NULL CHECK (item_kind IN ('page','user')),
    item_id      UUID NOT NULL,
    workspace_id UUID,
    event        TEXT NOT NULL CHECK (event IN ('like','react','share','comment','favorite','connect','view','impression','click','not_interested')),
    weight       REAL NOT NULL DEFAULT 1,
    surface      TEXT NOT NULL DEFAULT 'trigger' CHECK (surface IN ('trigger','feed','home','search','people','page')),
    rec_id       UUID,
    rank         SMALLINT,
    dwell_ms     INTEGER CHECK (dwell_ms BETWEEN 0 AND 1800000),
    is_synthetic BOOLEAN NOT NULL DEFAULT false,
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);

COMMENT ON TABLE public.ai_events IS
    'The recommender''s log of what the user did. Partitioned by RANGE (ts): '
    'ai_events_default and the monthly ai_events_yYYYYMM. Filled by the '
    'capture triggers on the engagement tables, never by a DELETE. Capture never '
    'fails the write it observes: a failure is a WARNING.';

COMMENT ON COLUMN public.ai_events.surface IS
    'Where the event happened. ''trigger'' = a capture trigger on an engagement '
    'table; the other values are for the surfaces the service writes itself.';

COMMENT ON COLUMN public.ai_events.is_synthetic IS
    'True for a row the service wrote for a test or a replay. A synthetic row is '
    'never read as a real preference.';

-- The two reads the recommender makes: a user's history, and an item's history.
CREATE INDEX IF NOT EXISTS ai_events_user_ts_idx ON public.ai_events (user_id, ts DESC);
CREATE INDEX IF NOT EXISTS ai_events_item_ts_idx ON public.ai_events (item_id, ts DESC);

-- -----------------------------------------------------------------------------
-- 3. The partitions: the DEFAULT one (always) and the current month plus the
--    next two. A partition is a table of its own: it inherits neither the
--    parent's grants nor its RLS flag, so each one is closed here, on every
--    replay — the same loop as the HASH partitions of
--    osionos-ai-rag-migration.sql:80-86.
--
--    The creation of a monthly partition is guarded: the DEFAULT partition may
--    already hold a row of that month (a row with a future ts, written before
--    the partition existed), and Postgres then refuses the new partition. That
--    refusal is a WARNING, not a failure: the rows stay in the DEFAULT
--    partition, which is exactly what ai_events_default_rows() reports.
--
--    The partitions are created with their schema spelled out ("%I.%I"), never
--    bare: a relation created without a schema goes into the FIRST schema of
--    the search_path, and the live database's search_path is "auth, public"
--    (grobase's 001_initial_schema.sql sets it on the postgres role). A bare
--    CREATE TABLE would have put every partition in the auth schema.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    i       INT;
    m_start DATE;
    m_name  TEXT;
BEGIN
    IF to_regclass('public.ai_events_default') IS NULL THEN
        -- The name goes through format(): a literal "create table <name>" in this
        -- file would be read by the runner's pending() as a table this file
        -- creates, and models/ would never converge.
        EXECUTE format('CREATE TABLE %I.%I PARTITION OF public.ai_events DEFAULT', 'public', 'ai_events_default');
    END IF;
    EXECUTE 'ALTER TABLE public.ai_events_default ENABLE ROW LEVEL SECURITY';
    EXECUTE 'REVOKE ALL ON public.ai_events_default FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT SELECT, INSERT, DELETE ON public.ai_events_default TO service_role';

    FOR i IN 0..2 LOOP
        m_start := (date_trunc('month', now()) + (i * INTERVAL '1 month'))::date;
        m_name  := 'ai_events_y' || to_char(m_start, 'YYYYMM');
        IF to_regclass('public.' || m_name) IS NULL THEN
            BEGIN
                EXECUTE format('CREATE TABLE %I.%I PARTITION OF public.ai_events FOR VALUES FROM (%L) TO (%L)',
                               'public', m_name, m_start, (m_start + INTERVAL '1 month')::date);
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'ai_events: % not created: %', m_name, SQLERRM;
            END;
        END IF;
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', m_name);
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', m_name);
        EXECUTE format('GRANT SELECT, INSERT, DELETE ON public.%I TO service_role', m_name);
    END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 4. The maintenance: public.ai_events_maintain() ages the partitions out, and
--    public.ai_events_default_rows() is the health signal of the DEFAULT
--    partition. Both are SECURITY DEFINER (the service calls them, not a
--    person) and both are executable by service_role only.
--
--    The daily runner that calls ai_events_maintain() is a LATER SERVICE SLICE
--    and is not written yet. Until it exists, no partition is ever dropped and
--    the log only grows.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_events_maintain(p_retention interval DEFAULT '180 days')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_created TEXT[] := ARRAY[]::TEXT[];
    v_dropped TEXT[] := ARRAY[]::TEXT[];
    m_start   DATE;
    m_name    TEXT;
    m_upper   DATE;
    i         INT;
    r         RECORD;
BEGIN
    -- The current month and the next two, if they are missing.
    FOR i IN 0..2 LOOP
        m_start := (date_trunc('month', now()) + (i * INTERVAL '1 month'))::date;
        m_name  := 'ai_events_y' || to_char(m_start, 'YYYYMM');
        IF to_regclass('public.' || m_name) IS NULL THEN
            BEGIN
                -- The schema is spelled out: a relation created without one goes
                -- into the first schema of the search_path. This function's own
                -- search_path is 'public, pg_temp', but the partition has to be
                -- in public whatever a caller does to the session.
                EXECUTE format('CREATE TABLE %I.%I PARTITION OF public.ai_events FOR VALUES FROM (%L) TO (%L)',
                               'public', m_name, m_start, (m_start + INTERVAL '1 month')::date);
                EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', m_name);
                EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', m_name);
                EXECUTE format('GRANT SELECT, INSERT, DELETE ON public.%I TO service_role', m_name);
                v_created := array_append(v_created, m_name);
            EXCEPTION WHEN OTHERS THEN
                -- The DEFAULT partition holds a row of that month. The month
                -- stays in the DEFAULT partition (the health signal says so) and
                -- the partition is not created. The log is never lost.
                RAISE WARNING 'ai_events_maintain: % not created: %', m_name, SQLERRM;
            END;
        END IF;
    END LOOP;

    -- The monthly partitions whose upper bound is older than the retention.
    -- The DEFAULT partition is never in this set: its name does not match, and
    -- it is the catch-all, not a month.
    FOR r IN
        SELECT c.relname
          FROM pg_class c
          JOIN pg_namespace ns ON ns.oid = c.relnamespace
         WHERE ns.nspname = 'public'
           AND c.relkind = 'r'
           AND c.relispartition
           AND c.relname LIKE 'ai\_events\_y%'
    LOOP
        m_upper := (to_date(right(r.relname, 6), 'YYYYMM') + INTERVAL '1 month')::date;
        IF m_upper < (now() - p_retention)::date THEN
            EXECUTE format('DROP TABLE public.%I', r.relname);
            v_dropped := array_append(v_dropped, r.relname);
        END IF;
    END LOOP;

    RETURN jsonb_build_object('created', to_jsonb(v_created), 'dropped', to_jsonb(v_dropped));
END $$;

COMMENT ON FUNCTION public.ai_events_maintain(interval) IS
    'Creates the current month and the next two monthly partitions when they are '
    'missing, drops the monthly partitions whose upper bound is older than the '
    'retention (default 180 days), and returns {created:[...], dropped:[...]}. '
    'The DEFAULT partition is never dropped. The daily runner that calls this is '
    'a later service slice: until it exists, no partition is ever dropped.';

CREATE OR REPLACE FUNCTION public.ai_events_default_rows()
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    n BIGINT;
BEGIN
    IF to_regclass('public.ai_events_default') IS NULL THEN
        RETURN 0;
    END IF;
    EXECUTE 'SELECT count(*) FROM public.ai_events_default' INTO n;
    RETURN n;
END $$;

COMMENT ON FUNCTION public.ai_events_default_rows() IS
    'The number of rows in the DEFAULT partition: the health signal of the '
    'partitioning (C52). A healthy month holds 0 — every row has its own '
    'monthly partition. A non-zero number means a month had no partition when '
    'the row was written.';

-- -----------------------------------------------------------------------------
-- 5. The capture. ONE function per source table, all SECURITY DEFINER with a
--    fixed search_path, all starting with the off switch, all wrapping their
--    INSERT in ONE exception block (never one per row).
--
--    Why one function per table: a trigger's transition table is visible to
--    its own function only, and plpgsql caches the plan of a statement per
--    function. A single function shared by six triggers would reuse the plan
--    of the first one against the next one's transition table.
--
--    The six statement-level triggers see the whole statement (REFERENCING NEW
--    TABLE), so a bulk insert is captured in one statement, not one per row.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_events_capture_feed_likes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF coalesce(current_setting('osionos.ai_events', true), '') = 'off' THEN
        RETURN NULL;
    END IF;
    BEGIN
        INSERT INTO public.ai_events (user_id, item_kind, item_id, workspace_id, event)
        SELECT n.user_id, 'page', n.page_id, p.workspace_id, 'like'
          FROM new_rows n
          JOIN public.osionos_pages p ON p.id = n.page_id
         WHERE p.archived_at IS NULL
           AND NOT EXISTS (
                 SELECT 1 FROM public.ai_personalization_settings s
                  WHERE s.user_id = n.user_id AND NOT s.capture_explicit);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'ai_events capture skipped: %', SQLERRM;
    END;
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS ai_events_capture_feed_likes ON public.osionos_feed_likes;
CREATE TRIGGER ai_events_capture_feed_likes
    AFTER INSERT ON public.osionos_feed_likes
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.ai_events_capture_feed_likes();

CREATE OR REPLACE FUNCTION public.ai_events_capture_feed_reactions()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF coalesce(current_setting('osionos.ai_events', true), '') = 'off' THEN
        RETURN NULL;
    END IF;
    BEGIN
        INSERT INTO public.ai_events (user_id, item_kind, item_id, workspace_id, event)
        SELECT n.user_id, 'page', n.page_id, p.workspace_id, 'react'
          FROM new_rows n
          JOIN public.osionos_pages p ON p.id = n.page_id
         WHERE p.archived_at IS NULL
           AND NOT EXISTS (
                 SELECT 1 FROM public.ai_personalization_settings s
                  WHERE s.user_id = n.user_id AND NOT s.capture_explicit);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'ai_events capture skipped: %', SQLERRM;
    END;
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS ai_events_capture_feed_reactions ON public.osionos_feed_reactions;
CREATE TRIGGER ai_events_capture_feed_reactions
    AFTER INSERT ON public.osionos_feed_reactions
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.ai_events_capture_feed_reactions();

CREATE OR REPLACE FUNCTION public.ai_events_capture_feed_shares()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF coalesce(current_setting('osionos.ai_events', true), '') = 'off' THEN
        RETURN NULL;
    END IF;
    BEGIN
        INSERT INTO public.ai_events (user_id, item_kind, item_id, workspace_id, event)
        SELECT n.user_id, 'page', n.page_id, p.workspace_id, 'share'
          FROM new_rows n
          JOIN public.osionos_pages p ON p.id = n.page_id
         WHERE p.archived_at IS NULL
           AND NOT EXISTS (
                 SELECT 1 FROM public.ai_personalization_settings s
                  WHERE s.user_id = n.user_id AND NOT s.capture_explicit);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'ai_events capture skipped: %', SQLERRM;
    END;
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS ai_events_capture_feed_shares ON public.osionos_feed_shares;
CREATE TRIGGER ai_events_capture_feed_shares
    AFTER INSERT ON public.osionos_feed_shares
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.ai_events_capture_feed_shares();

CREATE OR REPLACE FUNCTION public.ai_events_capture_feed_comments()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF coalesce(current_setting('osionos.ai_events', true), '') = 'off' THEN
        RETURN NULL;
    END IF;
    BEGIN
        INSERT INTO public.ai_events (user_id, item_kind, item_id, workspace_id, event)
        SELECT n.author_id, 'page', n.page_id, p.workspace_id, 'comment'
          FROM new_rows n
          JOIN public.osionos_pages p ON p.id = n.page_id
         WHERE p.archived_at IS NULL
           AND NOT EXISTS (
                 SELECT 1 FROM public.ai_personalization_settings s
                  WHERE s.user_id = n.author_id AND NOT s.capture_explicit);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'ai_events capture skipped: %', SQLERRM;
    END;
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS ai_events_capture_feed_comments ON public.osionos_feed_comments;
CREATE TRIGGER ai_events_capture_feed_comments
    AFTER INSERT ON public.osionos_feed_comments
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.ai_events_capture_feed_comments();

CREATE OR REPLACE FUNCTION public.ai_events_capture_page_comments()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF coalesce(current_setting('osionos.ai_events', true), '') = 'off' THEN
        RETURN NULL;
    END IF;
    BEGIN
        INSERT INTO public.ai_events (user_id, item_kind, item_id, workspace_id, event)
        SELECT n.author_id, 'page', n.page_id, p.workspace_id, 'comment'
          FROM new_rows n
          JOIN public.osionos_pages p ON p.id = n.page_id
         WHERE p.archived_at IS NULL
           AND NOT EXISTS (
                 SELECT 1 FROM public.ai_personalization_settings s
                  WHERE s.user_id = n.author_id AND NOT s.capture_explicit);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'ai_events capture skipped: %', SQLERRM;
    END;
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS ai_events_capture_page_comments ON public.osionos_page_comments;
CREATE TRIGGER ai_events_capture_page_comments
    AFTER INSERT ON public.osionos_page_comments
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.ai_events_capture_page_comments();

CREATE OR REPLACE FUNCTION public.ai_events_capture_page_favorites()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF coalesce(current_setting('osionos.ai_events', true), '') = 'off' THEN
        RETURN NULL;
    END IF;
    BEGIN
        INSERT INTO public.ai_events (user_id, item_kind, item_id, workspace_id, event)
        SELECT n.user_id, 'page', n.page_id, p.workspace_id, 'favorite'
          FROM new_rows n
          JOIN public.osionos_pages p ON p.id = n.page_id
         WHERE p.archived_at IS NULL
           AND NOT EXISTS (
                 SELECT 1 FROM public.ai_personalization_settings s
                  WHERE s.user_id = n.user_id AND NOT s.capture_explicit);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'ai_events capture skipped: %', SQLERRM;
    END;
    RETURN NULL;
END $$;

-- The favorite's rows are dropped with the page (ON DELETE CASCADE): the
-- trigger is AFTER INSERT only, so a page delete captures nothing.
DROP TRIGGER IF EXISTS ai_events_capture_page_favorites ON public.osionos_page_favorites;
CREATE TRIGGER ai_events_capture_page_favorites
    AFTER INSERT ON public.osionos_page_favorites
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.ai_events_capture_page_favorites();

-- The connection is captured on the ACCEPT of a MANUAL request, row by row: two
-- rows, one per side (the requester and the addressee), each honouring that
-- side's own opt-out. A colleague edge (source = 'colleague', bulk-inserted
-- 500 rows per statement) is never captured: the trigger is on UPDATE, and the
-- WHEN clause asks for a manual edge.
CREATE OR REPLACE FUNCTION public.ai_events_capture_connections()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF coalesce(current_setting('osionos.ai_events', true), '') = 'off' THEN
        RETURN NULL;
    END IF;
    BEGIN
        INSERT INTO public.ai_events (user_id, item_kind, item_id, workspace_id, event)
        SELECT side.user_id, 'user', side.peer, NULL, 'connect'
          FROM (VALUES (NEW.requester_id, NEW.addressee_id),
                       (NEW.addressee_id, NEW.requester_id)) AS side(user_id, peer)
         WHERE NOT EXISTS (
                 SELECT 1 FROM public.ai_personalization_settings s
                  WHERE s.user_id = side.user_id AND NOT s.capture_explicit);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'ai_events capture skipped: %', SQLERRM;
    END;
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS ai_events_capture_connections ON public.osionos_connections;
CREATE TRIGGER ai_events_capture_connections
    AFTER UPDATE OF status ON public.osionos_connections
    FOR EACH ROW
    WHEN (NEW.status = 'accepted'
          AND OLD.status IS DISTINCT FROM 'accepted'
          AND NEW.source = 'manual')
    EXECUTE FUNCTION public.ai_events_capture_connections();

COMMENT ON FUNCTION public.ai_events_capture_feed_likes() IS
    'Captures a like as one ai_events row. Statement level, so a bulk insert is '
    'one statement, not one per row. A ghost page id (no row in osionos_pages) '
    'is skipped by the JOIN; an archived page is skipped. The user''s opt-out '
    'wins. A failure is a WARNING: the like never fails because of the capture.';

COMMENT ON FUNCTION public.ai_events_capture_connections() IS
    'Captures the accept of a MANUAL connection as two ai_events rows, one per '
    'side, each honouring that side''s own opt-out. A colleague edge is never '
    'captured.';

-- -----------------------------------------------------------------------------
-- 6. The grants: service_role only. ai_* is outside the osionos_* catalog pass
--    of osionos-service-role-only-migration.sql, so the REVOKE happens here.
--
--    ai_events is append-only: the bridge SELECTs, INSERTs and DELETEs (an
--    erasure), it never UPDATEs a row. ai_personalization_settings is a
--    preference the bridge reads, writes and updates — and never deletes: the
--    erasure keeps that row (see ai_erase_user below).
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_personalization_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_events_service_role_all ON public.ai_events;
CREATE POLICY ai_events_service_role_all ON public.ai_events
    FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

DROP POLICY IF EXISTS ai_personalization_settings_service_role_all ON public.ai_personalization_settings;
CREATE POLICY ai_personalization_settings_service_role_all ON public.ai_personalization_settings
    FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

GRANT SELECT, INSERT, DELETE ON public.ai_events TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.ai_personalization_settings TO service_role;

REVOKE ALL ON public.ai_events FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.ai_personalization_settings FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 7. Erasure and export (C54).
--
--    The guard (SET osionos.ai_events = 'off') is on the capture functions and
--    on the erasure — the two that write. The read-only functions (the export,
--    the health signal) and the maintenance do not carry it: they must answer
--    even in a session that turned the capture off.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_erase_user(p_user UUID)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    n BIGINT;
    m BIGINT;
    f BIGINT;
BEGIN
    -- The capture is off for this transaction: an erasure writes no event.
    PERFORM set_config('osionos.ai_events', 'off', true);
    DELETE FROM public.ai_events WHERE user_id = p_user;
    GET DIAGNOSTICS n = ROW_COUNT;
    -- The moderation audit is erased too, when that file is applied
    -- (models/osionos-ugc-moderation-migration.sql). The call is DYNAMIC and
    -- GUARDED: this file stays valid on a database that never had the
    -- moderation migration, and the two files work in either order.
    IF to_regprocedure('public.ai_moderation_erase_user(uuid)') IS NOT NULL THEN
        EXECUTE 'SELECT public.ai_moderation_erase_user($1)' INTO m USING p_user;
    END IF;
    -- The recommender's FACTORS are erased too, when that file is applied
    -- (models/osionos-rec-factors-migration.sql): the user's factor vector in
    -- every model, and the rows where the user is a suggested person. Same
    -- DYNAMIC and GUARDED call: this file stays valid on a database that
    -- never had the factors migration, and the two files work in either
    -- order - the factors file references nothing of this one.
    IF to_regprocedure('public.ai_rec_erase_user(uuid)') IS NOT NULL THEN
        EXECUTE 'SELECT public.ai_rec_erase_user($1)' INTO f USING p_user;
    END IF;
    -- The personal access tokens go too (C113), when that file is applied
    -- (models/osionos-ai-access-tokens-migration.sql). Same DYNAMIC and
    -- GUARDED call; its count is discarded like the two above.
    IF to_regprocedure('public.ai_access_tokens_erase_user(uuid)') IS NOT NULL THEN
        EXECUTE 'SELECT public.ai_access_tokens_erase_user($1)' INTO f USING p_user;
    END IF;
    -- The user's AI memories and their audit go too (P5d-1), when that file is
    -- applied (models/osionos-ai-user-memory-migration.sql). Same DYNAMIC and
    -- GUARDED call; its count is discarded.
    IF to_regprocedure('public.ai_memory_erase_user(uuid)') IS NOT NULL THEN
        EXECUTE 'SELECT public.ai_memory_erase_user($1)' INTO f USING p_user;
    END IF;
    -- The sentiment scores of the user's page comments go too (C143), when
    -- that file is applied (models/osionos-ugc-sentiment-migration.sql). Same
    -- DYNAMIC and GUARDED call; its count is discarded like the others.
    IF to_regprocedure('public.ai_sentiment_erase_user(uuid)') IS NOT NULL THEN
        EXECUTE 'SELECT public.ai_sentiment_erase_user($1)' INTO f USING p_user;
    END IF;
    -- The user's remote MCP servers and their tool snapshots go too (C285),
    -- when that file is applied (models/osionos-ai-mcp-client-migration.sql).
    -- Same DYNAMIC and GUARDED call; its count is discarded.
    IF to_regprocedure('public.ai_mcp_erase_user(uuid)') IS NOT NULL THEN
        EXECUTE 'SELECT public.ai_mcp_erase_user($1)' INTO f USING p_user;
    END IF;
    -- The user's custom agents go (user scope) or are tombstoned (workspace
    -- scope, settings, audit) too (C338), when that file is applied
    -- (models/osionos-ai-runs-agents-migration.sql). Same DYNAMIC and GUARDED
    -- call; its count is discarded.
    IF to_regprocedure('public.ai_agents_erase_user(uuid)') IS NOT NULL THEN
        EXECUTE 'SELECT public.ai_agents_erase_user($1)' INTO f USING p_user;
    END IF;
    -- The user's own AI context items (skills, rules) go and the user is
    -- tombstoned as the author of workspace rules (C1007), when that file is
    -- applied (models/osionos-ai-context-migration.sql). Same DYNAMIC and
    -- GUARDED call; its count is discarded.
    IF to_regprocedure('public.ai_context_erase_user(uuid)') IS NOT NULL THEN
        EXECUTE 'SELECT public.ai_context_erase_user($1)' INTO f USING p_user;
    END IF;
    -- The user is tombstoned in the workspace web switch and its audit too
    -- (C374), when that file is applied (models/osionos-ai-web-migration.sql).
    -- Same DYNAMIC and GUARDED call; its count is discarded.
    IF to_regprocedure('public.ai_web_erase_user(uuid)') IS NOT NULL THEN
        EXECUTE 'SELECT public.ai_web_erase_user($1)' INTO f USING p_user;
    END IF;
    -- The count is the number of ai_events rows erased: the erasures are
    -- separate tables with separate counts, and this function answers for its own. The
    -- moderation count (m) and the factor and token counts (f) are deliberately
    -- DISCARDED.
    RETURN n;
END $$;

COMMENT ON FUNCTION public.ai_erase_user(UUID) IS
    'Erases every ai_events row of the user (every partition, through the '
    'parent) and returns the number of rows erased. Idempotent: a second call '
    'erases 0. The capture is turned off for the transaction, so the erasure '
    'writes no event of its own. The ai_personalization_settings row of the '
    'user is KEPT: it is a preference, not activity, and keeping it is what '
    'makes the opt-out survive the erasure. The moderation audit is erased '
    'too, when models/osionos-ugc-moderation-migration.sql is applied: the '
    'call is dynamic and guarded, so this file stays valid without it. '
    'THE FACTORS ARE COVERED NOW: the recommender''s factor vectors are '
    'erased through ai_rec_erase_user() when '
    'models/osionos-rec-factors-migration.sql is applied (the call is dynamic '
    'and guarded, so this file stays valid without it). PROFILE VECTORS AND '
    'SLATES DO NOT EXIST YET: a later slice MUST add their tables here, or '
    'the erasure leaves the derived data behind.';

CREATE OR REPLACE FUNCTION public.ai_export_user(p_user UUID)
RETURNS SETOF public.ai_events
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT e.*
      FROM public.ai_events e
     WHERE e.user_id = p_user
     ORDER BY e.ts;
$$;

COMMENT ON FUNCTION public.ai_export_user(UUID) IS
    'Every ai_events row of the user, oldest first, for a data export. '
    'THE FACTORS ARE EXPORTED BY ai_rec_export_user(), in '
    'models/osionos-rec-factors-migration.sql, WHEN THAT FILE IS APPLIED: the '
    'recommender''s derived vectors are a SEPARATE function, because this one '
    'returns SETOF ai_events - the row shape the bridge reads - and a JSONB '
    'object would break that caller. The bridge calls BOTH. PROFILE VECTORS '
    'AND SLATES DO NOT EXIST YET: a later slice MUST add them here too.';

-- The functions are service_role only: PUBLIC''s default EXECUTE would let any
-- PostgREST role call the erasure.
REVOKE ALL ON FUNCTION public.ai_events_maintain(interval) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_events_default_rows() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_erase_user(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_export_user(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ai_events_maintain(interval) TO service_role;
GRANT EXECUTE ON FUNCTION public.ai_events_default_rows() TO service_role;
GRANT EXECUTE ON FUNCTION public.ai_erase_user(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.ai_export_user(UUID) TO service_role;

-- A trigger function cannot be called directly, but PUBLIC's default EXECUTE
-- on it is closed anyway: the same service_role-only rule for every function
-- this file creates.
REVOKE ALL ON FUNCTION public.ai_events_capture_feed_likes() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_events_capture_feed_reactions() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_events_capture_feed_shares() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_events_capture_feed_comments() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_events_capture_page_comments() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_events_capture_page_favorites() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_events_capture_connections() FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
