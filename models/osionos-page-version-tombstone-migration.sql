-- osionos #344 — a page id re-created after a hard delete continues its content
-- version; it never restarts at 0.
--
-- WHY
--   public.osionos_pages.version (osionos-page-version-migration.sql) is what a
--   writer's precondition reads: `update … where id = $1 and version = $2`. A
--   hard delete followed by a create with the SAME id (a client-chosen id: the
--   osionos-ai builder retries its plan's ids) used to start the new row at the
--   column default, 0. Two content writes later the new row is back at a version
--   a stale client still holds as its base, its precondition matches, and its
--   whole-array write replaces newer content with nothing recording the loss.
--   Ruling: docs/adr/DRAFT-page-version-344-ruling.md, candidate (b), P344-1..10.
--
-- WHAT
--   1. public.osionos_page_version_tombstones (page_id, version): per hard-deleted
--      id, the highest content version it ever reached.
--   2. AFTER DELETE, FOR EACH STATEMENT, REFERENCING OLD TABLE: one upsert of
--      GREATEST(stored, deleted) for every row the statement removed. A
--      5,000-page workspace cascade is one statement, not 5,000 (P344-3).
--   3. BEFORE INSERT, FOR EACH ROW: NEW.version := tombstone + 1, or 0 when the
--      id was never deleted. Whatever the payload carried is overwritten (P344-6).
--   4. AFTER INSERT, FOR EACH STATEMENT, REFERENCING NEW TABLE: the race recheck
--      (P344-5, below).
--   The tombstone is written in the database, so the three delete paths are all
--   covered: the bridge's DELETE, the workspace cascade
--   (osionos-bridge-migration.sql:51) and the account erase
--   (osionos-account-erasure-migration.sql:725).
--
-- TRIGGER ORDER ON public.osionos_pages
--   Every BEFORE trigger runs before every AFTER trigger; row-level AFTER
--   triggers run before statement-level ones; inside a group, name order.
--     BEFORE INSERT  osionos_pages_version_seed_trg       <- this file (row)
--     BEFORE UPDATE  osionos_pages_version_trg            (page-version file)
--     AFTER  INSERT  ai_enqueue_page_ins
--     AFTER  INSERT  osionos_pages_links_trg / osionos_pages_tasks_trg
--     AFTER  INSERT  osionos_pages_version_recheck_trg    <- this file (statement)
--     AFTER  UPDATE  ai_enqueue_page_upd, ai_sync_page_acl_trg,
--                    osionos_pages_links_trg, osionos_pages_tasks_trg,
--                    osionos_publish_unhold
--     AFTER  DELETE  ai_delete_page_chunks_trg
--     AFTER  DELETE  osionos_pages_version_tombstone_trg  <- this file (statement)
--   The seed must be settled before the after-insert triggers read the row.
--
-- THE RACE (P344-5), CLOSED WITHOUT A LOCK
--   A create that runs while a DELETE of the same id is still uncommitted reads
--   no tombstone in its BEFORE trigger and seeds 0. Its INSERT then waits on the
--   primary key for the delete to commit and goes ahead. The statement-level
--   recheck runs after that wait, with a fresh snapshot, sees the committed
--   tombstone and raises SQLSTATE 40001 (serialization_failure): the caller
--   retries, and the retry seeds tombstone + 1. No pg_advisory_xact_lock (P344-4):
--   each one takes a slot in the shared lock table, and a large cascade could
--   exhaust it.
--
-- WHY THE TRIGGER FUNCTIONS ARE SECURITY DEFINER
--   Pages are deleted by service_role (the bridge), by the FK cascade and by the
--   erase (a SECURITY DEFINER function), and created by service_role. The
--   functions write and read the tombstone table only, never osionos_pages, so
--   running them as their owner widens nothing on the pages; it keeps every
--   deleter working whatever its grants on the tombstone (P344-2), while the
--   table stays service_role-only for every direct reader (P344-8). search_path
--   is pinned, as in the page-version file.
--
-- The tombstone holds only (page_id, version): no owner, title or timestamp, so
-- an erase leaves nothing personal in it. It is NEVER pruned: pruning an id
-- reopens the bug for any client whose base predates the prune. Estimated, not
-- measured: under 100 B per hard-deleted id.
--
-- Caveat: ids hard-deleted BEFORE this file was applied have no tombstone; a
--   re-create of one of them still starts at 0 (P344-9).
-- Caveat: the triggers do not fire under session_replication_role = replica
--   (the desktop importDump, firstrun.mjs:140) nor for TRUNCATE: a delete made
--   that way leaves no tombstone. Conversely, a data-only reload into an existing
--   schema with triggers ON reseeds every page at 0 (or tombstone + 1); a full
--   pg_dump restore creates the triggers after the data and is unaffected.
-- Caveat: the recheck closes the race at READ COMMITTED (PostgREST's write
--   default). A REPEATABLE READ inserter keeps its first snapshot, so a delete
--   that commits after that snapshot is missed and the re-create seeds low.
--
-- Where it runs: the plain alphabetical pass of scripts/apply-models-migrations.sh;
-- the name sorts right after osionos-page-version-migration.sql, which adds the
-- column, and before the ORDERED_LAST service-role-only sweep.
--
-- Idempotent (P344-7): CREATE TABLE IF NOT EXISTS, CREATE OR REPLACE, DROP/CREATE
-- TRIGGER, no row written. DOWN: scripts/rollback/page-version-tombstone-rollback.sql.

BEGIN;

-- Caveat: a busy osionos_pages makes this file fail (the transaction rolls back)
-- instead of queueing every page write behind it; the next run retries. 5 s is a
-- budget, not a promise.
SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS public.osionos_page_version_tombstones (
  page_id UUID PRIMARY KEY,
  version BIGINT NOT NULL
);

ALTER TABLE public.osionos_page_version_tombstones ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_page_version_tombstones_service_role_all ON public.osionos_page_version_tombstones;
CREATE POLICY osionos_page_version_tombstones_service_role_all ON public.osionos_page_version_tombstones
  FOR ALL TO service_role USING (true) WITH CHECK (true);
REVOKE ALL ON public.osionos_page_version_tombstones FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.osionos_page_version_tombstones TO service_role;

CREATE OR REPLACE FUNCTION public.osionos_page_version_tombstone() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  INSERT INTO public.osionos_page_version_tombstones AS t (page_id, version)
  SELECT d.id, d.version FROM deleted_pages d
  ON CONFLICT (page_id) DO UPDATE SET version = GREATEST(t.version, EXCLUDED.version);
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION public.osionos_page_version_seed() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  NEW.version := coalesce(
    (SELECT t.version + 1 FROM public.osionos_page_version_tombstones t WHERE t.page_id = NEW.id),
    0
  );
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.osionos_page_version_recheck() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  v_id UUID;
BEGIN
  SELECT n.id INTO v_id
    FROM inserted_pages n
    JOIN public.osionos_page_version_tombstones t ON t.page_id = n.id
   WHERE t.version >= n.version
   LIMIT 1;
  IF v_id IS NOT NULL THEN
    RAISE EXCEPTION 'osionos_pages: page % was deleted by a transaction that committed during this create; retry the create', v_id
      USING ERRCODE = 'serialization_failure';
  END IF;
  RETURN NULL;
END $$;

REVOKE ALL ON FUNCTION public.osionos_page_version_tombstone() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.osionos_page_version_seed() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.osionos_page_version_recheck() FROM PUBLIC;

DROP TRIGGER IF EXISTS osionos_pages_version_tombstone_trg ON public.osionos_pages;
CREATE TRIGGER osionos_pages_version_tombstone_trg
  AFTER DELETE ON public.osionos_pages
  REFERENCING OLD TABLE AS deleted_pages
  FOR EACH STATEMENT EXECUTE FUNCTION public.osionos_page_version_tombstone();

DROP TRIGGER IF EXISTS osionos_pages_version_seed_trg ON public.osionos_pages;
CREATE TRIGGER osionos_pages_version_seed_trg
  BEFORE INSERT ON public.osionos_pages
  FOR EACH ROW EXECUTE FUNCTION public.osionos_page_version_seed();

DROP TRIGGER IF EXISTS osionos_pages_version_recheck_trg ON public.osionos_pages;
CREATE TRIGGER osionos_pages_version_recheck_trg
  AFTER INSERT ON public.osionos_pages
  REFERENCING NEW TABLE AS inserted_pages
  FOR EACH STATEMENT EXECUTE FUNCTION public.osionos_page_version_recheck();

COMMIT;
