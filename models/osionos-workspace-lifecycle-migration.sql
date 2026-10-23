-- osionos workspace lifecycle (P3-5-b): the delete grace window and the ownership hand-over.
--
-- pending_delete_at / delete_after stage a delete: the bridge sets them and touches NOTHING else
-- for 14 days; only a later sweep may remove data once delete_after has passed.
--
-- osionos_workspace_transfer_ownership moves ownership in ONE statement block so the workspace
-- never has two owners or none, which two separate member updates over PostgREST cannot promise.
-- It locks the workspace row and both member rows (in user_id order, so two concurrent transfers
-- cannot deadlock) and returns false, changing nothing, when the premise no longer holds.
-- osionos_workspace_mark_delete stages a delete atomically: it locks every workspace the owner
-- holds (ORDER BY id, so two concurrent deletes serialise instead of both seeing the other as the
-- survivor), refuses the last live one, and binds the mark to the owner it just checked. A pending
-- row whose grace has passed with no sweep may be stamped again.
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
  v_pending TIMESTAMPTZ;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_from = p_to THEN
    RETURN false;
  END IF;

  SELECT owner_id, pending_delete_at INTO v_owner, v_pending
    FROM public.osionos_workspaces WHERE id = p_workspace FOR UPDATE;
  IF v_owner IS DISTINCT FROM p_from OR v_pending IS NOT NULL THEN
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

CREATE OR REPLACE FUNCTION public.osionos_workspace_mark_delete(
  p_workspace UUID, p_owner UUID, p_now TIMESTAMPTZ, p_after TIMESTAMPTZ
) RETURNS TEXT
LANGUAGE plpgsql
SET search_path = public, pg_temp
SET lock_timeout = '5s'
AS $$
DECLARE
  v_owner UUID;
  v_pending TIMESTAMPTZ;
  v_after TIMESTAMPTZ;
  v_others INT;
BEGIN
  PERFORM 1 FROM public.osionos_workspaces WHERE owner_id = p_owner ORDER BY id FOR UPDATE;

  SELECT owner_id, pending_delete_at, delete_after INTO v_owner, v_pending, v_after
    FROM public.osionos_workspaces WHERE id = p_workspace;
  IF v_owner IS DISTINCT FROM p_owner THEN
    RETURN 'not_owner';
  END IF;
  IF v_pending IS NOT NULL AND v_after > p_now THEN
    RETURN 'already_pending';
  END IF;

  SELECT count(*) INTO v_others FROM public.osionos_workspaces
   WHERE owner_id = p_owner AND id <> p_workspace AND pending_delete_at IS NULL;
  IF v_others < 1 THEN
    RETURN 'last_workspace';
  END IF;

  UPDATE public.osionos_workspaces
     SET pending_delete_at = p_now, delete_after = p_after, updated_at = now()
   WHERE id = p_workspace AND owner_id = p_owner;
  RETURN 'marked';
END;
$$;

REVOKE ALL ON FUNCTION public.osionos_workspace_mark_delete(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.osionos_workspace_mark_delete(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';
