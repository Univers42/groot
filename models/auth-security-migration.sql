-- Authentication security migration for track-binocle / Prismatica
-- Adds audit logging for sensitive authentication events.
-- Last updated: 2026-10-21

BEGIN;

SET LOCAL search_path = public;

-- The audit table follows whatever type public.users.id has instead of hard-coding one: the
-- auth gateway's BaaS database has a uuid users.id, while the databases that apply user.sql
-- (grobase's track-binocle project init, osionos-electron's first run) have an integer one.
-- A hard-coded integer fails the foreign key on a uuid users.id, and that failure is silent:
-- the gateway's audit call 404s and every event — failed logins, password recovery, signup
-- refusals — is dropped. The type is therefore read from the catalog at migration time.
DO $$
DECLARE
  users_id_type TEXT;
BEGIN
  SELECT format_type(a.atttypid, a.atttypmod) INTO users_id_type
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'
     AND c.relname = 'users'
     AND a.attname = 'id'
     AND a.attnum > 0
     AND NOT a.attisdropped;

  IF users_id_type IS NULL THEN
    RAISE EXCEPTION 'public.users(id) not found: auth_audit_events.user_id has no type to follow';
  END IF;

  EXECUTE format($ddl$
    CREATE TABLE IF NOT EXISTS auth_audit_events (
      id BIGSERIAL PRIMARY KEY,
      event_type VARCHAR(64) NOT NULL,
      user_id %1$s NULL REFERENCES users(id) ON DELETE SET NULL,
      email VARCHAR(255),
      ip_address VARCHAR(255),
      user_agent VARCHAR(1024),
      details JSONB NOT NULL DEFAULT '{}'::jsonb,
      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  $ddl$, users_id_type);
END;
$$;

CREATE INDEX IF NOT EXISTS auth_audit_events_event_created_idx ON auth_audit_events (event_type, created_at DESC);
CREATE INDEX IF NOT EXISTS auth_audit_events_email_created_idx ON auth_audit_events (lower(email), created_at DESC);

ALTER TABLE auth_audit_events DROP CONSTRAINT IF EXISTS auth_audit_events_event_type_check;
-- The auth gateway (apps/opposite-osiris) is the only writer of these events and this list is the
-- only copy of what it may write: auth_record_audit_event keeps none. The test guarding it against
-- the gateway source is scripts/tests/auth-audit-event-types.bats. Keep one name and one comma per
-- line: a missing comma concatenates two names into one string constant, with no syntax error.
ALTER TABLE auth_audit_events ADD CONSTRAINT auth_audit_events_event_type_check CHECK (event_type IN (
    'account_created_email_failed',
    'account_created_email_sent',
    'account_exists_email_sent',
    'account_mail_throttled',
    'auth_link_refused',
    'email_verification_sent',
    'email_verified',
    'ip_shift_detected',
    'login_alert_failed',
    'login_alert_sent',
    'login_alert_skipped',
    'login_alert_suppressed',
    'login_approve_approved',
    'login_approve_capped',
    'login_approve_denied',
    'login_approve_mismatch',
    'login_approve_released',
    'login_approve_requested',
    'login_approve_send_failed',
    'login_email_unconfirmed',
    'login_failed',
    'login_locked',
    'login_lockout_triggered',
    'login_otp_expired',
    'login_otp_failed',
    'login_otp_locked',
    'login_otp_request_failed',
    'login_otp_requested',
    'login_otp_verified',
    'login_success',
    'login_turnstile_failed',
    'logout',
    'mail_job_failed',
    'mail_queue_overflow',
    'mail_suppressed_exempt',
    'mfa_totp_enroll_started',
    'mfa_totp_verified',
    'newsletter_confirmation_email_failed',
    'newsletter_confirmation_email_sent',
    'newsletter_optin_requested',
    'newsletter_target_throttled',
    'newsletter_turnstile_failed',
    'newsletter_unsubscribe_email_failed',
    'newsletter_unsubscribe_email_sent',
    'newsletter_welcome_email_failed',
    'newsletter_welcome_email_sent',
    'oauth_account_linked',
    'oauth_exchange_failed',
    'oauth_link_refused',
    'oauth_link_reset_failed',
    'oauth_session_logout_failed',
    'osionos_bridge_failed',
    'osionos_bridge_redirect_rejected',
    'osionos_bridge_refused',
    'osionos_bridge_refused_logout_failed',
    'osionos_bridge_success',
    'password_changed',
    'password_changed_email_sent',
    'password_recovery_email_sent',
    'password_recovery_link_failed',
    'password_recovery_requested',
    'password_reset_completed',
    'password_reset_cutoff_failed',
    'password_reset_logout_failed',
    'password_reset_marker_failed',
    'recover_turnstile_failed',
    'refresh_failed',
    'refresh_success',
    'register_dev_confirmed',
    'register_dev_failed',
    'register_failed',
    'register_profile_failed',
    'register_requested',
    'register_turnstile_failed',
    'resend_turnstile_failed',
    'signup_refused_allowlist',
    'signup_refused_exempt',
    'verification_resend_link_failed',
    'webauthn_challenge_started'
  ));

COMMENT ON TABLE auth_audit_events IS 'security_monitoring: sensitive authentication events, failed logins, password recovery, token refreshes, MFA hooks and IP shifts; retain for 13 months unless a documented legal hold applies.';

CREATE OR REPLACE FUNCTION auth_record_audit_event(event_type TEXT, email TEXT DEFAULT NULL, details JSONB DEFAULT '{}'::jsonb)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  normalized_email TEXT;
  matched_user_id users.id%TYPE;
  event_id BIGINT;
  violated_constraint TEXT;
BEGIN
  normalized_email := lower(NULLIF(trim(email), ''));

  SELECT id INTO matched_user_id FROM users WHERE lower(users.email) = normalized_email LIMIT 1;

  BEGIN
    INSERT INTO auth_audit_events (event_type, user_id, email, ip_address, user_agent, details)
    VALUES (
      event_type,
      matched_user_id,
      normalized_email,
      COALESCE(current_setting('request.header.x-forwarded-for', true), current_setting('request.header.x-real-ip', true)),
      current_setting('request.header.user-agent', true),
      COALESCE(details, '{}'::jsonb)
    )
    RETURNING id INTO event_id;
  EXCEPTION WHEN check_violation THEN
    GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
    IF violated_constraint = 'auth_audit_events_event_type_check' THEN
      RAISE EXCEPTION 'Unsupported audit event type' USING ERRCODE = '22023';
    END IF;
    RAISE;
  END;

  RETURN jsonb_build_object('status', 'recorded', 'event_id', event_id);
END;
$$;

ALTER TABLE auth_audit_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS auth_audit_events_no_public_access ON auth_audit_events;
CREATE POLICY auth_audit_events_no_public_access ON auth_audit_events FOR SELECT TO authenticated USING (false);

REVOKE ALL ON auth_audit_events FROM anon, authenticated;
GRANT INSERT, SELECT ON auth_audit_events TO service_role;
GRANT USAGE, SELECT ON SEQUENCE auth_audit_events_id_seq TO service_role;
REVOKE EXECUTE ON FUNCTION auth_record_audit_event(TEXT, TEXT, JSONB) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION auth_record_audit_event(TEXT, TEXT, JSONB) TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
