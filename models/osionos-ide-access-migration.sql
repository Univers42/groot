-- osionos IDE access list (OSIONOS_IDE_ACCESS=approved|verified, B1.2 of the 2026-10-17 verdict).
--
-- One row per account the operator has approved for the IDE sandbox, and the per-user
-- kill switch: `disabled_at` set refuses the next token mint (the plane re-checks only the
-- env denylist, so a disable takes effect within one 15-minute token lifetime).
--
-- Service-role only, like every public.osionos_* relation: RLS is on with NO policy, and
-- anon/authenticated hold no privilege. service_role carries BYPASSRLS, which is why no
-- policy is needed; osionos-service-role-only-migration.sql repeats the revoke for the
-- whole osionos_* family and runs after this file.
--
-- The default access mode (`allowlist`) never reads this table, so applying it changes
-- nothing until the operator sets OSIONOS_IDE_ACCESS. `verified` is BLOCKED (B1.L1-L7,
-- infrastructure/docker/osionos/ide-sandbox/README.md).
--
-- Idempotent. DOWN (manual): DROP TABLE public.osionos_ide_access;
CREATE TABLE IF NOT EXISTS public.osionos_ide_access (
  user_id     UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  approved_at TIMESTAMPTZ,
  disabled_at TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.osionos_ide_access ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.osionos_ide_access FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.osionos_ide_access TO service_role;

NOTIFY pgrst, 'reload schema';
