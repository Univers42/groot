-- The rollback of models/osionos-rec-factors-migration.sql (the recommender's
-- model registry, the padded factor vectors, the guarded promotion and the
-- erasure).
--
-- THE RUNNER NEVER PICKS THIS FILE UP
--   The runner's glob is "${MODELS_DIR}"/*.sql
--   (scripts/apply-models-migrations.sh), and this file lives in the
--   models/rollback/ subdirectory, which that glob does not reach. The ledger
--   runner scripts/apply-models.sh globs the same way. A rollback is run by
--   hand, or by the service slice that owns the slice.
--
-- ORDER
--   The functions first (nothing else depends on them, and the events file
--   only CALLS them, guarded), then the factor tables, then the registry.
--   Dropping the registry would cascade to the factor tables anyway; they are
--   dropped explicitly so the order reads top to bottom.
--
-- IDEMPOTENT: every statement is IF EXISTS shaped, so it can be applied twice.
--
-- WHAT A ROLLBACK COSTS
--   Every model, every factor vector and every user vector is dropped with
--   the tables: the recommender has NO model to serve until the migration is
--   applied again and a training job writes the factors again. The HNSW index
--   goes with its table.
--
--   The events file stays valid after this rollback: its ai_erase_user()
--   calls ai_rec_erase_user() dynamically, and the call is skipped when the
--   function is not there. The moderation erasure is guarded the same way.

-- The service functions.
DROP FUNCTION IF EXISTS public.ai_rec_promote(BIGINT, BOOLEAN);
DROP FUNCTION IF EXISTS public.ai_rec_prune(INTEGER);
DROP FUNCTION IF EXISTS public.ai_rec_erase_user(UUID);

-- The factor tables, then the registry they hang from. The HNSW index goes
-- with its table.
DROP TABLE IF EXISTS public.ai_rec_user_factors;
DROP TABLE IF EXISTS public.ai_rec_item_factors;
DROP TABLE IF EXISTS public.ai_rec_models;
