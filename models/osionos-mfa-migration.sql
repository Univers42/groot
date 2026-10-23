-- osionos-mfa-migration.sql — the two-step verification secrets (P3-2, wave 0).
--
-- WHY THIS FILE EXISTS
--   The bridge verifies TOTP codes and recovery codes itself (GoTrue's factor
--   table is not used). What it must keep is secret material: an encrypted TOTP
--   seed and the HMACs of the recovery codes. Whoever reads either can pass the
--   second factor, so neither table has any reach but the bridge's.
--
-- WHAT IT CREATES
--   public.osionos_mfa_totp            one row per user: secret_enc (AES-256-GCM,
--                                       written by the bridge), status, last_step
--                                       (replay guard), verified_at
--   public.osionos_mfa_recovery_codes  one row per code: code_hmac (HMAC-SHA256
--                                       with a server pepper), generation (a
--                                       regenerate inserts the new set before it
--                                       deletes the old, so a crash never leaves
--                                       zero), used_at (single use)
--
-- WHO REACHES WHAT
--   service_role          everything (the bridge).
--   anon, authenticated,
--   osionos_account_user  nothing: no table or column privilege, no policy, and
--                         the tables carry no 'osionos:account-plane' comment.
--
-- WHERE IT RUNS
--   scripts/apply-models-migrations.sh lists it in ORDERED_LAST before the
--   service-role-only pass, which must find it already built.
--
-- Idempotent: a second run moves no grant, policy or index (check g of
-- scripts/verify/models-grants.sh).
--
-- DOWN (manual, IRREVERSIBLE for enrolled users): DROP TABLE
-- public.osionos_mfa_recovery_codes, public.osionos_mfa_totp;

BEGIN;

-- Caveat: a busy table makes this file fail (the transaction rolls back) instead
-- of waiting; the next run retries it. 5 s is a budget, not a promise.
SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS public.osionos_mfa_totp (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  secret_enc TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending','verified')),
  last_step BIGINT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  verified_at TIMESTAMPTZ,
  CHECK ((status = 'verified') = (verified_at IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS public.osionos_mfa_recovery_codes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  code_hmac TEXT NOT NULL CHECK (code_hmac ~ '^[0-9a-f]{64}$'),
  generation INTEGER NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  used_at TIMESTAMPTZ,
  UNIQUE (user_id, code_hmac)
);

-- "How many codes are left" and the generation sweep both read by user.
CREATE INDEX IF NOT EXISTS osionos_mfa_recovery_codes_user_used_idx
  ON public.osionos_mfa_recovery_codes (user_id, used_at);

-- grobase's CREATE TABLE hook (012) broadcasts every row of every new public
-- table, and the realtime socket has no grant check: a broadcast of these rows
-- is a broadcast of the secrets. Drop every trigger backed by the broadcaster,
-- regardless of trigger name, before the migration can proceed.
DROP TRIGGER IF EXISTS osionos_mfa_totp_realtime_trigger ON public.osionos_mfa_totp;
DROP TRIGGER IF EXISTS osionos_mfa_recovery_codes_realtime_trigger ON public.osionos_mfa_recovery_codes;
DO $$
DECLARE
  table_name text;
  trigger_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY['osionos_mfa_totp', 'osionos_mfa_recovery_codes'] LOOP
    FOR trigger_name IN
      SELECT tg.tgname
        FROM pg_trigger tg
        JOIN pg_class c ON c.oid = tg.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public'
         AND c.relname = table_name
         AND NOT tg.tgisinternal
         AND tg.tgfoid = to_regprocedure('public.realtime_notify()')
    LOOP
      EXECUTE format('DROP TRIGGER %I ON public.%I', trigger_name, table_name);
    END LOOP;
  END LOOP;
END
$$;

ALTER TABLE public.osionos_mfa_totp ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_mfa_recovery_codes ENABLE ROW LEVEL SECURITY;

-- The account role is named: a grant left over from a hand-made fix survives a
-- replay, and only a REVOKE takes it back.
REVOKE ALL ON public.osionos_mfa_totp FROM PUBLIC, anon, authenticated, osionos_account_user;
REVOKE ALL ON public.osionos_mfa_recovery_codes FROM PUBLIC, anon, authenticated, osionos_account_user;
GRANT ALL ON public.osionos_mfa_totp TO service_role;
GRANT ALL ON public.osionos_mfa_recovery_codes TO service_role;

DROP POLICY IF EXISTS osionos_mfa_totp_service_role_all ON public.osionos_mfa_totp;
CREATE POLICY osionos_mfa_totp_service_role_all ON public.osionos_mfa_totp
  FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS osionos_mfa_recovery_codes_service_role_all ON public.osionos_mfa_recovery_codes;
CREATE POLICY osionos_mfa_recovery_codes_service_role_all ON public.osionos_mfa_recovery_codes
  FOR ALL TO service_role USING (true) WITH CHECK (true);

COMMIT;
