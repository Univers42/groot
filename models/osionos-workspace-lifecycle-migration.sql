-- osionos workspace lifecycle (P3-5-b): the delete grace window and the ownership hand-over.
--
-- pending_delete_at / delete_after stage a delete: the bridge sets them and touches NOTHING else
-- for 14 days; only a later sweep may remove data once delete_after has passed.
--
-- osionos_workspace_transfer_ownership moves ownership in ONE statement block so the workspace
-- never has two owners or none, which two separate member updates over PostgREST cannot promise.
-- It locks the workspace row and both member rows (in user_id order, so two concurrent transfers
-- cannot deadlock) and returns false, changing nothing, when the premise no longer holds.
-- Called by the bridge with the service key only. Apply with
--   psql -v ON_ERROR_STOP=1 -f models/osionos-workspace-lifecycle-migration.sql
-- or `make apply-models`. Idempotent.

BEGIN;

ALTER TABLE public.osionos_workspaces
  ADD COLUMN IF NOT EXISTS pending_delete_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS delete_after      TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION public.osionos_workspace_transfer_ownership(
  p_workspace UUID, p_from UUID, p_to UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql
SET search_path = public, pg_temp
SET lock_timeout = '5s'
AS $$
DECLARE
  v_owner UUID;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_from = p_to THEN
    RETURN false;
  END IF;

  SELECT owner_id INTO v_owner FROM public.osionos_workspaces WHERE id = p_workspace FOR UPDATE;
  IF v_owner IS DISTINCT FROM p_from THEN
    RETURN false;
  END IF;

  PERFORM 1 FROM public.osionos_workspace_members
   WHERE workspace_id = p_workspace AND user_id IN (p_from, p_to)
   ORDER BY user_id FOR UPDATE;
  IF NOT EXISTS (SELECT 1 FROM public.osionos_workspace_members
                  WHERE workspace_id = p_workspace AND user_id = p_to) THEN
    RETURN false;
  END IF;

  INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role, permissions)
  VALUES (p_workspace, p_from, 'admin', ARRAY['create','read','update','delete','admin'])
  ON CONFLICT (workspace_id, user_id)
  DO UPDATE SET role = 'admin', permissions = EXCLUDED.permissions, updated_at = now();

  UPDATE public.osionos_workspace_members
     SET role = 'owner', permissions = ARRAY['create','read','update','delete','admin'], updated_at = now()
   WHERE workspace_id = p_workspace AND user_id = p_to;

  UPDATE public.osionos_workspaces SET owner_id = p_to, updated_at = now() WHERE id = p_workspace;
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.osionos_workspace_transfer_ownership(UUID, UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.osionos_workspace_transfer_ownership(UUID, UUID, UUID) TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';
