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
--   scripts/apply-models-migrations.sh lists models/*.sql in alphabetical order,
--   and this file sorts BEFORE osionos-tasks-migration.sql, the file that
--   creates public.osionos_tasks. On a fresh database that table does not
--   exist yet, so the tasks index cannot be built here: a one-shot event
--   trigger builds it the moment the table appears and then removes itself
--   and its function. The pages table does exist by then (the bridge file is
--   applied first), so its index is built here.
--
-- HOW EACH INDEX IS BUILT
--   The runner feeds every file to psql on its own, outside a transaction, so
--   CREATE INDEX CONCURRENTLY is allowed and the build does not block the
--   writes on the table it indexes. The tasks index is the exception: the
--   event trigger runs inside the transaction that creates the table, where
--   CONCURRENTLY is refused ("CREATE INDEX CONCURRENTLY cannot be executed
--   from a function"). That table is empty then, so the build is free.
-- Caveat: on a database that already holds public.osionos_tasks the tasks
--   index is built in one statement, which holds a write lock on the table for
--   the length of the build; lock_timeout caps that wait at five seconds.
--
-- Idempotent: a second run creates no index and leaves no object behind (check
-- g of scripts/verify/models-grants.sh).

-- A concurrent build that fails leaves an INVALID index behind, and IF NOT EXISTS
-- skips that name for good: the index would stay dead and the read would fall
-- back to a sequential scan without a word. Drop it first, so this file builds it.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
              WHERE c.relname = 'osionos_pages_owner_updated_idx' AND NOT i.indisvalid) THEN
    DROP INDEX public.osionos_pages_owner_updated_idx;
  END IF;
END $$;

-- The pages index. The read is scoped by owner_id and ordered by updated_at
-- DESC, so the index carries the sort order: an ascending index would still
-- be scanned backwards for one owner, but the planner asks for the order the
-- index already has.
CREATE INDEX CONCURRENTLY IF NOT EXISTS osionos_pages_owner_updated_idx
  ON public.osionos_pages (owner_id, updated_at DESC);

-- The tasks index, for the database that already holds the table. Same shape:
-- the read is scoped by owner_id and ordered by updated_at DESC.
DO $$
BEGIN
  IF to_regclass('public.osionos_tasks') IS NOT NULL THEN
    SET LOCAL lock_timeout = '5s';
    EXECUTE 'CREATE INDEX IF NOT EXISTS osionos_tasks_owner_updated_idx ON public.osionos_tasks (owner_id, updated_at DESC)';
  END IF;
END $$;

-- The tasks index, for the fresh database where the table is still to come.
-- The trigger fires on the next CREATE TABLE, builds the index as soon as
-- public.osionos_tasks exists, and drops the trigger and its own function: the
-- file leaves nothing behind.
DO $$
BEGIN
  IF to_regclass('public.osionos_tasks') IS NOT NULL THEN
    RETURN;
  END IF;
  EXECUTE $fn$
    CREATE OR REPLACE FUNCTION public.osionos_self_data_indexes_on_create() RETURNS event_trigger
    LANGUAGE plpgsql AS $body$
    BEGIN
      IF to_regclass('public.osionos_tasks') IS NULL THEN
        RETURN;
      END IF;
      EXECUTE 'CREATE INDEX IF NOT EXISTS osionos_tasks_owner_updated_idx ON public.osionos_tasks (owner_id, updated_at DESC)';
      EXECUTE 'DROP EVENT TRIGGER osionos_self_data_indexes_on_create';
      EXECUTE 'DROP FUNCTION public.osionos_self_data_indexes_on_create()';
      RETURN;
    EXCEPTION WHEN others THEN
      -- A failed build must never abort the statement that fired this trigger,
      -- and it must not drop the trigger either: the next CREATE TABLE retries.
      RAISE WARNING 'osionos_self_data_indexes_on_create: %', SQLERRM;
    END $body$
  $fn$;
  EXECUTE 'CREATE EVENT TRIGGER osionos_self_data_indexes_on_create ON ddl_command_end WHEN TAG IN (''CREATE TABLE'') EXECUTE FUNCTION public.osionos_self_data_indexes_on_create()';
END $$;
