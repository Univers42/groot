-- Rollback of models/osionos-page-version-tombstone-migration.sql (osionos #344).
--
-- Drops the three triggers, their functions and the tombstone table. After it
-- runs, a page id re-created after a hard delete restarts at version 0 again,
-- and the tombstones recorded so far are GONE: re-applying the migration later
-- starts from an empty table, so every id deleted before that re-apply loses its
-- protection for good. Back the table up first if it may be re-applied:
--   COPY public.osionos_page_version_tombstones TO STDOUT;
--
-- Usage: psql -v ON_ERROR_STOP=1 -f scripts/rollback/page-version-tombstone-rollback.sql
BEGIN;
SET LOCAL lock_timeout = '5s';
DROP TRIGGER IF EXISTS osionos_pages_version_recheck_trg ON public.osionos_pages;
DROP TRIGGER IF EXISTS osionos_pages_version_seed_trg ON public.osionos_pages;
DROP TRIGGER IF EXISTS osionos_pages_version_tombstone_trg ON public.osionos_pages;
DROP FUNCTION IF EXISTS public.osionos_page_version_recheck();
DROP FUNCTION IF EXISTS public.osionos_page_version_seed();
DROP FUNCTION IF EXISTS public.osionos_page_version_tombstone();
DROP TABLE IF EXISTS public.osionos_page_version_tombstones;
COMMIT;
