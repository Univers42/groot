-- The two reads that serve the champion: a user's context, and the champion's
-- nearest items.
--
-- WHAT THIS IS
--   M3c-2 (models/osionos-rec-factors-migration.sql) put the recommender's
--   model in Postgres: a registry with ONE champion, the item and user factor
--   vectors searched by inner product over a pgvector HNSW index, and the
--   erasure of a user's derived vectors. The nightly job fills it. This file
--   is the READ side of that model — the two things the serving bridge must
--   know to answer "For you" for one user, and nothing else:
--
--   M3c-4b-1 adds two columns to that registry so the champion carries what
--   serving needs to fold a user in: its item Gram matrix (Y^T Y, factors^2
--   numbers) and the event weights it was trained with. Both nullable; null
--   means "no fold-in".
--     1. public.ai_rec_user_context(p_user, p_recent): the champion's
--        hyperparameters, the user's stored vector if the nightly model has
--        seen them, their recent POSITIVE interactions with the item vectors
--        (so a user the model has NOT seen can be folded in), and the items
--        they marked not interested;
--     2. public.ai_rec_nearest(p_model, p_vector, p_limit, p_kind): the
--        champion's nearest items to a vector, searched on the HNSW index.
--   Both are service_role only: they expose what a user did and what the
--   model inferred about them.
--
-- WHY THE CONTEXT IS ONE JSONB
--   The bridge asks for a user's context ONCE per request and gets one object
--   back: the model, the user's vector, their recent items and their
--   not-interested items. Four round trips to PostgREST for one page would be
--   four chances to serve a half-built recommendation. One JSONB is one
--   round trip, and the shape is a CONTRACT: the bridge reads
--   context.model.factors before it reads a vector, because the vectors are
--   zero-padded to 64 and only the first `factors` of them are real.
--
-- WHY THE OPT-OUT IS THE FIRST THING
--   ai_personalization_settings.capture_explicit = false is the opt-out, and
--   an opted-out user gets {"opted_out": true} and NOTHING ELSE: no model, no
--   events, no vectors, no not-interested list. The check comes before the
--   champion is even looked up, so there is no path through this function
--   that reads an opted-out user's activity. A user with no settings row is
--   NOT opted out: no row means the defaults, and the default is to capture.
--
-- WHY THE WEIGHTS ARE NOT APPLIED HERE
--   ai_events carries a weight per event, but the weights live in ONE place —
--   the ML package (services/osionos-ml/) — and the bridge applies them when
--   it folds a user in. A second copy of the weights here would be a second
--   place to change them, and the two copies would drift. So this function
--   returns the COUNTS per event name and nothing else: the bridge sees
--   {"like": 3, "share": 1} and decides what that is worth.
--
-- WHY THE NEAREST SEARCH NEEDS THE ITERATIVE SCAN
--   The HNSW index covers EVERY model's rows — the champion's, the retired
--   models' and the candidates' — because one index cannot be per model. A
--   search that filters on model_id therefore reads at most hnsw.ef_search
--   CANDIDATES before the filter is applied: with the default 40, a request
--   for 50 items of the champion gets the ~13 of them that happen to be in the
--   first 40 candidates, and the answer is SHORT. With
--   hnsw.iterative_scan = relaxed_order the scan keeps going through the
--   index until the LIMIT is met, and hnsw.ef_search = 100 gives the first
--   batch more to choose from. Both are set ON THE FUNCTION, so the caller
--   cannot forget them: the bridge calls an RPC and does not know that
--   pgvector has a GUC.
--
-- WHY THE ORDER BY IS THE BARE <#> EXPRESSION
--   The ORDER BY is `factors <#> padded`, the operator the index is built
--   for (vector_ip_ops), and nothing else. pgvector's <#> is the NEGATIVE
--   inner product, so ascending <#> is descending inner product: the best
--   item first. The score the function returns is the inner product itself
--   (-(factors <#> padded)), so a positive score is a good match. Writing the
--   ORDER BY as -(factors <#> padded) DESC would read the same and would NOT
--   use the index: the planner matches the ORDER BY expression against the
--   index operator, and a negated one is not that operator.
--
-- WHY THE QUERY LIVES IN A NAMED SQL FUNCTION
--   The row query is public.ai_rec_nearest_rows, a plain SQL function, and
--   the serving function calls it. That is not decoration: a SECURITY
--   DEFINER function with SET clauses is NEVER inlined by the planner, so
--   EXPLAIN on a call to it shows "Function Scan" and the HNSW index does not
--   appear in the plan. The named SQL function has neither, so it IS inlined
--   and EXPLAIN names the index — which is how the verify script proves the
--   search runs on the index and not on a scan of 6,000 rows.
--
--   The helper carries no SET clause of its own for the same reason (a SET
--   clause stops the inlining), and it needs none: it is only ever called
--   from the serving function, whose search_path is fixed to public, pg_temp,
--   and every relation it names is spelled out. It is not granted to
--   anybody: it is an implementation detail, and the serving function is the
--   entry point.
--
-- THE FILE NAME IS AN ORDERING FACT (read the runner's ORDERING note)
--   This file is models/osionos-rec-serving-migration.sql. It sorts AFTER
--   models/osionos-rec-factors-migration.sql ("factors" < "serving"), and
--   that order HOLDS: the SQL function's body is validated when it is
--   created, so the factor tables have to exist when this file is applied,
--   and the alphabetical pass applies the factors file first.
--
--   It sorts BEFORE models/osionos-user-events-migration.sql ("serving" <
--   "user"), and that order is fine ONLY because the events tables are read
--   from PL/pgSQL, which resolves a relation at CALL time and not at
--   creation time: ai_rec_user_context reads public.ai_events and
--   public.ai_personalization_settings when it is called, never when it is
--   created. The runner applies both files in the same boot, so the tables
--   are there before the first call. It is the same trick the events file
--   uses in reverse, where ai_erase_user() resolves ai_rec_erase_user() at
--   CALL time.
--
-- THE GRANTS ARE ITS OWN
--   The catalog-wide revoke of models/osionos-service-role-only-migration.sql
--   matches osionos\_% only, and the ai\_% relations have to close
--   themselves. So the two functions are service_role only, REVOKE ALL from
--   PUBLIC, anon and authenticated, on every replay. The helper
--   (ai_rec_nearest_rows) is not granted to anybody: it is an implementation
--   detail of the serving function, and a bridge that can call the serving
--   function has no reason to call the query behind it.
--
-- IDEMPOTENT
--   Every statement is IF NOT EXISTS / DROP ... IF EXISTS / CREATE OR REPLACE
--   shaped, so the file is replayed on every boot. It never writes a row of
--   anything: it reads the registry, the factors and the log.

-- -----------------------------------------------------------------------------
-- 0. The champion carries what serving needs to fold a user in.
--
--    Two columns on the registry, both nullable: a model written before this
--    change (or before the job stores them) stays valid, and serving treats
--    null as "no fold-in" (it uses the stored user vector).
--
--      item_gram    -- row-major Y^T Y of the model's item factors,
--                      factors^2 numbers. Too big to recompute per request,
--                      trivial to compute once when the model is written.
--      event_weights -- the weights of osml/events.py the model was trained
--                      with (a JSON object), so serving applies the champion's
--                      own weights and a weight change never mismatches an
--                      older champion.
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_rec_models
    ADD COLUMN IF NOT EXISTS item_gram REAL[],
    ADD COLUMN IF NOT EXISTS event_weights JSONB;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'ai_rec_models_item_gram_check'
           AND conrelid = 'public.ai_rec_models'::regclass
    ) THEN
        ALTER TABLE public.ai_rec_models
            ADD CONSTRAINT ai_rec_models_item_gram_check
            CHECK (item_gram IS NULL OR cardinality(item_gram) = factors * factors);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'ai_rec_models_event_weights_check'
           AND conrelid = 'public.ai_rec_models'::regclass
    ) THEN
        ALTER TABLE public.ai_rec_models
            ADD CONSTRAINT ai_rec_models_event_weights_check
            CHECK (event_weights IS NULL OR jsonb_typeof(event_weights) = 'object');
    END IF;
END $$;

COMMENT ON COLUMN public.ai_rec_models.item_gram IS
    'Row-major Y^T Y of the model''s item factors: factors^2 numbers. Stored '
    'when the model is written so serving can fold a user in without '
    'recomputing it per request. NULL means "no fold-in": serving uses the '
    'stored user vector.';

COMMENT ON COLUMN public.ai_rec_models.event_weights IS
    'The weights of osml/events.py the model was trained with, as a JSON '
    'object. Stored so serving applies the champion''s own weights and a '
    'weight change never mismatches an older champion. NULL means "no '
    'fold-in".';

-- -----------------------------------------------------------------------------
-- 1. The context: what the service must know about ONE user to score them.
--
--    The shape is a CONTRACT with the bridge:
--      {"opted_out": true}                       the user opted out, and
--                                                NOTHING else is returned;
--      {"model": null}                           there is no champion;
--      {"model": {...}, "user_vector": ...,
--       "recent": [...], "not_interested": [...]} the real thing.
--
--    The vectors are the champion's TRUE dimension: the stored vector is
--    always 64-dimensional (the factors file's zero-padding), and the model
--    row says how many of those 64 numbers are real. So the user's vector and
--    the item vectors come back with their first `factors` numbers only, and
--    the bridge may use them as they are.
--
--    `recent` is the user's REAL activity of the last 180 days (a synthetic
--    row is a test or a replay, never a preference), the items they marked
--    NOT INTERESTED excluded, grouped by item, the p_recent most recently
--    touched items first. `not_interested` is the other half of the same
--    window: the items to keep away from.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_rec_user_context(p_user UUID, p_recent INTEGER DEFAULT 50)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
    v_opt_out BOOLEAN := false;
    v_model    public.ai_rec_models%ROWTYPE;
    v_limit    INTEGER;
    v_user_vec REAL[];
    v_recent   JSONB;
    v_not_int  JSONB;
BEGIN
    -- The opt-out comes FIRST, before the champion is even looked up: there
    -- is no path through this function that reads an opted-out user's
    -- activity. No settings row means the defaults, and the default is to
    -- capture, so a missing row is NOT an opt-out.
    SELECT NOT s.capture_explicit INTO v_opt_out
      FROM public.ai_personalization_settings s
     WHERE s.user_id = p_user;
    IF v_opt_out THEN
        RETURN jsonb_build_object('opted_out', true);
    END IF;

    -- No champion: there is no model to score anybody with, and there is
    -- nothing to fold a user into.
    SELECT m.* INTO v_model FROM public.ai_rec_models m WHERE m.status = 'champion';
    IF NOT FOUND THEN
        RETURN jsonb_build_object('model', NULL);
    END IF;

    -- The window is clamped: a caller cannot ask for nothing (1) nor for the
    -- whole log (200).
    v_limit := least(greatest(coalesce(p_recent, 50), 1), 200);

    -- The user's own vector, if the nightly model has seen them. A user the
    -- model has NOT seen has no row here, and the bridge folds them in from
    -- the recent items below.
    SELECT (f.factors::real[])[1:v_model.factors]
      INTO v_user_vec
      FROM public.ai_rec_user_factors f
     WHERE f.model_id = v_model.id
       AND f.user_id = p_user;

    -- The recent items: the events of the last 180 days, grouped by item,
    -- the most recently touched first. The item's vector is the champion's
    -- vector for that item — the one the fold-in needs — and it is NULL when
    -- the champion has no row for the item (a page the model never saw).
    SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'item_kind', r.item_kind,
                   'item_id',   r.item_id,
                   'events',    r.events,
                   'vector',    r.vec
               ) ORDER BY r.last_ts DESC), '[]'::jsonb)
      INTO v_recent
      FROM (
          SELECT g.item_kind,
                 g.item_id,
                 g.events,
                 g.last_ts,
                 v.vec
            FROM (
                -- One row per item: the events of that item as a JSON object.
                SELECT e.item_kind,
                       e.item_id,
                       jsonb_object_agg(e.event, e.n) AS events,
                       max(e.last_ts) AS last_ts
                  FROM (
                      -- One row per (item, event): the count of each event.
                      SELECT e.item_kind,
                             e.item_id,
                             e.event,
                             count(*) AS n,
                             max(e.ts) AS last_ts
                        FROM public.ai_events e
                       WHERE e.user_id = p_user
                         AND e.is_synthetic = false
                         AND e.ts >= now() - interval '180 days'
                         -- An impression is not an interaction: a user is shown
                         -- far more than they touch, and impressions would fill
                         -- the p_recent slots the likes and comments need.
                         AND e.event NOT IN ('not_interested', 'impression')
                       GROUP BY e.item_kind, e.item_id, e.event
                  ) e
                 GROUP BY e.item_kind, e.item_id
                 ORDER BY max(e.last_ts) DESC
                 LIMIT v_limit
            ) g
            LEFT JOIN LATERAL (
                SELECT (f.factors::real[])[1:v_model.factors] AS vec
                  FROM public.ai_rec_item_factors f
                 WHERE f.model_id = v_model.id
                   AND f.item_kind = g.item_kind
                   AND f.item_id = g.item_id
            ) v ON true
      ) r;

    -- The items the user marked not interested. The whole window, NOT the
    -- p_recent slice: a not-interested item that is dropped from this list is
    -- an item the bridge may serve again.
    SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'item_kind', n.item_kind,
                   'item_id',   n.item_id
               ) ORDER BY n.last_ts DESC), '[]'::jsonb)
      INTO v_not_int
      FROM (
          SELECT e.item_kind, e.item_id, max(e.ts) AS last_ts
            FROM public.ai_events e
           WHERE e.user_id = p_user
             AND e.is_synthetic = false
             AND e.ts >= now() - interval '180 days'
             AND e.event = 'not_interested'
           GROUP BY e.item_kind, e.item_id
      ) n;

    RETURN jsonb_build_object(
        'model', jsonb_build_object(
            'id',             v_model.id,
            'factors',        v_model.factors,
            'regularization', v_model.regularization,
            'alpha',          v_model.alpha,
            'item_gram',      v_model.item_gram,
            'event_weights',  v_model.event_weights
        ),
        'user_vector', v_user_vec,
        'recent',      v_recent,
        'not_interested', v_not_int
    );
