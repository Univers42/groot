-- The recommender's model, in Postgres: a registry of models with ONE
-- champion, the factor vectors searched by inner product, a promotion that
-- refuses a worse model, and the erasure of a user's derived vectors.
--
-- WHAT THIS IS
--   M3c-1 (services/osionos-ml/) trains an implicit ALS (iALS) recommender
--   offline and reports nDCG@10 on a labelled synthetic log. The trained
--   model has to live in Postgres: the Node service serves it from there, and
--   a model that only exists in a Python process is a model nobody else can
--   read. This file creates six things:
--     1. the REGISTRY (public.ai_rec_models): one row per trained model, with
--        its hyperparameters, its offline metrics and its status;
--     2. the FACTORS (public.ai_rec_item_factors and
--        public.ai_rec_user_factors): the item and user vectors, searched by
--        inner product over a pgvector HNSW index;
--     3. the PROMOTION (public.ai_rec_promote): one champion at a time, and a
--        candidate that is worse than the champion does not replace it;
--     4. the PRUNE (public.ai_rec_prune): the old retired models and the
--        stale candidates go;
--     5. the ERASURE (public.ai_rec_erase_user): a user's derived vectors go
--        with the user;
--     6. the EXPORT (public.ai_rec_export_user): a user's data export carries
--        those same derived vectors, unpadded to their model's factor count.
--
-- WHY THE FACTORS ARE 64-DIMENSIONAL, ALWAYS
--   M3c-1 tunes the factor count in {8, 16, 32, 64}, and the model row says
--   how many factors the model really has. An HNSW index has ONE dimension
--   for its whole life: it is built on a column of a fixed type, and a column
--   of a fixed type cannot hold a 16-dim vector and a 64-dim vector. So every
--   vector is stored as vector(64), ZERO-PADDED when the model has fewer
--   factors.
--
--   The padding is not a compromise, it is exact. An inner product is a sum of
--   coordinate products, and the product of a real coordinate and a zero is
--   zero, so (u ⋅ i) over the padded vectors EQUALS (u ⋅ i) over the
--   unpadded ones. A 16-factor model and a 64-factor model live in the same
--   column and the same index serves both. The model row keeps the true count
--   (factors SMALLINT), so a reader knows how many of the 64 numbers are
--   real and may read the model row before it reads a vector.
--
--   The verify script proves the equality, not the intention: it computes a
--   16-dim dot product OUTSIDE the database and compares it with the inner
--   product the database computes over the padded pair.
--
-- WHY ONE CHAMPION
--   The service serves ONE model: the champion. A second champion makes "the
--   model" ambiguous, and two promoters racing would leave two. The unique
--   partial index on (status) WHERE status = 'champion' makes the invariant a
--   property of the DATABASE and not of the code that writes it: the second
--   champion is refused with 23505 whatever wrote it.
--
-- WHY A PROMOTION REFUSES A WORSE MODEL
--   The offline numbers are the only comparison there is: there is no online
--   A/B yet, so the registry holds what the offline evaluation measured
--   (metrics->>'ndcg10') and the promotion refuses a candidate whose nDCG@10
--   is LOWER than the champion's. Three refusals, all with SQLSTATE P0001 and
--   a message that says why:
--     * the model is not a candidate (it is already the champion, or retired);
--     * the model is SYNTHETIC and the champion is not: a synthetic model
--       (trained on a generated log) never replaces a real one, whatever its
--       score says — a synthetic number is not a measurement of the users;
--     * the model's nDCG@10 is lower than the champion's, unless p_force says
--       so. p_force overrides the METRIC comparison only: a synthetic model
--       never replaces a real one and a retired model never comes back, both
--       with or without it.
--   A model with no ndcg10 in its metrics counts as 0: an unmeasured model
--   is not known to be better than a measured one.
--
-- WHY THE ERASURE IS HERE
--   The events file says it plainly: "FACTORS, PROFILE VECTORS AND SLATES DO
--   NOT EXIST YET: a later slice MUST add their tables here, or the erasure
--   leaves the derived data behind." This is that slice, for the FACTORS.
--   ai_rec_erase_user(p_user) deletes the user's own vectors in EVERY model
--   (a user vector is derived from what the user did, in every model) and the
--   rows where the user is an ITEM (the user as a suggested person: their
--   factor vector is what the "people you might like" list searches for).
--   A factor vector is derived from the user's activity, so it is the user's
--   data: it goes with the user.
--
--   The events file's ai_erase_user() calls this erasure DYNAMICALLY and
--   GUARDED (to_regprocedure(...) IS NOT NULL -> EXECUTE), exactly like it
--   calls the moderation erasure: the events file stays valid on a database
--   that never had this migration, and the two files work in either order.
--
-- WHY THE EXPORT IS HERE
--   The erasure covers the DERIVED data, so the export has to cover it too:
--   a data export that holds the raw log and leaves the vectors behind is
--   half an export. The export is the ERASURE'S MIRROR: it returns the very
--   rows the erasure deletes - the user's own vectors in every model, and
--   the rows where the user is an ITEM - row for row, so what a user takes
--   away is exactly what a user's deletion removes.
--
--   The vectors are UNPADDED: the column holds 64 numbers, but a 16-factor
--   model's vector has 16 real ones and 48 zeros, and 48 zeros are not the
--   user's data. The export says how many are real ("factors": 16) and
--   hands over exactly that many numbers, the same slicing the serving file
--   does (f.factors::real[])[1:m.factors].
--
--   It is a SEPARATE function and not a change to ai_export_user: the events
--   file's export returns SETOF ai_events, and the bridge reads exactly that
--   row shape (osionos scripts/bridge-personalization.mjs:96-101). Changing
--   the return type would break that caller, so the vectors get their own
--   function here and the bridge calls BOTH.
--
-- WHAT IS NOT HERE
--   The TRAINING JOB that reads ai_events, trains and writes the factors is
--   NOT here: this file is the home of the model, not the job that fills it.
--   The Node service that SERVES the champion, the fold-in of a new user into
--   the model, the nightly run and the health chart are all later slices.
--   The registry holds the models that are written; it does not make any.
--
-- THE FILE NAME IS AN ORDERING FACT (read the runner's ORDERING note)
--   This file is models/osionos-rec-factors-migration.sql, and it sorts
--   BEFORE models/osionos-user-events-migration.sql ("r" < "u"). That order is
--   fine ONLY because this file references NOTHING in the events file: it
--   creates its own three tables and its own four functions, and it reads no
--   ai_events table. The events file's ai_erase_user() resolves
--   ai_rec_erase_user() at CALL time, so the two files work in either order
--   and each of them works alone — the same trick the moderation file uses.
--
--   The extension it needs (pgvector) is created by
--   models/osionos-social-migration.sql:12, which is in ORDERED_FIRST, so the
--   extension exists before the alphabetical pass whatever this file's name
--   says. The CREATE EXTENSION below is the same belt as
--   models/osionos-ai-rag-migration.sql:19 wears: a database whose pgvector
--   was created under another schema keeps it there, and the type would not
--   resolve, so the extension moves to public.
--
-- THE GRANTS ARE ITS OWN
--   The catalog-wide revoke of models/osionos-service-role-only-migration.sql
--   matches osionos\_% only, and the ai\_% relations have to close themselves
--   — the moderation file says the same of its own tables. So every table and
--   every function here is service_role only, RLS on with a service_role
--   policy, and the REVOKE happens here on every replay.
--
-- IDEMPOTENT
--   Every statement is IF NOT EXISTS / DROP ... IF EXISTS / CREATE OR REPLACE
--   shaped, so the file is replayed on every boot. It never rewrites a row of
--   the registry and never rewrites a factor: a factor is written by the
--   training job, once, and the file only creates the table it lands in.

-- pgvector 0.8.0: the inner-product operator class of the HNSW index. The
-- extension is created by models/osionos-social-migration.sql (ORDERED_FIRST);
-- the two statements below are the same belt as osionos-ai-rag-migration.sql
-- wears, for a database whose pgvector was created under another schema.
CREATE EXTENSION IF NOT EXISTS vector;
DO $$
BEGIN
    IF (SELECT extnamespace <> 'public'::regnamespace FROM pg_extension WHERE extname = 'vector') THEN
        ALTER EXTENSION vector SET SCHEMA public;
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1. The registry: one row per trained model.
--
--    The row says what the model IS (algo, factors, regularization, alpha,
--    iterations), what it was trained ON (events_used, trained_until), what it
--    SCORED (metrics: the offline numbers — ndcg10, recall20, …) and whether
--    it is REAL (is_synthetic: trained on a generated log, not on the users).
--
--    status is the lifecycle: a model starts as a 'candidate', becomes the
--    'champion' when it is promoted, and becomes 'retired' when a better one
--    takes its place. The UNIQUE PARTIAL INDEX below is what makes "one
--    champion" a fact about the database rather than a hope about the code.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_rec_models (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    algo           TEXT NOT NULL CHECK (algo IN ('ials')),
    factors        SMALLINT NOT NULL CHECK (factors BETWEEN 1 AND 64),
    regularization REAL NOT NULL,
    alpha          REAL NOT NULL,
    iterations     SMALLINT NOT NULL,
    events_used    BIGINT NOT NULL,
    trained_until  TIMESTAMPTZ NOT NULL,
    metrics        JSONB NOT NULL CHECK (jsonb_typeof(metrics) = 'object'),
    is_synthetic   BOOLEAN NOT NULL,
    code_sha       TEXT CHECK (code_sha ~ '^[0-9a-f]{7,64}$'),
    status         TEXT NOT NULL DEFAULT 'candidate'
                     CHECK (status IN ('candidate','champion','retired'))
);

