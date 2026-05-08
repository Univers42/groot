-- Authentication security migration for track-binocle / Prismatica
-- Adds audit logging for sensitive authentication events.
-- Last updated: 2026-05-03

BEGIN;

SET LOCAL search_path = public;

CREATE TABLE IF NOT EXISTS auth_audit_events (
  id BIGSERIAL PRIMARY KEY,
  event_type VARCHAR(64) NOT NULL CHECK (event_type IN (
    'register_requested',
    'register_failed',
    'register_dev_confirmed',
    'register_dev_failed',
    'login_success',
    'login_failed',
    'login_alert_sent',
    'login_alert_failed',
    'login_alert_skipped',
    'login_turnstile_failed',
    'register_turnstile_failed',
    'recover_turnstile_failed',
    'password_recovery_requested',
    'newsletter_optin_requested',
    'password_changed',
    'refresh_success',
    'refresh_failed',
    'logout',
    'mfa_totp_enroll_started',
    'mfa_totp_verified',
    'webauthn_challenge_started',
    'ip_shift_detected'
  )),
  user_id INTEGER NULL REFERENCES users(id) ON DELETE SET NULL,
  email VARCHAR(255),
  ip_address VARCHAR(255),
  user_agent VARCHAR(1024),
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS auth_audit_events_event_created_idx ON auth_audit_events (event_type, created_at DESC);
CREATE INDEX IF NOT EXISTS auth_audit_events_email_created_idx ON auth_audit_events (lower(email), created_at DESC);

ALTER TABLE auth_audit_events DROP CONSTRAINT IF EXISTS auth_audit_events_event_type_check;
ALTER TABLE auth_audit_events ADD CONSTRAINT auth_audit_events_event_type_check CHECK (event_type IN (
    'register_requested',
    'register_failed',
    'register_dev_confirmed',
    'register_dev_failed',
    'account_created_email_sent',
    'account_created_email_failed',
    'email_verification_sent',
    'login_success',
    'login_failed',
    'login_alert_sent',
    'login_alert_failed',
    'login_alert_skipped',
    'login_alert_suppressed',
    'login_turnstile_failed',
    'register_turnstile_failed',
    'recover_turnstile_failed',
    'password_recovery_requested',
    'password_recovery_email_sent',
    'password_recovery_link_failed',
    'newsletter_optin_requested',
    'newsletter_confirmation_email_sent',
    'newsletter_confirmation_email_failed',
    'newsletter_welcome_email_sent',
    'newsletter_welcome_email_failed',
    'newsletter_unsubscribe_email_sent',
    'newsletter_unsubscribe_email_failed',
    'password_changed',
    'refresh_success',
    'refresh_failed',
    'logout',
    'mfa_totp_enroll_started',
    'mfa_totp_verified',
    'webauthn_challenge_started',
    'ip_shift_detected'
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
  matched_user_id INTEGER;
  event_id BIGINT;
BEGIN
  normalized_email := lower(NULLIF(trim(email), ''));

  IF event_type NOT IN (
    'register_requested',
    'register_failed',
    'register_dev_confirmed',
    'register_dev_failed',
    'account_created_email_sent',
    'account_created_email_failed',
    'email_verification_sent',
    'login_success',
    'login_failed',
    'login_alert_sent',
    'login_alert_failed',
    'login_alert_skipped',
    'login_alert_suppressed',
    'login_turnstile_failed',
    'register_turnstile_failed',
    'recover_turnstile_failed',
    'password_recovery_requested',
    'password_recovery_email_sent',
    'password_recovery_link_failed',
    'newsletter_optin_requested',
    'newsletter_confirmation_email_sent',
    'newsletter_confirmation_email_failed',
    'newsletter_welcome_email_sent',
    'newsletter_welcome_email_failed',
    'newsletter_unsubscribe_email_sent',
    'newsletter_unsubscribe_email_failed',
    'password_changed',
    'refresh_success',
    'refresh_failed',
    'logout',
    'mfa_totp_enroll_started',
    'mfa_totp_verified',
    'webauthn_challenge_started',
    'ip_shift_detected'
  ) THEN
    RAISE EXCEPTION 'Unsupported audit event type' USING ERRCODE = '22023';
  END IF;

  SELECT id INTO matched_user_id FROM users WHERE lower(users.email) = normalized_email LIMIT 1;

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
