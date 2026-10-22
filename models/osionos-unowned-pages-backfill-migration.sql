-- osionos page-owner backfill: an ownerless page becomes the workspace owner's.
--
-- Why this exists
--   The bridge's page write rule (scripts/bridge-api.mjs, mayModifyPage) used to
--   answer "writable" for any osionos_pages row with owner_id IS NULL, so a
--   membership carrying 'admin' but not 'update'/'delete' wrote pages nobody could
--   re-share, restore or take back, and a PRIVATE ownerless page was readable by
--   nobody at all (the server's read rule has no legacy branch — see
--   scripts/bridge-page-read.mjs). The bridge now answers an ownerless page like an
--   owned one; this file gives those rows an owner so they keep working.
--
-- What it does
--   Sets osionos_pages.owner_id to the owner_id of the page's workspace for every
--   ownerless row, and records every page it changed in
--   public.osionos_page_owner_backfill, so the grant is undoable.
--   It changes nothing else: visibility, collaborators and the archive state stay
--   as they are, so a private ownerless page stays private and becomes readable by
--   its new owner only (not archived, not published).
--
-- The skip branch cannot happen (F9)
--   osionos_pages.workspace_id REFERENCES public.osionos_workspaces(id) ON DELETE
--   CASCADE and osionos_workspaces.owner_id is NOT NULL
--   (models/osionos-bridge-migration.sql), so an ownerless page always has exactly
--   one workspace row and that row always has an owner. The skipped count below is
--   therefore 0 by construction; it is printed anyway, so a database that somehow
--   broke the invariant says so instead of passing silently.
--
-- Idempotent: a second run updates 0 pages and records 0 pages.
--
-- Where it runs
--   models/*.sql is replayed on every boot (make models-migrate, and the desktop
--   edition's firstrun.mjs). One transaction: this database's default privileges
--   give anon/authenticated SELECT/INSERT/UPDATE/DELETE on every new public table,
--   so a half-applied file would leave the ledger writable with the public anon key
--   through Kong /rest/v1. Apply with
--     psql -v ON_ERROR_STOP=1 -f models/osionos-unowned-pages-backfill-migration.sql
--
-- Deploy order
--   Apply this file BEFORE (or with) the bridge that drops the legacy branch:
--   without it, an ownerless page stays unwritable for an admin-only membership
--   until this runs.
--
-- Caveat: the workspace owner becomes the page owner even when another member wrote
--   the page before it lost its owner — the page is then owned by someone who never
--   edited it, and that owner may re-share or archive it.
--
-- DOWN (manual, undo the grant):
--   UPDATE public.osionos_pages SET owner_id = NULL
--    WHERE id IN (SELECT page_id FROM osionos_page_owner_backfill);

BEGIN;

CREATE TABLE IF NOT EXISTS public.osionos_page_owner_backfill (
  page_id    UUID        PRIMARY KEY,
  new_owner  UUID        NOT NULL,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.osionos_page_owner_backfill IS
  'Every osionos_pages row the owner backfill gave an owner, and the owner it got. Undo: set osionos_pages.owner_id back to NULL for these ids.';

-- The bridge (service_role) is the only reader and writer; nobody else gets a grant.
REVOKE ALL ON public.osionos_page_owner_backfill FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.osionos_page_owner_backfill TO service_role;

ALTER TABLE public.osionos_page_owner_backfill ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_page_owner_backfill FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_page_owner_backfill_service_role_all ON public.osionos_page_owner_backfill;
CREATE POLICY osionos_page_owner_backfill_service_role_all ON public.osionos_page_owner_backfill
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- The realtime event trigger attaches a row-broadcasting trigger to every new public
-- table. Nothing consumes this ledger, and a broadcast is one more path out of it.
DROP TRIGGER IF EXISTS osionos_page_owner_backfill_realtime_trigger ON public.osionos_page_owner_backfill;

DO $$
DECLARE
  pending_pages   integer := 0;
  recorded_pages  integer := 0;
  updated_pages   integer := 0;
BEGIN
  -- The pre-run count: how many rows carried no owner before this file touched them.
  SELECT count(*) INTO pending_pages
    FROM public.osionos_pages
   WHERE owner_id IS NULL;

  -- The ledger first, the grant second: both statements select the same rows (an
  -- ownerless page of a workspace that exists), and one transaction undoes both.
  INSERT INTO public.osionos_page_owner_backfill (page_id, new_owner)
  SELECT p.id, w.owner_id
    FROM public.osionos_pages p
    JOIN public.osionos_workspaces w ON w.id = p.workspace_id
   WHERE p.owner_id IS NULL
  ON CONFLICT (page_id) DO NOTHING;
  GET DIAGNOSTICS recorded_pages = ROW_COUNT;

  UPDATE public.osionos_pages p
     SET owner_id = w.owner_id
    FROM public.osionos_workspaces w
   WHERE w.id = p.workspace_id
     AND p.owner_id IS NULL;
  GET DIAGNOSTICS updated_pages = ROW_COUNT;

  RAISE NOTICE 'osionos-unowned-pages-backfill: % ownerless page(s) before, % updated, % skipped, % recorded',
    pending_pages, updated_pages, pending_pages - updated_pages, recorded_pages;
END
$$;

COMMIT;

NOTIFY pgrst, 'reload schema';