COMMENT ON TABLE public.ai_rec_models IS
    'The registry of the recommender''s trained models: one row per model, '
    'with its hyperparameters, its offline metrics (ndcg10, recall20, ...) and '
    'its status. At most ONE row is the champion, by the unique partial index '
    'on (status) WHERE status = ''champion''. factors is the TRUE number of '
    'factors; the stored vectors are always 64-dimensional and zero-padded. '
    'service_role only.';

-- The champion is read on every request, and this index is also the lookup:
-- the champion is the row WHERE status = 'champion', so the partial index
-- answers "who is the champion" without a scan of the registry. No second
-- index on (status): the registry holds a handful of models.
CREATE UNIQUE INDEX IF NOT EXISTS ai_rec_models_one_champion_idx
    ON public.ai_rec_models (status) WHERE status = 'champion';

-- -----------------------------------------------------------------------------
-- 2. The factors.
--
--    ITEM FACTORS: one row per (model, item). item_kind is 'page' or 'user',
--    the same two kinds the ai_events log names (models/osionos-user-events-
--    migration.sql:112), so a factor can be joined back to the log it came
--    from. workspace_id is NULL for a user item: a person is not in a
--    workspace.
--
--    The HNSW index is over (factors vector_ip_ops): the inner product. The
--    recommender scores a candidate item by the inner product with the user's
--    vector, and HNSW answers the top-N of that without the scan.
--
--    USER FACTORS: one row per (model, user). The user's vector is derived
--    from what the user did, in every model: the fold-in of a new user is a
--    later slice, and this table is where its row lands.
--
--    Both tables are ON DELETE CASCADE from the registry: a pruned or dropped
--    model takes its factors with it, and a factor never outlives the model
--    it belongs to.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_rec_item_factors (
    model_id     BIGINT NOT NULL REFERENCES public.ai_rec_models(id) ON DELETE CASCADE,
    item_kind    TEXT NOT NULL CHECK (item_kind IN ('page','user')),
    item_id      UUID NOT NULL,
    workspace_id UUID,
    factors      vector(64) NOT NULL,
    PRIMARY KEY (model_id, item_kind, item_id)
);

