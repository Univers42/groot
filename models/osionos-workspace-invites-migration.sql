-- osionos pending workspace invites, served ONLY through the bridge
-- (/api/workspaces/:id/invites, /api/invites/accept; scripts/bridge-workspace-invites.mjs).
--
-- An invite is a pending row, not a membership: the membership is written when the invited
-- account accepts. The token is a bearer secret, so only its sha256 hex is stored; the
-- plaintext is shown to the inviter once and never persisted.
--
-- One transaction: this database's default privileges give anon/authenticated
-- SELECT/INSERT/UPDATE/DELETE on every new public table, so a half-applied file would leave
-- the table writable with the public anon key through Kong /rest/v1. Apply with
--   psql -v ON_ERROR_STOP=1 -f models/osionos-workspace-invites-migration.sql
-- or `make apply-models`. Idempotent.

BEGIN;

CREATE TABLE IF NOT EXISTS public.osionos_workspace_invites (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id    UUID        NOT NULL REFERENCES public.osionos_workspaces(id) ON DELETE CASCADE,
  -- display only: acceptance compares invited_user_id with the session's user, never the email.
  email           TEXT        NOT NULL CHECK (char_length(email) <= 320),
  invited_user_id UUID        NOT NULL,
  -- the DB roles the bridge writes to osionos_workspace_members; never 'owner'.
  role            TEXT        NOT NULL CHECK (role IN ('admin', 'editor', 'viewer')),
  token_hash      TEXT        NOT NULL CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  expires_at      TIMESTAMPTZ NOT NULL,
  accepted_at     TIMESTAMPTZ,
  accepted_by     UUID,
  revoked_at      TIMESTAMPTZ,
  invited_by      UUID        NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One live invite per account per workspace. The bridge does not upsert against this index:
-- PostgREST's on_conflict emits ON CONFLICT (cols) DO UPDATE, and Postgres will not infer a
-- partial index (42P10). It SELECTs the live row and UPDATEs or INSERTs; this index refuses
-- the second live row when two requests race.
CREATE UNIQUE INDEX IF NOT EXISTS osionos_workspace_invites_live_idx
  ON public.osionos_workspace_invites (workspace_id, invited_user_id)
  WHERE accepted_at IS NULL AND revoked_at IS NULL;

-- Accept looks the invite up by hash.
CREATE UNIQUE INDEX IF NOT EXISTS osionos_workspace_invites_token_hash_idx
  ON public.osionos_workspace_invites (token_hash);

REVOKE ALL ON public.osionos_workspace_invites FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.osionos_workspace_invites TO service_role;

ALTER TABLE public.osionos_workspace_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_workspace_invites FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_workspace_invites_service_role_all ON public.osionos_workspace_invites;
CREATE POLICY osionos_workspace_invites_service_role_all ON public.osionos_workspace_invites
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- The realtime event trigger attaches a row-broadcasting trigger to every new public table.
-- Nothing consumes invite changes, and a broadcast is one more path out of the table.
DROP TRIGGER IF EXISTS osionos_workspace_invites_realtime_trigger ON public.osionos_workspace_invites;

COMMIT;

NOTIFY pgrst, 'reload schema';
