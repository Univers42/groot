-- Public page publishing: an explicit SNAPSHOT of a page (content copied at
-- publish time, never a live-table read). The unauthenticated public GET reads
-- ONLY this table. service_role-only (the bridge mediates every access); no
-- authenticated/anon grant. Idempotent. Feature is flag-gated OFF at the bridge
-- (OSIONOS_PUBLISH_ENABLED) — this table is inert until then.

CREATE TABLE IF NOT EXISTS public.osionos_published_pages (
  token        TEXT PRIMARY KEY DEFAULT encode(gen_random_bytes(16), 'hex'),
  page_id      UUID NOT NULL UNIQUE REFERENCES public.osionos_pages(id) ON DELETE CASCADE,
  owner_id     UUID NOT NULL,
  title        TEXT NOT NULL,
  icon         TEXT,
  content      JSONB NOT NULL,
  published_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.osionos_published_pages ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_published_pages_service_role_all ON public.osionos_published_pages;
CREATE POLICY osionos_published_pages_service_role_all ON public.osionos_published_pages
  FOR ALL TO service_role USING (true) WITH CHECK (true);
GRANT ALL ON public.osionos_published_pages TO service_role;

NOTIFY pgrst, 'reload schema';

-- The publish cascade (C633, devil verdict share-p1): a published snapshot dies
-- with the page's hold. The anonymous public GET serves ONLY
-- public.osionos_published_pages, so a snapshot that outlives its owner's hold
-- is a public leak of content the owner withdrew. The page DELETE already
-- removes the row (the table's own ON DELETE CASCADE, line 9), but the hold
-- ends in ways no DELETE carries:
--   - the page is archived             -> the snapshot is gone;
--   - the page's owner_id changes      -> the snapshot is gone (an ownership
--     transfer, or the erasure's transfer of a shared page to the workspace's
--     new owner, models/osionos-account-erasure-migration.sql, the shared-page transfer);
--   - the page's workspace_id changes  -> the snapshot is gone (the owner may
--     hold no members row in the new workspace);
--   - the owner loses their members row in the page's workspace (deleted, or
--     the row's workspace_id/user_id changes) -> the owner no longer holds
--     the page (C557 ownerHoldsPage is "the caller is the page owner AND has a
--     members row in the page's workspace"), so the snapshot is gone.
-- The erasure of the owner itself already deletes the owner's published rows
-- through its data map (its osionos_published_pages row); this
-- block does not duplicate that path, it only makes the transfer and the
-- members delete safe on their own. Re-publishing after unarchive is the
-- owner's explicit act, so unarchive removes nothing. A role change
-- (editor -> viewer) writes nothing: it is not a loss of the hold.
--
-- WHY THESE SHAPES (copied from models/osionos-membership-cutoff-migration.sql):
--   * no column list (never UPDATE OF ...): nothing runs unless the WHEN clause
--     matches, so content, title and icon saves never call the function;
--   * TWO member triggers, not one: PostgreSQL refuses a WHEN condition that
--     references NEW on a trigger that also fires on DELETE, so the
--     (workspace_id, user_id) value-change guard lives on the UPDATE trigger
--     alone and the DELETE trigger needs none -- every delete of a members row
--     IS a loss of the hold;
--   * NOT deferred: nothing is stamped here, and the snapshot delete belongs
--     to the same transaction as the change that removed the hold;
--   * SECURITY DEFINER with SET search_path = pg_catalog: the snapshot delete
--     happens even when the changing transaction's role has no INSERT/DELETE
--     grant on osionos_published_pages (only service_role holds one), and every
--     relation name in the bodies is schema-qualified so no other search_path
--     is read;
--   * REVOKE ALL ON FUNCTION ... FROM PUBLIC: trigger functions are not
--     callable APIs, only their triggers are.
--
-- Caveat: this removes the SNAPSHOT, not copies an edge/CDN/browser already
-- holds: those keep serving up to the bridge's Cache-Control max-age (60 s,
-- on the osionos bridge's public route). A share-rule no_access set on the
-- page AFTER publishing does NOT unpublish: the owner keeps full access to
-- their own page under C557.
--
-- Caveat: a members row is not the only hold the bridge accepts -- a page in
-- the marketplace workspace (5a4b1c2d-1111-4111-8111-000000000001) holds
-- without one. The members triggers delete on every row they match, so for a
-- published page in a marketplace membership they are on the strict side: one
-- re-publish call puts the snapshot back.
--
-- A staged workspace delete (pending_delete_at) also ends every hold in it; that
-- trigger lives in osionos-workspace-publish-hold-migration.sql because the
-- column is added by osionos-workspace-lifecycle-migration.sql, which sorts
-- after this file.

BEGIN;

-- The runner re-applies this file on every run, and the DROP/CREATE TRIGGER
-- pair below takes an exclusive lock on osionos_pages and
-- osionos_workspace_members until COMMIT: fail fast behind a long transaction
-- rather than stall every page read and write queued behind this one.
SET LOCAL lock_timeout = '5s';

-- The unhold trigger's owner look-up: the members delete below joins
-- osionos_published_pages by owner_id.
CREATE INDEX IF NOT EXISTS osionos_published_pages_owner_idx
  ON public.osionos_published_pages(owner_id);

-- Page side: archive, owner change or workspace move removes the snapshot.
CREATE OR REPLACE FUNCTION public.osionos_published_page_unhold() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  DELETE FROM public.osionos_published_pages WHERE page_id = NEW.id;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS osionos_publish_unhold ON public.osionos_pages;
CREATE TRIGGER osionos_publish_unhold
AFTER UPDATE ON public.osionos_pages
FOR EACH ROW
WHEN ((OLD.archived_at IS NULL AND NEW.archived_at IS NOT NULL)
      OR OLD.owner_id IS DISTINCT FROM NEW.owner_id
      OR OLD.workspace_id IS DISTINCT FROM NEW.workspace_id)
EXECUTE FUNCTION public.osionos_published_page_unhold();

-- Members side: the owner stops holding the page when their members row in the
-- page's workspace leaves.
CREATE OR REPLACE FUNCTION public.osionos_published_member_left() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  DELETE FROM public.osionos_published_pages pp
   USING public.osionos_pages p
   WHERE pp.page_id = p.id AND pp.owner_id = OLD.user_id
     AND p.workspace_id = OLD.workspace_id;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS osionos_publish_member_left_delete ON public.osionos_workspace_members;
CREATE TRIGGER osionos_publish_member_left_delete
AFTER DELETE ON public.osionos_workspace_members
FOR EACH ROW
EXECUTE FUNCTION public.osionos_published_member_left();

-- No column list: a role or permissions change writes nothing.
DROP TRIGGER IF EXISTS osionos_publish_member_left_move ON public.osionos_workspace_members;
CREATE TRIGGER osionos_publish_member_left_move
AFTER UPDATE ON public.osionos_workspace_members
FOR EACH ROW
WHEN ((OLD.workspace_id, OLD.user_id) IS DISTINCT FROM (NEW.workspace_id, NEW.user_id))
EXECUTE FUNCTION public.osionos_published_member_left();

-- Trigger functions are not callable APIs.
REVOKE ALL ON FUNCTION public.osionos_published_page_unhold() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.osionos_published_member_left() FROM PUBLIC;

-- The triggers see only changes made after they exist: a snapshot whose hold
-- ended earlier (page archived, owner changed, owner out of the workspace)
-- would stay public. Re-run every apply; a consistent table loses nothing.
-- The marketplace workspace is exempt from the members test (no members row
-- is its hold, see the Caveat above): a re-apply must not undo a re-publish.
DELETE FROM public.osionos_published_pages pp
 USING public.osionos_pages p
 WHERE pp.page_id = p.id
   AND (p.archived_at IS NOT NULL
        OR p.owner_id IS DISTINCT FROM pp.owner_id
        OR (p.workspace_id <> '5a4b1c2d-1111-4111-8111-000000000001'::uuid
            AND NOT EXISTS (SELECT 1 FROM public.osionos_workspace_members m
                             WHERE m.workspace_id = p.workspace_id AND m.user_id = pp.owner_id)));

COMMIT;

NOTIFY pgrst, 'reload schema';

-- DOWN (manual):
--   DROP TRIGGER osionos_publish_unhold ON public.osionos_pages;
--   DROP TRIGGER osionos_publish_member_left_delete ON public.osionos_workspace_members;
--   DROP TRIGGER osionos_publish_member_left_move ON public.osionos_workspace_members;
--   DROP FUNCTION public.osionos_published_page_unhold();
--   DROP FUNCTION public.osionos_published_member_left();
--   DROP INDEX IF EXISTS public.osionos_published_pages_owner_idx;
-- The page DELETE cascade (line 9) stays: it is the table's own definition.
