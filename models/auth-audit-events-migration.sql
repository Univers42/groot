-- public.auth_audit_events and public.auth_record_audit_event(): the auth-gateway's audit trail,
-- uuid-native, on grobase's postgres. The gateway calls the function over Kong /rest/v1/rpc with
-- the service key (apps/opposite-osiris/scripts/auth-gateway.mjs audit()).
--
-- Why a second file next to auth-security-migration.sql: that one is skipped by
-- scripts/apply-models-migrations.sh (its users.id is INTEGER, grobase's is uuid), so the audit
-- RPC never existed here and every audit() call was swallowed with a warning. This file is the
-- applied one. It is safe on a database that lacks the objects and on one carrying the old
-- shape (integer user_id, a narrower CHECK, a function with its own copy of the event list):
-- the table is kept (user_id retyped to uuid when it is integer), the CHECK and the function are replaced.
--
-- The CHECK is the ONE event list. The function no longer repeats it: an unknown event is
-- refused by the CHECK (23514). scripts/tests/auth-audit-events.bats fails when the gateway
-- emits an event this list lacks.
--
-- Runner position: plain alphabetical order, no dependency on another models file
-- (public.users comes from grobase 001_initial_schema.sql). Idempotent.
-- Realtime: realtime-cdc-off-migration.sql (ORDERED_LAST) drops the row-broadcast trigger
-- grobase's CREATE TABLE hook gives this table.
--
-- DOWN (manual): DROP FUNCTION public.auth_record_audit_event(TEXT, TEXT, JSONB);
--                DROP TABLE public.auth_audit_events;

BEGIN;

CREATE TABLE IF NOT EXISTS public.auth_audit_events (
  id BIGSERIAL PRIMARY KEY,
  event_type VARCHAR(64) NOT NULL,
  user_id uuid NULL,
  email VARCHAR(255),
  ip_address VARCHAR(255),
  user_agent VARCHAR(1024),
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- An old-shape table has user_id INTEGER (and an FK to an integer users table). Against
-- grobase's uuid public.users those ids point at nothing, and the function's lookup would fail
-- on the first known email. Caveat: the integer values are discarded (set to NULL), not mapped.
DO $$
DECLARE
  fk record;
BEGIN
  IF (SELECT atttypid FROM pg_attribute
       WHERE attrelid = 'public.auth_audit_events'::regclass AND attname = 'user_id') = 'integer'::regtype THEN
    FOR fk IN
      SELECT conname FROM pg_constraint
       WHERE conrelid = 'public.auth_audit_events'::regclass AND contype = 'f'
         AND conkey = ARRAY[(SELECT attnum FROM pg_attribute
                              WHERE attrelid = 'public.auth_audit_events'::regclass AND attname = 'user_id')]
    LOOP
      EXECUTE format('ALTER TABLE public.auth_audit_events DROP CONSTRAINT %I', fk.conname);
    END LOOP;
    ALTER TABLE public.auth_audit_events ALTER COLUMN user_id TYPE uuid USING NULL;
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS auth_audit_events_event_created_idx ON public.auth_audit_events (event_type, created_at DESC);
CREATE INDEX IF NOT EXISTS auth_audit_events_email_created_idx ON public.auth_audit_events (lower(email), created_at DESC);

ALTER TABLE public.auth_audit_events DROP CONSTRAINT IF EXISTS auth_audit_events_event_type_check;
ALTER TABLE public.auth_audit_events ADD CONSTRAINT auth_audit_events_event_type_check CHECK (event_type IN (
    'register_requested',
    'register_failed',
    'register_profile_failed',
    'register_dev_confirmed',
    'register_dev_failed',
    'register_turnstile_failed',
    'account_created_email_sent',
    'account_created_email_failed',
    'account_exists_email_sent',
    'account_mail_throttled',
    'email_verification_sent',
    'email_verified',
    'verification_resend_link_failed',
    'resend_turnstile_failed',
    'login_success',
    'login_failed',
    'login_locked',
    'login_lockout_triggered',
    'login_email_unconfirmed',
    'login_turnstile_failed',
    'login_alert_sent',
    'login_alert_failed',
    'login_alert_skipped',
    'login_alert_suppressed',
    'login_otp_requested',
    'login_otp_request_failed',
    'login_otp_verified',
    'login_otp_failed',
    'login_otp_expired',
    'login_otp_locked',
    'recover_turnstile_failed',
    'password_recovery_requested',
    'password_recovery_email_sent',
    'password_recovery_link_failed',
    'password_reset_completed',
    'password_reset_logout_failed',
    'password_reset_cutoff_failed',
    'password_changed',
    'password_changed_email_sent',
    'auth_link_refused',
    'newsletter_optin_requested',
    'newsletter_target_throttled',
    'newsletter_confirmation_email_sent',
    'newsletter_confirmation_email_failed',
    'newsletter_welcome_email_sent',
    'newsletter_welcome_email_failed',
    'newsletter_unsubscribe_email_sent',
    'newsletter_unsubscribe_email_failed',
    'osionos_bridge_success',
    'osionos_bridge_failed',
    'osionos_bridge_redirect_rejected',
    'refresh_success',
    'refresh_failed',
    'logout',
    'mail_queue_overflow',
    'mail_job_failed',
    'mfa_totp_enroll_started',
    'mfa_totp_verified',
    'webauthn_challenge_started',
    'ip_shift_detected'
  ));

COMMENT ON TABLE public.auth_audit_events IS 'security_monitoring: sensitive authentication events, failed logins, password recovery, token refreshes, MFA hooks and IP shifts; retain for 13 months unless a documented legal hold applies.';

-- Parameter names are the RPC contract (PostgREST binds the JSON keys to them).
CREATE OR REPLACE FUNCTION public.auth_record_audit_event(event_type TEXT, email TEXT DEFAULT NULL, details JSONB DEFAULT '{}'::jsonb)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  normalized_email TEXT;
  matched_user_id public.auth_audit_events.user_id%TYPE;
  event_id BIGINT;
BEGIN
  normalized_email := lower(NULLIF(trim(email), ''));

  SELECT id INTO matched_user_id FROM public.users WHERE lower(users.email) = normalized_email LIMIT 1;

  INSERT INTO public.auth_audit_events (event_type, user_id, email, ip_address, user_agent, details)
  VALUES (
    event_type,
    matched_user_id,
    normalized_email,
    COALESCE(current_setting('request.header.x-forwarded-for', true), current_setting('request.header.x-real-ip', true)),
    current_setting('request.header.user-agent', true),
    COALESCE(details, '{}'::jsonb)
  )
  RETURNING id INTO event_id;

  RETURN jsonb_build_object('status', 'recorded', 'event_id', event_id);
END;
$$;

ALTER TABLE public.auth_audit_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS auth_audit_events_no_public_access ON public.auth_audit_events;
DROP POLICY IF EXISTS auth_audit_events_service_role_all ON public.auth_audit_events;
CREATE POLICY auth_audit_events_service_role_all ON public.auth_audit_events
  FOR ALL TO service_role USING (true) WITH CHECK (true);

REVOKE ALL ON public.auth_audit_events FROM PUBLIC, anon, authenticated;
GRANT INSERT, SELECT ON public.auth_audit_events TO service_role;
REVOKE ALL ON SEQUENCE public.auth_audit_events_id_seq FROM PUBLIC, anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.auth_audit_events_id_seq TO service_role;
-- PUBLIC holds EXECUTE on a new function; revoking from anon alone leaves it reachable.
REVOKE ALL ON FUNCTION public.auth_record_audit_event(TEXT, TEXT, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auth_record_audit_event(TEXT, TEXT, JSONB) TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';
