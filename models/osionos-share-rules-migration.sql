-- osionos share rules (the Share dialog's per-page AccessRules), served ONLY through the
-- bridge (/api/perms/rules, scripts/bridge-perms-rules.mjs), which checks the caller's live
-- workspace access and validates every rule before it writes.
--
-- They used to be a JSON file in the bridge container's /tmp: lost on every recreate and
-- absent from the vault's pg_dumpall seed. Here they are durable and travel with the seeds.
--
-- One transaction: this database's default privileges give anon/authenticated
-- SELECT/INSERT/UPDATE/DELETE on every new public table, so a half-applied file would leave
-- the table writable with the public anon key through Kong /rest/v1. Apply with
--   psql -v ON_ERROR_STOP=1 -f models/osionos-share-rules-migration.sql
-- or `make apply-models`. Idempotent.

BEGIN;

CREATE TABLE IF NOT EXISTS public.osionos_share_rules (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id  UUID        NOT NULL REFERENCES public.osionos_workspaces(id) ON DELETE CASCADE,
  resource_type TEXT        NOT NULL DEFAULT 'page'
                CHECK (resource_type IN ('workspace', 'page', 'database', 'block')),
  -- '' = the whole workspace (the API reports null). Not NULL, so the plain UNIQUE below can
  -- serve PostgREST's on_conflict upsert.
  resource_id   TEXT        NOT NULL DEFAULT '' CHECK (char_length(resource_id) <= 256),
  target        JSONB       NOT NULL CHECK (target ? 'type'),
  -- type:userId:role — computed by the bridge from the normalized target; the rule identity.
  target_key    TEXT        NOT NULL CHECK (char_length(target_key) <= 200),
  permission    TEXT        NOT NULL
                CHECK (permission IN ('no_access', 'can_view', 'can_comment', 'can_edit', 'full_access')),
  explicit      BOOLEAN     NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT osionos_share_rules_identity UNIQUE (workspace_id, resource_type, resource_id, target_key)
);

CREATE INDEX IF NOT EXISTS osionos_share_rules_resource_idx
  ON public.osionos_share_rules (workspace_id, resource_id);

-- The bridge (service_role) is the only reader and writer; nobody else gets a grant.
REVOKE ALL ON public.osionos_share_rules FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.osionos_share_rules TO service_role;

ALTER TABLE public.osionos_share_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_share_rules FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_share_rules_service_role_all ON public.osionos_share_rules;
CREATE POLICY osionos_share_rules_service_role_all ON public.osionos_share_rules
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- The realtime event trigger attaches a row-broadcasting trigger to every new public table.
-- Nothing consumes share-rule changes, and a broadcast is one more path out of the table.
DROP TRIGGER IF EXISTS osionos_share_rules_realtime_trigger ON public.osionos_share_rules;

COMMIT;

NOTIFY pgrst, 'reload schema';