END $$;

COMMENT ON FUNCTION public.ai_rec_user_context(UUID, INTEGER) IS
    'Everything the service must know about ONE user to score them, as one '
    'JSONB: the champion''s hyperparameters, the user''s stored vector (the '
    'first `factors` numbers, or null when the model has not seen them), '
    'their recent real items of the last 180 days with the count of each '
    'event and the champion''s vector for that item, and the items they '
    'marked not interested. An opted-out user gets {"opted_out": true} and '
    'nothing else; no champion gets {"model": null}. The champion''s item '
    'Gram matrix (item_gram, row-major Y^T Y, factors^2 numbers) and its '
    'event weights (event_weights) are returned inside model so the bridge '
    'can fold a user in with the champion''s own inputs; both are null when '
    'the model was written without them, and serving treats null as "no '
    'fold-in". The event WEIGHTS are not applied here: they live in the ML '
    'package, and the bridge applies them. service_role only.';

-- -----------------------------------------------------------------------------
-- 2. The nearest items: the champion's rows, nearest first, on the HNSW index.
--
--    The query is public.ai_rec_nearest_rows, a plain SQL function. It is
--    named so that EXPLAIN can name the index (see the header), and it is
--    called by the serving function below.
--
--    The ORDER BY is the bare `factors <#> p_q`: the operator the index is
--    built for, so the planner can use it. The score the caller gets is the
--    inner product (-(factors <#> p_q)), positive for a good match.
--
--    The vector the caller gets is the item's first `factors` numbers: the
--    same TRUE dimension the context returns.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_rec_nearest_rows(p_model BIGINT, p_q vector(64), p_limit INTEGER, p_kind TEXT, p_factors SMALLINT)
RETURNS TABLE (item_kind TEXT, item_id UUID, workspace_id UUID, score REAL, vector REAL[])
LANGUAGE sql
STABLE
AS $$
    SELECT f.item_kind,
           f.item_id,
           f.workspace_id,
           -(f.factors <#> p_q)::real,
           (f.factors::real[])[1:p_factors]
      FROM public.ai_rec_item_factors f
     WHERE f.model_id = p_model
       AND f.item_kind = p_kind
     ORDER BY f.factors <#> p_q
     LIMIT p_limit
$$;

COMMENT ON FUNCTION public.ai_rec_nearest_rows(BIGINT, vector, INTEGER, TEXT, SMALLINT) IS
    'The query behind public.ai_rec_nearest: the rows of one model and one '
    'kind, ordered by the inner product with the query vector (the bare <#> '
    'expression, so the HNSW index is used), with the inner product as the '
    'score and the item''s first `factors` numbers as the vector. A named SQL '
    'function so that EXPLAIN inlines it and names the index.';

-- -----------------------------------------------------------------------------
-- 3. The serving function: the same search, with the arguments checked.
--
--    The vector is zero-padded to 64 here: the models have 8, 16, 32 or 64
--    factors and the column is vector(64), so a 16-number query vector has to
--    become a 64-number one before it can be compared with the stored ones.
--    The padding is exact (a product with a zero is a zero), and the model
--    row keeps the true count.
--
--    The refusals: a vector of more than 64 numbers is 22023 (invalid
--    parameter value) — it is not a vector of this model — and a kind that is
--    not 'page' or 'user' is refused too, rather than silently returning the
--    rows of no kind at all.
--
--    The two GUCs of the search are set HERE, on the function, so that the
--    caller cannot forget them: the iterative scan is what makes a filtered
--    search return the LIMIT it was asked for, and the HNSW index covers
--    every model, not just the champion's.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_rec_nearest(p_model BIGINT, p_vector REAL[], p_limit INTEGER DEFAULT 100, p_kind TEXT DEFAULT 'page')
RETURNS TABLE (item_kind TEXT, item_id UUID, workspace_id UUID, score REAL, vector REAL[])
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
SET hnsw.iterative_scan = 'relaxed_order'
SET hnsw.ef_search = 100
AS $$
DECLARE
    v_len     INTEGER;
    v_limit   INTEGER;
    v_q       vector(64);
    v_factors SMALLINT;
BEGIN
    v_len := coalesce(array_length(p_vector, 1), 0);
    IF v_len > 64 THEN
        RAISE EXCEPTION 'ai_rec_nearest: the vector has % numbers, a model vector has 64 at most', v_len
            USING ERRCODE = '22023';
    END IF;
    IF p_kind IS NULL OR p_kind NOT IN ('page', 'user') THEN
        RAISE EXCEPTION 'ai_rec_nearest: the kind must be page or user, not %', coalesce(p_kind, 'null')
            USING ERRCODE = '22023';
    END IF;

    -- The window is clamped: 1 at least, 500 at most.
    v_limit := least(greatest(coalesce(p_limit, 100), 1), 500);

    -- Zero-pad to 64. An empty vector is the zero vector.
    v_q := (CASE WHEN v_len = 0
                 THEN array_fill(0::real, ARRAY[64])
                 ELSE p_vector || array_fill(0::real, ARRAY[64 - v_len])
            END)::vector(64);

    -- The model's TRUE factor count: how many of the 64 numbers are real.
    SELECT m.factors INTO v_factors FROM public.ai_rec_models m WHERE m.id = p_model;
    IF NOT FOUND THEN
        -- No such model: the query returns no row anyway, and the count
        -- below is the whole vector.
        v_factors := 64;
    END IF;

    RETURN QUERY
        SELECT r.item_kind, r.item_id, r.workspace_id, r.score, r.vector
          FROM public.ai_rec_nearest_rows(p_model, v_q, v_limit, p_kind, v_factors) r
         -- relaxed_order may hand rows back slightly out of order (pgvector
         -- 0.8 README, "Iterative Index Scans"); the LIMIT is already applied
         -- inside, so this sort is over at most 500 rows.
         ORDER BY r.score DESC, r.item_id;
END $$;

COMMENT ON FUNCTION public.ai_rec_nearest(BIGINT, REAL[], INTEGER, TEXT) IS
    'The champion''s nearest items to a vector, searched on the pgvector HNSW '
    'index: the rows of model p_model and kind p_kind (''page'' or ''user''), '
    'the best inner product first, with the inner product as the score and '
    'the item''s first `factors` numbers as the vector. The query vector has '
    'at most 64 numbers and is zero-padded to 64; more than 64 is refused '
    'with SQLSTATE 22023. p_limit is clamped to 1..500. The HNSW index '
    'covers every model, so the search runs with hnsw.iterative_scan = '
    '''relaxed_order'' and hnsw.ef_search = 100, set on the function. '
    'service_role only.';

-- -----------------------------------------------------------------------------
-- 4. The grants: service_role only.
--
--    ai_* is outside the osionos_* catalog pass of
--    models/osionos-service-role-only-migration.sql, so the REVOKE happens
--    here, on every replay. The context exposes what a user did and what the
--    model inferred about them: nobody but the service may read either.
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.ai_rec_user_context(UUID, INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_rec_nearest(BIGINT, REAL[], INTEGER, TEXT) FROM PUBLIC, anon, authenticated;
-- The helper is not granted to anybody: it is the query behind
-- ai_rec_nearest, and the serving function is the entry point.
REVOKE ALL ON FUNCTION public.ai_rec_nearest_rows(BIGINT, vector, INTEGER, TEXT, SMALLINT) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.ai_rec_user_context(UUID, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.ai_rec_nearest(BIGINT, REAL[], INTEGER, TEXT) TO service_role;

-- -----------------------------------------------------------------------------
-- 5. ai_rec_popular — the NON-PERSONALISED order (devil C48).
--
--    When "For you" cannot personalise (the user opted out, there is no
--    trained model, or the user is new) the bridge serves this order instead
--    of an empty strip. It reads NO user's own history: only the aggregate.
--
--    A page ranks by how many DISTINCT users gave it a positive explicit
--    event in the window (C50: one account, however many rows, counts once).
--    Impressions, views, clicks, connects and not_interested are not
--    positive. Synthetic rows are not real preferences. A page needs
--    p_min_users distinct users (default 3) so that a handful of accounts
--    cannot hoist a page, and a single user's taste is not readable from the
--    aggregate. p_limit is clamped to 1..200.
--
--    Caveat: a popular page the viewer cannot read is dropped by the bridge
--    (ACL and blocks, C55), so a small workspace may get fewer than limit
--    items, or none: the strip is then empty, as before.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_rec_popular(
    p_limit     INTEGER  DEFAULT 100,
    p_window    INTERVAL DEFAULT '30 days',
    p_min_users INTEGER  DEFAULT 3
)
RETURNS TABLE(item_id UUID, users BIGINT)
LANGUAGE plpgsql
STABLE
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
BEGIN
    -- plpgsql, not sql: ai_events is read at CALL time, so this file still
    -- applies on a database without the events migration (check 0).
    RETURN QUERY
    SELECT e.item_id, COUNT(DISTINCT e.user_id)
      FROM public.ai_events e
     WHERE e.item_kind = 'page'
       AND e.event IN ('like', 'react', 'share', 'comment', 'favorite')
       AND NOT e.is_synthetic
       AND e.ts >= now() - p_window
     GROUP BY e.item_id
    HAVING COUNT(DISTINCT e.user_id) >= GREATEST(p_min_users, 1)
     ORDER BY COUNT(DISTINCT e.user_id) DESC, e.item_id
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
END;
$$;

COMMENT ON FUNCTION public.ai_rec_popular(INTEGER, INTERVAL, INTEGER) IS
    'The non-personalised order "For you" falls back to (C48): pages ranked by '
    'DISTINCT users with a positive explicit event (like, react, share, comment, '
    'favorite) in the window, at least p_min_users of them. p_limit clamped to '
    '1..200. service_role only.';

REVOKE ALL ON FUNCTION public.ai_rec_popular(INTEGER, INTERVAL, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ai_rec_popular(INTEGER, INTERVAL, INTEGER) TO service_role;

NOTIFY pgrst, 'reload schema';
