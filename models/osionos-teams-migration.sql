-- osionos teams: a named subset of a workspace's members, served ONLY through the bridge
-- (/api/workspaces/:id/teams; scripts/bridge-workspace-teams.mjs).
--
-- A team's member is always a member of the workspace: the composite foreign key below is the
-- invariant, so removing someone from the workspace removes them from every team, and the
-- database (not only the bridge) refuses a team member who is not a workspace member.
--
-- One transaction: this database's default privileges give anon/authenticated
-- SELECT/INSERT/UPDATE/DELETE on every new public table, so a half-applied file would leave
-- the tables writable with the public anon key through Kong /rest/v1. Apply with
--   psql -v ON_ERROR_STOP=1 -f models/osionos-teams-migration.sql
-- or `make apply-models`. Idempotent.

BEGIN;

CREATE TABLE IF NOT EXISTS public.osionos_teams (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID        NOT NULL REFERENCES public.osionos_workspaces(id) ON DELETE CASCADE,
  name         TEXT        NOT NULL CHECK (char_length(name) BETWEEN 1 AND 80),
  description  TEXT        NOT NULL DEFAULT '' CHECK (char_length(description) <= 500),
  created_by   UUID        NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  archived_at  TIMESTAMPTZ,
  CONSTRAINT osionos_teams_name_unique UNIQUE (workspace_id, name),
  -- the target of the member table's composite foreign key
  CONSTRAINT osionos_teams_workspace_id_unique UNIQUE (workspace_id, id)
);

CREATE TABLE IF NOT EXISTS public.osionos_team_members (
  workspace_id UUID        NOT NULL,
  team_id      UUID        NOT NULL,
  user_id      UUID        NOT NULL,
  role         TEXT        NOT NULL DEFAULT 'member' CHECK (role IN ('member', 'lead')),
  added_by     UUID        NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (team_id, user_id),
  CONSTRAINT osionos_team_members_team_fk FOREIGN KEY (workspace_id, team_id)
    REFERENCES public.osionos_teams (workspace_id, id) ON DELETE CASCADE,
  CONSTRAINT osionos_team_members_workspace_member_fk FOREIGN KEY (workspace_id, user_id)
    REFERENCES public.osionos_workspace_members (workspace_id, user_id) ON DELETE CASCADE
);

-- The PK is (team_id, user_id), so "the members of a workspace" has no index of its own; the
-- erase and the share-rule evaluator (a caller's teams) read by workspace and by user.
CREATE INDEX IF NOT EXISTS osionos_team_members_workspace_idx
  ON public.osionos_team_members (workspace_id, team_id);
CREATE INDEX IF NOT EXISTS osionos_team_members_user_idx
  ON public.osionos_team_members (user_id);

REVOKE ALL ON public.osionos_teams, public.osionos_team_members FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.osionos_teams, public.osionos_team_members TO service_role;

ALTER TABLE public.osionos_teams ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_teams FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_teams_service_role_all ON public.osionos_teams;
CREATE POLICY osionos_teams_service_role_all ON public.osionos_teams
  FOR ALL TO service_role USING (true) WITH CHECK (true);

ALTER TABLE public.osionos_team_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_team_members FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_team_members_service_role_all ON public.osionos_team_members;
CREATE POLICY osionos_team_members_service_role_all ON public.osionos_team_members
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- The realtime event trigger attaches a row-broadcasting trigger to every new public table.
-- Nothing consumes team changes, and a broadcast is one more path out of the tables.
DROP TRIGGER IF EXISTS osionos_teams_realtime_trigger ON public.osionos_teams;
DROP TRIGGER IF EXISTS osionos_team_members_realtime_trigger ON public.osionos_team_members;

COMMIT;

NOTIFY pgrst, 'reload schema';
