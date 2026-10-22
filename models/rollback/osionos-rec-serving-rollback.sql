-- The rollback of models/osionos-rec-serving-migration.sql (the user's context
-- for the fold-in, and the champion's nearest items through the HNSW index).
--
-- THE RUNNER NEVER PICKS THIS FILE UP
--   The runner's glob is "${MODELS_DIR}"/*.sql
--   (scripts/apply-models-migrations.sh), and this file lives in the
--   models/rollback/ subdirectory, which that glob does not reach. The ledger
--   runner scripts/apply-models.sh globs the same way. A rollback is run by
--   hand, or by the service slice that owns the slice.
--
-- ORDER
--   The serving functions first, then the query behind them: the helper is
--   only ever called from inside ai_rec_nearest, so dropping the caller
--   first leaves nothing that could call it.
--
-- IDEMPOTENT: every statement is IF EXISTS shaped, so it can be applied twice.
--
-- WHAT A ROLLBACK COSTS
--   The recommender can no longer be served: the bridge has no way to read a
--   user's context and no way to ask for the champion's nearest items. The
--   MODEL ITSELF IS NOT TOUCHED: the registry, the factor vectors and the
--   HNSW index of models/osionos-rec-factors-migration.sql stay exactly
--   where they are, so re-applying the migration restores the serving side
--   without training anything again.
--
--   The events file stays valid after this rollback: it never calls these
--   functions, and nothing else does either.

-- The serving functions.
DROP FUNCTION IF EXISTS public.ai_rec_popular(INTEGER, INTERVAL, INTEGER);
DROP FUNCTION IF EXISTS public.ai_rec_nearest(BIGINT, REAL[], INTEGER, TEXT);
DROP FUNCTION IF EXISTS public.ai_rec_user_context(UUID, INTEGER);

-- The query behind ai_rec_nearest.
DROP FUNCTION IF EXISTS public.ai_rec_nearest_rows(BIGINT, vector, INTEGER, TEXT, SMALLINT);

-- The champion's fold-in inputs (M3c-4b-1): the constraints first, then the
-- columns. Both IF EXISTS, so a model written without them (or a rollback
-- run twice) is a no-op.
ALTER TABLE public.ai_rec_models DROP CONSTRAINT IF EXISTS ai_rec_models_item_gram_check;
ALTER TABLE public.ai_rec_models DROP CONSTRAINT IF EXISTS ai_rec_models_event_weights_check;
ALTER TABLE public.ai_rec_models DROP COLUMN IF EXISTS item_gram;
ALTER TABLE public.ai_rec_models DROP COLUMN IF EXISTS event_weights;