COMMENT ON TABLE public.ai_rec_item_factors IS
    'The item factor vectors of every model: one row per (model, item_kind, '
    'item_id), searched by INNER PRODUCT over a pgvector HNSW index. The '
    'vector is always 64-dimensional: a model with fewer factors is stored '
    'zero-padded, which leaves every inner product unchanged. service_role '
    'only.';

-- hnsw needs no training data and tolerates incremental inserts (vs ivfflat).
CREATE INDEX IF NOT EXISTS ai_rec_item_factors_hnsw_idx
    ON public.ai_rec_item_factors USING hnsw (factors vector_ip_ops);

CREATE TABLE IF NOT EXISTS public.ai_rec_user_factors (
    model_id   BIGINT NOT NULL REFERENCES public.ai_rec_models(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL,
    factors    vector(64) NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (model_id, user_id)
);

COMMENT ON TABLE public.ai_rec_user_factors IS
    'The user factor vectors of every model: one row per (model, user_id). A '
    'user vector is derived from what the user did, so it is erased with the '
    'user (public.ai_rec_erase_user). The vector is 64-dimensional, '
    'zero-padded. service_role only.';

-- -----------------------------------------------------------------------------
-- 3. The promotion: one champion, and never a worse one.
--
--    SECURITY DEFINER, and the registry is LOCKED for the call (SHARE ROW
--    EXCLUSIVE): two promoters racing would otherwise both see the same
--    champion and both write. The lock is on the registry, not on the whole
--    database, and it is held for the length of the function.
--
--    The refusals raise with SQLSTATE P0001 (raise_exception) and a message
--    that says WHICH rule refused and why. The unique partial index is the
--    backstop: even a writer that bypasses this function cannot make a
--    second champion.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_rec_promote(p_model BIGINT, p_force BOOLEAN DEFAULT false)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_model    public.ai_rec_models%ROWTYPE;
    v_champion public.ai_rec_models%ROWTYPE;
    v_new      DOUBLE PRECISION;
    v_old      DOUBLE PRECISION;
BEGIN
    -- The registry is locked for the call: a second promoter waits instead of
    -- reading a champion that is about to be retired.
    LOCK TABLE public.ai_rec_models IN SHARE ROW EXCLUSIVE MODE;

    SELECT * INTO v_model FROM public.ai_rec_models WHERE id = p_model;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ai_rec_promote: model % does not exist', p_model
            USING ERRCODE = 'P0001';
    END IF;
    IF v_model.status <> 'candidate' THEN
        RAISE EXCEPTION 'ai_rec_promote: model % is % , only a candidate can be promoted',
            p_model, v_model.status USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO v_champion FROM public.ai_rec_models WHERE status = 'champion';
    IF FOUND THEN
        -- A synthetic model never replaces a real one: its nDCG@10 was
        -- measured on a generated log, not on the users.
        IF v_model.is_synthetic AND NOT v_champion.is_synthetic THEN
            RAISE EXCEPTION 'ai_rec_promote: model % is synthetic and the champion % is not - a synthetic model never replaces a real one',
                p_model, v_champion.id USING ERRCODE = 'P0001';
        END IF;
        -- An unmeasured model counts as 0: it is not known to be better.
        v_new := coalesce((v_model.metrics->>'ndcg10')::DOUBLE PRECISION, 0);
        v_old := coalesce((v_champion.metrics->>'ndcg10')::DOUBLE PRECISION, 0);
        IF v_new < v_old AND NOT p_force THEN
            RAISE EXCEPTION 'ai_rec_promote: model % has ndcg10 % , the champion % has % - refused (p_force overrides the metric only)',
                p_model, v_new, v_champion.id, v_old USING ERRCODE = 'P0001';
        END IF;
        -- The old champion is retired, not deleted: the prune keeps the two
        -- newest retired models, and the registry says what each one scored.
        UPDATE public.ai_rec_models SET status = 'retired' WHERE id = v_champion.id;
    END IF;

    UPDATE public.ai_rec_models SET status = 'champion' WHERE id = p_model;
    RETURN 'promoted';
END $$;

COMMENT ON FUNCTION public.ai_rec_promote(BIGINT, BOOLEAN) IS
    'Promotes a candidate model to the champion and retires the old one; '
    'returns ''promoted''. It REFUSES (SQLSTATE P0001) when the model is not '
    'a candidate, when the model is synthetic and the champion is real, and '
    'when the model''s ndcg10 is lower than the champion''s - p_force '
    'overrides the METRIC comparison only. With no champion yet, the first '
    'candidate is promoted. The registry is locked for the call, and the '
    'unique partial index on the champion is the backstop.';

-- -----------------------------------------------------------------------------
-- 4. The prune: the old retired models and the stale candidates go.
--
--    The retired models beyond the newest p_keep_retired are deleted, and so
--    are the candidates older than 7 days (a candidate nobody promoted in a
--    week is a candidate that will not be promoted). Their factor rows go by
--    cascade: a factor never outlives its model.
--
--    The champion is NEVER pruned: it is neither retired nor a candidate.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_rec_prune(p_keep_retired INTEGER DEFAULT 2)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    n BIGINT;
    m BIGINT;
BEGIN
    DELETE FROM public.ai_rec_models
     WHERE status = 'retired'
       AND id NOT IN (
             SELECT r.id FROM public.ai_rec_models r
              WHERE r.status = 'retired'
              ORDER BY r.created_at DESC, r.id DESC
              LIMIT GREATEST(coalesce(p_keep_retired, 0), 0)
           );
    GET DIAGNOSTICS m = ROW_COUNT;
    n := m;
    DELETE FROM public.ai_rec_models
     WHERE status = 'candidate'
       AND created_at < now() - interval '7 days';
    GET DIAGNOSTICS m = ROW_COUNT;
    RETURN n + m;
END $$;

COMMENT ON FUNCTION public.ai_rec_prune(INTEGER) IS
    'Deletes the retired models beyond the newest p_keep_retired (default 2) '
    'and the candidates older than 7 days, and returns the number of models '
    'deleted. Their factor rows go by cascade. The champion is never pruned. '
    'The daily runner that calls this is a LATER SERVICE SLICE: until it '
    'exists, nothing is ever pruned and the registry only grows.';

-- -----------------------------------------------------------------------------
-- 5. The erasure: a user's derived vectors go with the user.
--
--    Two deletes: the user's own vectors in EVERY model, and the rows where
--    the user is an ITEM (the user as a suggested person - that vector is
--    what a "people you might like" list searches for, and it is derived from
--    the user's activity too).
--
--    Idempotent: a second call deletes 0.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_rec_erase_user(p_user UUID)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    n BIGINT;
    m BIGINT;
BEGIN
    DELETE FROM public.ai_rec_user_factors WHERE user_id = p_user;
    GET DIAGNOSTICS n = ROW_COUNT;
    DELETE FROM public.ai_rec_item_factors
     WHERE item_kind = 'user' AND item_id = p_user;
    GET DIAGNOSTICS m = ROW_COUNT;
    RETURN n + m;
END $$;

COMMENT ON FUNCTION public.ai_rec_erase_user(UUID) IS
    'Erases the derived vectors of the user: their user factor vector in '
    'EVERY model, and the item rows where the user is the item (the user as '
    'a suggested person). Returns the number of rows erased. Idempotent: a '
    'second call erases 0. The events file''s ai_erase_user() calls this '
    'dynamically, so the events file stays valid without it.';

-- -----------------------------------------------------------------------------
-- 6. The export: the derived vectors travel with the user's data.
--
--    Two arrays, and they are the ERASURE'S ROWS: "user_vectors" holds the
--    user's own factor vector in every model, "as_item" holds the rows where
--    the user is an ITEM (the user as a suggested person). Both are ordered by
--    model_id, and both are [] (never null) when the user has nothing.
--
--    Each entry says WHICH model it came from (model_id), what that model is
--    (status), how far it was trained (trained_until), how many factors it
--    really has (factors) and the vector itself - UNPADDED, because the
--    stored 64 numbers are the real ones plus zeros, and the zeros are not
--    the user's data.
--
--    A SEPARATE function: the events file's ai_export_user returns SETOF
--    ai_events, the shape the bridge reads, and a JSONB object would break
--    that caller. The bridge calls BOTH.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_rec_export_user(p_user UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT jsonb_build_object(
        'user_vectors', coalesce((
            SELECT jsonb_agg(
                       jsonb_build_object(
                           'model_id',      m.id,
                           'status',        m.status,
                           'trained_until', m.trained_until,
                           'factors',       m.factors,
                           'vector',        to_jsonb((f.factors::real[])[1:m.factors])
                       )
                       ORDER BY m.id
                   )
              FROM public.ai_rec_user_factors f
              JOIN public.ai_rec_models m ON m.id = f.model_id
             WHERE f.user_id = p_user
        ), '[]'::jsonb),
        'as_item', coalesce((
            SELECT jsonb_agg(
                       jsonb_build_object(
                           'model_id',      m.id,
                           'status',        m.status,
                           'trained_until', m.trained_until,
                           'factors',       m.factors,
                           'vector',        to_jsonb((f.factors::real[])[1:m.factors])
                       )
                       ORDER BY m.id
                   )
              FROM public.ai_rec_item_factors f
              JOIN public.ai_rec_models m ON m.id = f.model_id
             WHERE f.item_kind = 'user'
               AND f.item_id = p_user
        ), '[]'::jsonb)
    );
$$;

COMMENT ON FUNCTION public.ai_rec_export_user(UUID) IS
    'The derived vectors of the user, for a data export: user_vectors is the '
    'user''s own factor vector in every model, as_item is the rows where the '
    'user is the item (the user as a suggested person). Each entry says the '
    'model (model_id, status, trained_until), the model''s true factor count '
    '(factors) and the vector UNPADDED to that count - the stored 64 numbers '
    'are the real ones plus zeros, and the zeros are not the user''s data. '
    'Both arrays are ordered by model_id and are [] (never null) when empty. '
    'These are the very rows public.ai_rec_erase_user erases, row for row: '
    'the export is the erasure''s mirror image. It is a SEPARATE function '
    'because the events file''s ai_export_user returns SETOF ai_events, the '
    'shape the bridge reads; the bridge calls both. service_role only.';

-- -----------------------------------------------------------------------------
-- 7. The grants: service_role only.
--
--    ai_* is outside the osionos_* catalog pass of
--    models/osionos-service-role-only-migration.sql, so the REVOKE happens
--    here, on every replay. The bridge is the only reader and writer: the
--    training job writes the factors, the service reads the champion and
--    searches the vectors, and nobody else may see either.
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_rec_models ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_rec_item_factors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_rec_user_factors ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_rec_models_service_role_all ON public.ai_rec_models;
CREATE POLICY ai_rec_models_service_role_all ON public.ai_rec_models
    FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

DROP POLICY IF EXISTS ai_rec_item_factors_service_role_all ON public.ai_rec_item_factors;
CREATE POLICY ai_rec_item_factors_service_role_all ON public.ai_rec_item_factors
    FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

DROP POLICY IF EXISTS ai_rec_user_factors_service_role_all ON public.ai_rec_user_factors;
CREATE POLICY ai_rec_user_factors_service_role_all ON public.ai_rec_user_factors
    FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_rec_models TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_rec_item_factors TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_rec_user_factors TO service_role;

REVOKE ALL ON public.ai_rec_models FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.ai_rec_item_factors FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.ai_rec_user_factors FROM PUBLIC, anon, authenticated;

-- The functions are service_role only: PUBLIC's default EXECUTE would let
-- any PostgREST role promote a model or erase a user.
REVOKE ALL ON FUNCTION public.ai_rec_promote(BIGINT, BOOLEAN) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_rec_prune(INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_rec_erase_user(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_rec_export_user(UUID) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.ai_rec_promote(BIGINT, BOOLEAN) TO service_role;
GRANT EXECUTE ON FUNCTION public.ai_rec_prune(INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.ai_rec_erase_user(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.ai_rec_export_user(UUID) TO service_role;

NOTIFY pgrst, 'reload schema';
