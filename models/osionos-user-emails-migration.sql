-- osionos-user-emails-migration.sql — secondary email addresses (F-3broot, F-3b).
--
-- WHY THIS FILE EXISTS
--   An account may prove ownership of extra addresses beyond its GoTrue primary.
--   The bridge keeps them here as ciphertext plus a keyed hash: whoever reads the
--   table learns nothing about the addresses without the bridge's keys, and the
--   database itself, not a read-then-write in the bridge, decides that one
--   VERIFIED address belongs to one user.
--
-- WHAT IT CREATES
--   public.osionos_user_emails   one row per (user, secondary address):
--     email_enc    the address sealed with AES-256-GCM by the bridge, AAD
--                  'osionos-user-email:v1:<user_id>'
--     email_hmac   HMAC-SHA256 (hex) of the lowercased, trimmed address
--     verified_at  NULL until the owner proved the mailbox with a code
--   Secondaries only: the primary address stays GoTrue's.
--
-- INDEXES
--   unique (user_id, email_hmac)                   a user lists an address once
--   unique (email_hmac) WHERE verified_at IS NOT NULL
--                                                  two users may both hold the
--                                                  address UNVERIFIED, only one
--                                                  can verify it
--   (user_id, created_at)                          the per-user list and the
--                                                  pending-row sweep
--
-- WHO REACHES WHAT
--   service_role          everything (the bridge, which filters user_id itself).
--   anon, authenticated,
--   osionos_account_user  nothing: no privilege, no policy, and the table carries
--                         no 'osionos:account-plane' comment.
--
-- WHERE IT RUNS
--   scripts/apply-models-migrations.sh lists it in ORDERED_LAST before the
--   erasure migration (whose registry row names this table) and before the
--   service-role-only pass.
--
-- Caveat: a verified secondary can come to equal another user's GoTrue primary AFTER it was verified (B changes primary through GoTrue's own flow, or a new account signs up or links OAuth with a provider-verified X); the primary has no row, so no index sees it. Nothing in F-3b grants authority to a secondary (no sign-in, recovery or invite reach). F-3b2 (make-primary) and any address-keyed lookup MUST recheck both directions.
-- Caveat: the add-time and verify-time GoTrue check is read-then-write and the admin list is one page; a full page with no exact match is treated as unprovable, never as absent.
-- Caveat: the answer to add is uniform but not constant-time in the detached task; delivery of the mail is observable by the mailbox owner only.
-- Caveat: the seal key rotates through OSIONOS_EMAIL_SEAL_KEY_PREVIOUS but there is NO re-seal path, so _PREVIOUS must stay set until a re-seal job exists. The lookup key (OSIONOS_EMAIL_LOOKUP_KEY) has NO rotation: changing it orphans every email_hmac, the verified-unique index silently stops matching and every address looks free; rotating it is unsupported without a backfill that re-HMACs every row from the opened address.
-- Caveat: aliases (a+1@x, dotted gmail) are distinct strings and bypass uniqueness by design.
--
-- Idempotent: a second run moves no grant or policy (check g of
-- scripts/verify/models-grants.sh); the indexes are IF NOT EXISTS, which check g does not snapshot.
--
-- DOWN (manual, IRREVERSIBLE for rows): DROP TABLE public.osionos_user_emails;

BEGIN;

-- Caveat: a busy table makes this file fail (the transaction rolls back) instead
-- of waiting; the next run retries it. 5 s is a budget, not a promise.
SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS public.osionos_user_emails (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  email_enc TEXT NOT NULL,
  email_hmac TEXT NOT NULL CHECK (email_hmac ~ '^[0-9a-f]{64}$'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  verified_at TIMESTAMPTZ,
  UNIQUE (user_id, email_hmac)
);

CREATE UNIQUE INDEX IF NOT EXISTS osionos_user_emails_verified_hmac_uidx
  ON public.osionos_user_emails (email_hmac) WHERE verified_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS osionos_user_emails_user_created_idx
  ON public.osionos_user_emails (user_id, created_at);

-- grobase's CREATE TABLE hook (012) broadcasts every row of every new public
-- table, and the realtime socket has no grant check: a broadcast of these rows
-- is a broadcast of the sealed addresses. Drop every trigger backed by the
-- broadcaster, regardless of trigger name.
DROP TRIGGER IF EXISTS osionos_user_emails_realtime_trigger ON public.osionos_user_emails;
DO $$
DECLARE
  trigger_name text;
BEGIN
  FOR trigger_name IN
    SELECT tg.tgname
      FROM pg_trigger tg
      JOIN pg_class c ON c.oid = tg.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relname = 'osionos_user_emails'
       AND NOT tg.tgisinternal
       AND tg.tgfoid = to_regprocedure('public.realtime_notify()')
  LOOP
    EXECUTE format('DROP TRIGGER %I ON public.osionos_user_emails', trigger_name);
  END LOOP;
END
$$;

ALTER TABLE public.osionos_user_emails ENABLE ROW LEVEL SECURITY;

-- The account role is named: a grant left over from a hand-made fix survives a
-- replay, and only a REVOKE takes it back.
REVOKE ALL ON public.osionos_user_emails FROM PUBLIC, anon, authenticated, osionos_account_user;
GRANT ALL ON public.osionos_user_emails TO service_role;

DROP POLICY IF EXISTS osionos_user_emails_service_role_all ON public.osionos_user_emails;
CREATE POLICY osionos_user_emails_service_role_all ON public.osionos_user_emails
  FOR ALL TO service_role USING (true) WITH CHECK (true);

COMMIT;
