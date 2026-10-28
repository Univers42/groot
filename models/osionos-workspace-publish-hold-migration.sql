-- A staged workspace delete ends every published snapshot in it (C633, devil
-- verdict share-p1). osionos-workspace-lifecycle-migration.sql stages a delete by
-- stamping pending_delete_at and touches nothing else for 14 days, so pages and
-- members rows stay and none of the triggers in osionos-publish-migration.sql
-- fire: without this, the anonymous public GET would keep serving the deleted
-- workspace's published pages for the whole grace window.
--
-- This file is NAMED to sort after osionos-workspace-lifecycle-migration.sql,
-- which adds the column the WHEN clause reads (the runner's alphabetical pass).
-- Cancelling the delete restores nothing: re-publishing is the owner's explicit
-- act, as after an unarchive. Idempotent.

BEGIN;

-- Same reason as the publish migration: DROP/CREATE TRIGGER locks the table.
SET LOCAL lock_timeout = '5s';

CREATE OR REPLACE FUNCTION public.osionos_published_workspace_pending() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  DELETE FROM public.osionos_published_pages pp
   USING public.osionos_pages p
   WHERE pp.page_id = p.id AND p.workspace_id = NEW.id;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS osionos_publish_workspace_pending ON public.osionos_workspaces;
CREATE TRIGGER osionos_publish_workspace_pending
AFTER UPDATE ON public.osionos_workspaces
FOR EACH ROW
WHEN (OLD.pending_delete_at IS NULL AND NEW.pending_delete_at IS NOT NULL)
EXECUTE FUNCTION public.osionos_published_workspace_pending();

REVOKE ALL ON FUNCTION public.osionos_published_workspace_pending() FROM PUBLIC;

-- A workspace already pending when this trigger first appeared.
DELETE FROM public.osionos_published_pages pp
 USING public.osionos_pages p, public.osionos_workspaces w
 WHERE pp.page_id = p.id AND w.id = p.workspace_id AND w.pending_delete_at IS NOT NULL;

COMMIT;
