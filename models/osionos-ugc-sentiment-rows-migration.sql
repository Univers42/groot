-- AI sentiment (M6p-1): the per-row projection of object databases, the queue
-- feed that scores it, and the teardown that keeps every derived row with its
-- source (C150-C155).
--
-- WHAT THIS IS
--   1. public.osionos_object_database_rows: one row per (database, row, AI
--      property), the text that the property names and its sha256. It is a
--      PROJECTION of the JSONB state, never a copy of user data that the app
--      reads back into the kit.
--   2. The trigger on public.osionos_object_databases that rebuilds the
--      projection from `state` after every save. This replaces the bridge RPC
--      of the design (B1.2): the bridge keeps writing the whole state, exactly
--      as it does today, and the database does the projection in the same
--      transaction.
--   3. The enqueue triggers on the projection (C146), and the settings trigger
--      that queues the projection on enable.
--   4. Delete, off and erase (C143): a projection row takes its score and job
--      with it, a deleted database takes every projection of it, and
--      ai_sentiment_erase_user(uuid) now also deletes the scores of the
--      databases the user owns.
--
-- THE FILE NAME
--   Named osionos-ugc-* so the runner's alphabetical pass applies it AFTER
--   osionos-object-databases-migration.sql (the state table) and
--   osionos-ugc-sentiment-migration.sql (the score and settings tables), and
--   BEFORE osionos-user-events-migration.sql (the erasure dispatcher).
--
-- CAVEAT: the projection reads the kit's `autofill` field on a property
--   (`{ kind: 'sentiment', sourcePropertyIds: [...] }`). The kit and the app
--   write that field in later slices; until then no state carries it and the
--   trigger's first jsonpath probe returns false (C150).
--
-- Idempotent: every statement is IF NOT EXISTS / CREATE OR REPLACE /
-- DROP ... IF EXISTS.

