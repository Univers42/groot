-- Upgrade the live-call uniqueness index without blocking approval writes.
--
-- The base AI migration creates ai_approvals_one_live_per_call for
-- pending/executing/executed approvals. P6 adds 'partial', so a half-built plan
-- must also hold the unique key. The replacement is built CONCURRENTLY under a
-- different name; only after PostgreSQL reports it valid do we remove the old
-- index concurrently. The two indexes overlap during the swap, so there is no
-- gap without uniqueness for the original statuses.
--
-- IMPORTANT: this file intentionally uses top-level CREATE/DROP INDEX
-- CONCURRENTLY statements. scripts/apply-models-migrations.sh feeds each file
-- to psql in autocommit mode; do not wrap this file in BEGIN/COMMIT.
--
-- If an earlier concurrent build was interrupted, PostgreSQL may leave an
-- invalid staging index. We fail closed and retain the legacy index rather than
-- silently letting IF NOT EXISTS skip an invalid index. The operator can then
-- DROP INDEX CONCURRENTLY public.ai_approvals_one_live_per_call_partial_idx
-- and replay this migration.
--
-- If rows already contain duplicate live calls involving 'partial', stop
-- before starting the build. The previous index remains in place and the
-- conflicting records can be reconciled intentionally instead of losing data.

SET lock_timeout = '5s';

DO $$
DECLARE
    target_exists BOOLEAN;
    target_valid  BOOLEAN;
    target_pred   TEXT;
    target_def    TEXT;
BEGIN
    IF EXISTS (
        SELECT 1
          FROM public.ai_approvals
         WHERE run_id IS NOT NULL
           AND status IN ('pending', 'executing', 'executed', 'partial')
         GROUP BY run_id, tool, args_sha256
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION
            'cannot create ai_approvals_one_live_per_call_partial_idx: duplicate live approval keys exist; reconcile them first';
    END IF;

    SELECT EXISTS (
        SELECT 1
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public'
           AND c.relname = 'ai_approvals_one_live_per_call_partial_idx'
           AND c.relkind = 'i'
    )
    INTO target_exists;

    IF target_exists THEN
        SELECT i.indisvalid AND i.indisready AND i.indisunique,
               coalesce(pg_get_expr(i.indpred, i.indrelid), ''),
               pg_get_indexdef(i.indexrelid)
          INTO target_valid, target_pred, target_def
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_index i ON i.indexrelid = c.oid
         WHERE n.nspname = 'public'
           AND c.relname = 'ai_approvals_one_live_per_call_partial_idx';

        IF NOT coalesce(target_valid, FALSE)
           OR position('pending' IN coalesce(target_pred, '')) = 0
           OR position('executing' IN coalesce(target_pred, '')) = 0
           OR position('executed' IN coalesce(target_pred, '')) = 0
           OR position('partial' IN coalesce(target_pred, '')) = 0
           OR position('run_id, tool, args_sha256' IN coalesce(target_def, '')) = 0 THEN
            RAISE EXCEPTION
                'ai_approvals_one_live_per_call_partial_idx exists but is invalid or has the wrong definition; drop it CONCURRENTLY and replay this migration';
        END IF;
    END IF;
END
$$;

CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS ai_approvals_one_live_per_call_partial_idx
    ON public.ai_approvals (run_id, tool, args_sha256)
    WHERE status IN ('pending', 'executing', 'executed', 'partial');

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_index i ON i.indexrelid = c.oid
         WHERE n.nspname = 'public'
           AND c.relname = 'ai_approvals_one_live_per_call_partial_idx'
           AND i.indisvalid
           AND i.indisready
           AND i.indisunique
           AND position('pending' IN coalesce(pg_get_expr(i.indpred, i.indrelid), '')) > 0
           AND position('executing' IN coalesce(pg_get_expr(i.indpred, i.indrelid), '')) > 0
           AND position('executed' IN coalesce(pg_get_expr(i.indpred, i.indrelid), '')) > 0
           AND position('partial' IN coalesce(pg_get_expr(i.indpred, i.indrelid), '')) > 0
    ) THEN
        RAISE EXCEPTION
            'replacement approval index was not verified as valid; legacy index was retained';
    END IF;
END
$$;

DROP INDEX CONCURRENTLY IF EXISTS public.ai_approvals_one_live_per_call;

RESET lock_timeout;
