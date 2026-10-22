-- osionos-self-data-indexes-migration.sql — the indexes the sys: self-data
-- sources read through.
--
-- WHY THIS FILE EXISTS
--   The self-data sources (scripts/bridge-self-sources.mjs) answer with the
--   caller's own rows: public.osionos_pages for my-pages, public.osionos_tasks
--   for my-tasks. Both reads are scoped by owner_id=eq.<uid> and ordered by
--   updated_at DESC, and these two indexes are the ones that serve them.
--
-- WHERE IT RUNS
--   scripts/apply-models-migrations.sh lists this file in ORDERED_LAST, right
--   before osionos-service-role-only-migration.sql: the tasks index names
--   public.osionos_tasks, which osionos-tasks-migration.sql creates in the
--   alphabetical pass, and this file would otherwise run before it. The pages
--   table exists by then too (osionos-bridge-migration.sql is in ORDERED_FIRST).
--
-- HOW EACH INDEX IS BUILT
--   The runner feeds every file to psql on its own, outside a transaction, so
--   CREATE INDEX CONCURRENTLY is allowed and the build does not block the
--   writes on the table it indexes.
-- Caveat: a concurrent build that fails leaves an INVALID index behind, and
--   IF NOT EXISTS skips that name for good (the index would stay dead). The
--   repair step above each build drops an invalid index of that name so the
--   file rebuilds it on the next pass.
--
-- Idempotent: a second run creates no index and moves no grant (check g of
-- scripts/verify/models-grants.sh).

-- The pages index. The read is scoped by owner_id and ordered by updated_at
-- DESC, so the index carries the sort order.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
              WHERE c.relname = 'osionos_pages_owner_updated_idx' AND NOT i.indisvalid) THEN
    DROP INDEX public.osionos_pages_owner_updated_idx;
  END IF;
END $$;
CREATE INDEX CONCURRENTLY IF NOT EXISTS osionos_pages_owner_updated_idx
  ON public.osionos_pages (owner_id, updated_at DESC);

-- The tasks index. Same shape: the read is scoped by owner_id and ordered by
-- updated_at DESC.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
              WHERE c.relname = 'osionos_tasks_owner_updated_idx' AND NOT i.indisvalid) THEN
    DROP INDEX public.osionos_tasks_owner_updated_idx;
  END IF;
END $$;
CREATE INDEX CONCURRENTLY IF NOT EXISTS osionos_tasks_owner_updated_idx
  ON public.osionos_tasks (owner_id, updated_at DESC);