-- -----------------------------------------------------------------------------
-- 1. The projection table.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.osionos_object_database_rows (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id       UUID NOT NULL,
    db_key         TEXT NOT NULL CHECK (length(db_key) <= 128),
    workspace_id   UUID REFERENCES public.osionos_workspaces (id) ON DELETE CASCADE,
    row_id         TEXT NOT NULL CHECK (length(row_id) <= 80),
    property_id    TEXT NOT NULL CHECK (length(property_id) <= 80),
    visibility     TEXT NOT NULL DEFAULT 'private'
                   CHECK (visibility IN ('private', 'shared', 'public')),
    collaborators  JSONB NOT NULL DEFAULT '[]'::jsonb,
    scored_text    TEXT NOT NULL CHECK (length(scored_text) <= 8000),
    content_sha256 TEXT NOT NULL CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (owner_id, db_key, row_id, property_id),
    FOREIGN KEY (owner_id, db_key)
        REFERENCES public.osionos_object_databases (owner_id, db_key)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS osionos_object_database_rows_owner_idx
    ON public.osionos_object_database_rows (owner_id, db_key);
CREATE INDEX IF NOT EXISTS osionos_object_database_rows_workspace_idx
    ON public.osionos_object_database_rows (workspace_id);
CREATE INDEX IF NOT EXISTS osionos_object_database_rows_read_idx
    ON public.osionos_object_database_rows (db_key, property_id, row_id);

COMMENT ON TABLE public.osionos_object_database_rows IS
    'Projection of the AI-filled properties of an object database: one row per '
    '(owner, db_key, row_id, property_id), the chosen text and its sha256. Not '
    'user data: rebuilt from osionos_object_databases.state and deleted with '
    'its source (C143, C152). The visibility/collaborators columns are the '
    'four fields canReadPageRowAsMember reads, so the read route can use the '
    'same ACL as a page (C141, C154). service_role only (C145).';

-- -----------------------------------------------------------------------------
-- 2. Service-role-only storage (C145), as ai_sentiment.
-- -----------------------------------------------------------------------------
ALTER TABLE public.osionos_object_database_rows ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_object_database_rows_service_role_all ON public.osionos_object_database_rows;
CREATE POLICY osionos_object_database_rows_service_role_all ON public.osionos_object_database_rows
    FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.osionos_object_database_rows TO service_role;
REVOKE ALL ON public.osionos_object_database_rows FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3. The subject kind. ai_sentiment still has NO author column (C140).
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_sentiment
    DROP CONSTRAINT IF EXISTS ai_sentiment_subject_kind_check;
ALTER TABLE public.ai_sentiment
    ADD CONSTRAINT ai_sentiment_subject_kind_check
    CHECK (subject_kind IN ('page_comment', 'database_row'));

-- -----------------------------------------------------------------------------
-- 4. The projection trigger, on the state table. It replaces the bridge RPC
--    of the design: the bridge still writes the whole state in one statement,
--    and the projection lands in the same transaction. A failure here is a
--    WARNING and never fails the user's save (C151).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.osionos_object_databases_project_rows()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_has_autofill BOOLEAN;
    v_property     RECORD;
    v_page         RECORD;
    v_source_id    TEXT;
    v_value        JSONB;
    v_text         TEXT;
    v_sha          TEXT;
    v_row_ids      TEXT[] := ARRAY[]::TEXT[];
    v_property_ids TEXT[] := ARRAY[]::TEXT[];
BEGIN
    BEGIN
        -- With the jobs off nothing new is projected, but C143 still holds: a
        -- page gone from the state takes its row, and its score, with it.
        IF coalesce(current_setting('osionos.ai_jobs', true), '') = 'off' THEN
            DELETE FROM public.osionos_object_database_rows r
             WHERE r.owner_id = NEW.owner_id
               AND r.db_key = NEW.db_key
               AND NOT (coalesce(NEW.state -> 'pages', '{}'::jsonb) ? r.row_id);
            RETURN NEW;
        END IF;

        -- C150: when the new state names no AI property and the database has no
        -- projection, the whole trigger is this one jsonpath probe and one
        -- existence test.
        v_has_autofill := jsonb_path_exists(
            NEW.state,
            '$.databases.*.properties.*.autofill ? (@.kind == "sentiment")'
        );
        IF NOT v_has_autofill THEN
            IF NOT EXISTS (
                SELECT 1
                  FROM public.osionos_object_database_rows r
                 WHERE r.owner_id = NEW.owner_id
                   AND r.db_key = NEW.db_key
            ) THEN
                RETURN NEW;
            END IF;
        END IF;

        -- C153: only the properties whose config names the text, and only the
        -- pages of this database that are neither archived nor templates.
        FOR v_property IN
            SELECT p.key AS property_id, p.value AS property
              FROM jsonb_each(
                       coalesce(NEW.state -> 'databases' -> NEW.db_key -> 'properties', '{}'::jsonb)
                   ) AS p
             WHERE p.value -> 'autofill' ->> 'kind' = 'sentiment'
        LOOP
            FOR v_page IN
                SELECT pg.key AS row_id, pg.value AS page
                  FROM jsonb_each(coalesce(NEW.state -> 'pages', '{}'::jsonb)) AS pg
                 WHERE pg.value ->> 'databaseId' = NEW.db_key
                   AND coalesce((pg.value ->> 'archived')::boolean, false) = false
                   AND coalesce((pg.value ->> 'isTemplate')::boolean, false) = false
            LOOP
                IF length(v_page.row_id) > 80 OR length(v_property.property_id) > 80 THEN
                    CONTINUE;
                END IF;

                v_text := '';
                FOR v_source_id IN
                    SELECT s.value
                      FROM jsonb_array_elements_text(
                               v_property.property -> 'autofill' -> 'sourcePropertyIds'
                           ) WITH ORDINALITY AS s(value, ord)
                     WHERE s.ord <= 4
                     ORDER BY s.ord
                LOOP
                    v_value := v_page.page -> 'properties' -> v_source_id;
                    IF v_value IS NOT NULL AND jsonb_typeof(v_value) = 'string' THEN
                        IF v_text <> '' THEN
                            v_text := v_text || E'\n';
                        END IF;
                        v_text := v_text || (v_value #>> '{}');
                    END IF;
                END LOOP;

                v_text := left(btrim(v_text), 8000);
                IF v_text = '' THEN
                    CONTINUE;
                END IF;

                v_sha := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');

                -- C152: one row per (row, property), updated only when the sha
                -- changes, so the enqueue trigger fires only on a real edit.
                INSERT INTO public.osionos_object_database_rows AS r
                    (owner_id, db_key, workspace_id, row_id, property_id,
                     visibility, collaborators, scored_text, content_sha256)
                VALUES
                    (NEW.owner_id, NEW.db_key, NEW.workspace_id, v_page.row_id,
                     v_property.property_id, 'private', '[]'::jsonb, v_text, v_sha)
                ON CONFLICT (owner_id, db_key, row_id, property_id) DO UPDATE
                   SET workspace_id   = EXCLUDED.workspace_id,
                       visibility     = 'private',
                       collaborators  = '[]'::jsonb,
                       scored_text    = EXCLUDED.scored_text,
                       content_sha256 = EXCLUDED.content_sha256,
                       updated_at     = now()
                 WHERE r.content_sha256 IS DISTINCT FROM EXCLUDED.content_sha256;

                v_row_ids := v_row_ids || v_page.row_id;
                v_property_ids := v_property_ids || v_property.property_id;
            END LOOP;
        END LOOP;

        -- C152: projection = exactly the current state. Whatever is absent from
        -- the set just built goes, and its score/job go with it through the
        -- delete trigger below.
        DELETE FROM public.osionos_object_database_rows r
         WHERE r.owner_id = NEW.owner_id
           AND r.db_key = NEW.db_key
           AND NOT EXISTS (
               SELECT 1
                 FROM unnest(v_row_ids, v_property_ids) AS keep(row_id, property_id)
                WHERE keep.row_id = r.row_id
                  AND keep.property_id = r.property_id
           );
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'osionos_object_databases project rows skipped: %', SQLERRM;
    END;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS osionos_object_databases_project_rows ON public.osionos_object_databases;
CREATE TRIGGER osionos_object_databases_project_rows
    AFTER INSERT OR UPDATE OF state ON public.osionos_object_databases
    FOR EACH ROW
    EXECUTE FUNCTION public.osionos_object_databases_project_rows();

COMMENT ON FUNCTION public.osionos_object_databases_project_rows() IS
    'Rebuilds public.osionos_object_database_rows from the saved state: only '
    'properties with autofill.kind = sentiment, only non-archived non-template '
    'pages of the database, at most 4 string sources joined by newline, '
    'trimmed and cut to 8000 characters. Updates a row only when its sha '
    'changes; deletes the rows absent from the new state (C152, C153). Early '
    'exits on one jsonpath probe when nothing is projected (C150). An error is '
    'a WARNING and never fails the save (C151).';

-- -----------------------------------------------------------------------------
-- 5. Enqueue a score only for an opted-in workspace, only when the projection
--    really changed (C146). The INSERT trigger has no old_rows transition
--    table; the UPDATE one has both, so the function branches on TG_OP.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_jobs_enqueue_sentiment_database_rows()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_enqueued INTEGER := 0;
BEGIN
    IF coalesce(current_setting('osionos.ai_jobs', true), '') = 'off' THEN
        RETURN NULL;
    END IF;
    BEGIN
        IF TG_OP = 'UPDATE' THEN
            INSERT INTO public.ai_jobs (kind, subject_kind, subject_id, workspace_id, content_sha256)
            SELECT 'sentiment', 'database_row', n.id::text, n.workspace_id, n.content_sha256
              FROM new_rows n
              JOIN old_rows o ON o.id = n.id
              JOIN public.ai_sentiment_settings s
                ON s.workspace_id = n.workspace_id AND s.enabled
             WHERE o.content_sha256 IS DISTINCT FROM n.content_sha256
            ON CONFLICT (kind, subject_kind, subject_id) DO UPDATE
               SET content_sha256 = EXCLUDED.content_sha256,
                   run_after      = now(),
                   attempts       = 0,
                   last_error     = NULL,
                   enqueued_at    = now();
        ELSE
            INSERT INTO public.ai_jobs (kind, subject_kind, subject_id, workspace_id, content_sha256)
            SELECT 'sentiment', 'database_row', n.id::text, n.workspace_id, n.content_sha256
              FROM new_rows n
              JOIN public.ai_sentiment_settings s
                ON s.workspace_id = n.workspace_id AND s.enabled
            ON CONFLICT (kind, subject_kind, subject_id) DO UPDATE
               SET content_sha256 = EXCLUDED.content_sha256,
                   run_after      = now(),
                   attempts       = 0,
                   last_error     = NULL,
                   enqueued_at    = now();
        END IF;
        GET DIAGNOSTICS v_enqueued = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'ai_jobs sentiment database_row enqueue skipped: %', SQLERRM;
        v_enqueued := 0;
    END;
    IF v_enqueued > 0 THEN
        PERFORM pg_notify('ai_jobs', 'sentiment');
    END IF;
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS ai_jobs_enqueue_sentiment_database_rows_insert ON public.osionos_object_database_rows;
CREATE TRIGGER ai_jobs_enqueue_sentiment_database_rows_insert
    AFTER INSERT ON public.osionos_object_database_rows
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.ai_jobs_enqueue_sentiment_database_rows();

DROP TRIGGER IF EXISTS ai_jobs_enqueue_sentiment_database_rows_update ON public.osionos_object_database_rows;
CREATE TRIGGER ai_jobs_enqueue_sentiment_database_rows_update
    AFTER UPDATE ON public.osionos_object_database_rows
    REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.ai_jobs_enqueue_sentiment_database_rows();

COMMENT ON FUNCTION public.ai_jobs_enqueue_sentiment_database_rows() IS
    'Queues a projected database row for sentiment only when its workspace '
    'opted in (C138) and its sha changed. One notify per statement. Honours '
    'osionos.ai_jobs = off; a failure is a WARNING and never fails the row '
    'write (C146).';

-- -----------------------------------------------------------------------------
-- 6. A projection row deleted (by the sync or by the database cascade) takes
--    its score and its pending job with it (C143).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_sentiment_forget_database_rows()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    DELETE FROM public.ai_sentiment
     WHERE subject_kind = 'database_row' AND subject_id = OLD.id::text;
    DELETE FROM public.ai_jobs
     WHERE kind = 'sentiment' AND subject_kind = 'database_row'
       AND subject_id = OLD.id::text;
    RETURN OLD;
END $$;

DROP TRIGGER IF EXISTS ai_sentiment_forget_database_rows_delete ON public.osionos_object_database_rows;
CREATE TRIGGER ai_sentiment_forget_database_rows_delete
    AFTER DELETE ON public.osionos_object_database_rows
    FOR EACH ROW
    EXECUTE FUNCTION public.ai_sentiment_forget_database_rows();

-- A deleted database does not rely on the cascade's transition tables: the
-- BEFORE DELETE trigger removes every score and job of its projection rows.
CREATE OR REPLACE FUNCTION public.ai_sentiment_forget_database()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    DELETE FROM public.ai_sentiment s
     USING public.osionos_object_database_rows r
     WHERE r.owner_id = OLD.owner_id
       AND r.db_key = OLD.db_key
       AND s.subject_kind = 'database_row'
       AND s.subject_id = r.id::text;
    DELETE FROM public.ai_jobs j
     USING public.osionos_object_database_rows r
     WHERE r.owner_id = OLD.owner_id
       AND r.db_key = OLD.db_key
       AND j.kind = 'sentiment'
       AND j.subject_kind = 'database_row'
       AND j.subject_id = r.id::text;
    RETURN OLD;
END $$;

DROP TRIGGER IF EXISTS ai_sentiment_forget_database_delete ON public.osionos_object_databases;
CREATE TRIGGER ai_sentiment_forget_database_delete
    BEFORE DELETE ON public.osionos_object_databases
    FOR EACH ROW
    EXECUTE FUNCTION public.ai_sentiment_forget_database();

-- -----------------------------------------------------------------------------
-- 7. Switch on: queue the projection rows of the workspace, mirroring the
--    comment backfill of ai_sentiment_settings_switch. Switch off is already
--    covered by the existing function, which deletes ai_sentiment rows (both
--    kinds) and sentiment jobs by workspace_id in the same transaction.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_jobs_enqueue_sentiment_database_rows_enable()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_enqueued INTEGER := 0;
BEGIN
    IF coalesce(current_setting('osionos.ai_jobs', true), '') = 'off' THEN
        RETURN NULL;
    END IF;
    IF NOT (
        (TG_OP = 'INSERT' AND NEW.enabled)
        OR (TG_OP = 'UPDATE' AND NEW.enabled AND NOT OLD.enabled)
    ) THEN
        RETURN NULL;
    END IF;
    BEGIN
        INSERT INTO public.ai_jobs (kind, subject_kind, subject_id, workspace_id, content_sha256)
        SELECT 'sentiment', 'database_row', r.id::text, r.workspace_id, r.content_sha256
          FROM public.osionos_object_database_rows r
         WHERE r.workspace_id = NEW.workspace_id
        ON CONFLICT (kind, subject_kind, subject_id) DO UPDATE
           SET content_sha256 = EXCLUDED.content_sha256,
               run_after      = now(),
               attempts       = 0,
               last_error     = NULL,
               enqueued_at    = now();
        GET DIAGNOSTICS v_enqueued = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'ai_jobs sentiment database_row backfill skipped: %', SQLERRM;
        v_enqueued := 0;
    END;
    IF v_enqueued > 0 THEN
        PERFORM pg_notify('ai_jobs', 'sentiment');
    END IF;
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS ai_jobs_enqueue_sentiment_database_rows_enable ON public.ai_sentiment_settings;
CREATE TRIGGER ai_jobs_enqueue_sentiment_database_rows_enable
    AFTER INSERT OR UPDATE ON public.ai_sentiment_settings
    FOR EACH ROW
    EXECUTE FUNCTION public.ai_jobs_enqueue_sentiment_database_rows_enable();

COMMENT ON FUNCTION public.ai_jobs_enqueue_sentiment_database_rows_enable() IS
    'enabled -> true (or an enabled row inserted): queues every projection row '
    'of the workspace, as the comment backfill of the same transition does. '
    'Honours osionos.ai_jobs = off; a failure is a WARNING.';

-- -----------------------------------------------------------------------------
-- 8. Erasure (C143), dispatched from ai_erase_user(). The comment branch is
--    unchanged; the database-row branch is owner-based because a kit Page's
--    createdBy is a display string, not a user UUID.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_sentiment_erase_user(p_user UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    n INTEGER;
    m INTEGER;
BEGIN
    DELETE FROM public.ai_sentiment s
     USING public.osionos_page_comments c
     WHERE s.subject_kind = 'page_comment'
       AND s.subject_id = c.id::text
       AND c.author_id = p_user;
    GET DIAGNOSTICS n = ROW_COUNT;

    DELETE FROM public.ai_sentiment s
     USING public.osionos_object_database_rows r
     WHERE s.subject_kind = 'database_row'
       AND s.subject_id = r.id::text
       AND r.owner_id = p_user;
    GET DIAGNOSTICS m = ROW_COUNT;

    RETURN n + m;
END $$;

REVOKE ALL ON FUNCTION public.ai_sentiment_erase_user(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ai_sentiment_erase_user(UUID) TO service_role;

COMMENT ON FUNCTION public.ai_sentiment_erase_user(UUID) IS
    'Deletes the sentiment rows of the page comments the user authored and of '
    'the object databases the user owns; returns the count. Idempotent.';

NOTIFY pgrst, 'reload schema';
