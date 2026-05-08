-- GDPR migration for track-binocle / Prismatica
-- Policy version: 1.0.0
-- Last updated: 2026-05-03

BEGIN;

SET LOCAL search_path = public;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION gdpr_policy_version()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT '1.0.0'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_consent_type_terms()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'terms'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_consent_type_newsletter()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'newsletter'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_consent_type_analytics()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'analytics'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_consent_type_marketing()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'marketing'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_allowed_consent_types()
RETURNS TEXT[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT ARRAY[
    gdpr_consent_type_terms(),
    gdpr_consent_type_newsletter(),
    gdpr_consent_type_analytics(),
    gdpr_consent_type_marketing()
  ]::TEXT[]
$$;

CREATE OR REPLACE FUNCTION gdpr_request_type_access()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'access'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_request_type_deletion()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'deletion'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_request_type_rectification()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'rectification'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_request_type_portability()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'portability'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_request_type_restriction()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'restriction'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_request_type_objection()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'objection'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_request_type_consent_withdrawal()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'consent_withdrawal'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_request_type_newsletter()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT gdpr_consent_type_newsletter()
$$;

CREATE OR REPLACE FUNCTION gdpr_allowed_request_types()
RETURNS TEXT[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT ARRAY[
    gdpr_request_type_access(),
    gdpr_request_type_deletion(),
    gdpr_request_type_rectification(),
    gdpr_request_type_portability(),
    gdpr_request_type_restriction(),
    gdpr_request_type_objection(),
    gdpr_request_type_consent_withdrawal(),
    gdpr_request_type_newsletter()
  ]::TEXT[]
$$;

CREATE OR REPLACE FUNCTION gdpr_request_status_received()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'received'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_status_pending()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'pending'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_status_confirmed()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'confirmed'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_status_unsubscribed()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'unsubscribed'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_status_expired()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'expired'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_status_updated()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'updated'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_newsletter_statuses()
RETURNS TEXT[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT ARRAY[
    gdpr_status_pending(),
    gdpr_status_confirmed(),
    gdpr_status_unsubscribed(),
    gdpr_status_expired()
  ]::TEXT[]
$$;

CREATE OR REPLACE FUNCTION gdpr_response_deadline()
RETURNS INTERVAL
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT INTERVAL '30 days'
$$;

CREATE OR REPLACE FUNCTION gdpr_sqlstate_invalid_authorization()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT '28000'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_sqlstate_invalid_parameter()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT '22023'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_json_key_status()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'status'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_json_key_user_id()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'user_id'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_json_key_policy_version()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'policy_version'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_json_key_source()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'source'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_json_key_consent_type()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'consent_type'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_json_key_granted()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'granted'::TEXT
$$;

CREATE OR REPLACE FUNCTION gdpr_json_key_withdrawn_at()
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 'withdrawn_at'::TEXT
$$;

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS deletion_requested_at TIMESTAMP NULL,
  ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP NULL;

CREATE TABLE IF NOT EXISTS user_consents (
  id SERIAL PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  consent_type VARCHAR(32) NOT NULL CHECK (consent_type = ANY (gdpr_allowed_consent_types())),
  granted BOOLEAN NOT NULL DEFAULT FALSE,
  granted_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  withdrawn_at TIMESTAMP NULL,
  ip_at_consent VARCHAR(255),
  user_agent_at_consent VARCHAR(1024),
  version VARCHAR(32) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (user_id, consent_type, version)
);

CREATE TABLE IF NOT EXISTS gdpr_requests (
  id SERIAL PRIMARY KEY,
  user_id INTEGER NULL REFERENCES users(id) ON DELETE SET NULL,
  email VARCHAR(255),
  request_type VARCHAR(32) NOT NULL CHECK (request_type = ANY (gdpr_allowed_request_types())),
  status VARCHAR(32) NOT NULL DEFAULT gdpr_request_status_received(),
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  requested_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  due_at TIMESTAMP NOT NULL DEFAULT (CURRENT_TIMESTAMP + gdpr_response_deadline()),
  completed_at TIMESTAMP NULL
);

CREATE TABLE IF NOT EXISTS newsletter_optins (
  id SERIAL PRIMARY KEY,
  email VARCHAR(255) NOT NULL,
  user_id INTEGER NULL REFERENCES users(id) ON DELETE SET NULL,
  token_hash VARCHAR(128) NOT NULL UNIQUE,
  status VARCHAR(32) NOT NULL DEFAULT gdpr_status_pending() CHECK (status = ANY (gdpr_newsletter_statuses())),
  version VARCHAR(32) NOT NULL DEFAULT gdpr_policy_version(),
  requested_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at TIMESTAMP NOT NULL DEFAULT (CURRENT_TIMESTAMP + INTERVAL '24 hours'),
  confirmed_at TIMESTAMP NULL,
  unsubscribed_at TIMESTAMP NULL,
  ip_at_request VARCHAR(255),
  user_agent_at_request VARCHAR(1024)
);

CREATE INDEX IF NOT EXISTS newsletter_optins_email_idx ON newsletter_optins (lower(email));

COMMENT ON TABLE users IS 'data_retention_policy: account data is retained for the account lifetime; personal fields are anonymised within 30 days after verified erasure request unless a legal hold applies.';
COMMENT ON TABLE user_tokens IS 'data_retention_policy: verification and reset tokens are retained until expiry and then purged, normally within 24 hours to 7 days and never more than 30 days.';
COMMENT ON TABLE sessions IS 'data_retention_policy: session records are retained until expiry and a short operational window, normally no more than 7 days after expiry.';
COMMENT ON TABLE user_activities IS 'data_retention_policy: security and activity logs, including IP addresses and device strings, must be purged or anonymised after 13 months per CNIL log-retention guidance unless a documented legal hold applies.';
COMMENT ON TABLE user_consents IS 'data_retention_policy: consent evidence is retained for the account lifetime and normally 5 years after withdrawal or closure to prove compliance.';
COMMENT ON TABLE gdpr_requests IS 'data_retention_policy: data subject request records are retained for 5 years after closure for accountability and dispute evidence.';
COMMENT ON TABLE newsletter_optins IS 'data_retention_policy: newsletter double opt-in tokens are retained until confirmation/expiry and purged within 30 days; confirmed consent evidence is retained in user_consents where applicable.';

CREATE OR REPLACE FUNCTION gdpr_claims()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  raw_claims TEXT;
BEGIN
  raw_claims := current_setting('request.jwt.claims', true);
  IF raw_claims IS NULL OR raw_claims = '' THEN
    RETURN '{}'::jsonb;
  END IF;
  RETURN raw_claims::jsonb;
EXCEPTION WHEN others THEN
  RETURN '{}'::jsonb;
END;
$$;

CREATE OR REPLACE FUNCTION gdpr_current_email()
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(COALESCE(current_setting('request.jwt.claim.email', true), gdpr_claims() ->> 'email'), '')
$$;

CREATE OR REPLACE FUNCTION gdpr_current_role()
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(COALESCE(current_setting('request.jwt.claim.role', true), gdpr_claims() ->> 'role'), '')
$$;

CREATE OR REPLACE FUNCTION gdpr_current_user_id()
RETURNS INTEGER
LANGUAGE sql
STABLE
AS $$
  SELECT id FROM users WHERE email = gdpr_current_email() AND deleted_at IS NULL LIMIT 1
$$;

CREATE OR REPLACE FUNCTION gdpr_require_authenticated_user()
RETURNS INTEGER
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  current_user_id INTEGER;
BEGIN
  IF COALESCE(gdpr_current_role(), '') <> 'authenticated' THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = gdpr_sqlstate_invalid_authorization();
  END IF;

  current_user_id := gdpr_current_user_id();
  IF current_user_id IS NULL THEN
    RAISE EXCEPTION 'Authenticated user is not mapped to a local profile' USING ERRCODE = gdpr_sqlstate_invalid_authorization();
  END IF;

  RETURN current_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION gdpr_hash_token(raw_token TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT encode(digest(COALESCE(raw_token, ''), 'sha256'), 'hex')
$$;

CREATE OR REPLACE FUNCTION anonymise_user(target_user_id INT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  affected INTEGER;
BEGIN
  UPDATE users
  SET
    email = 'anonymised_' || id || '@deleted.invalid',
    username = 'deleted_' || id,
    password_hash = 'deleted',
    first_name = NULL,
    last_name = NULL,
    avatar_url = NULL,
    bio = NULL,
    notifications_enabled = FALSE,
    deleted_at = COALESCE(deleted_at, CURRENT_TIMESTAMP),
    updated_at = CURRENT_TIMESTAMP
  WHERE id = target_user_id;

  GET DIAGNOSTICS affected = ROW_COUNT;

  UPDATE user_activities
  SET activity_data = COALESCE(activity_data, '{}'::jsonb)
    - 'ip'
    - 'device'
    - 'location'
    - 'user_agent'
    - 'browser'
    - 'os'
    || jsonb_build_object('anonymised', true)
  WHERE user_id = target_user_id;

  DELETE FROM sessions WHERE user_id = target_user_id;
  DELETE FROM user_tokens WHERE user_id = target_user_id;

  RETURN jsonb_build_object(gdpr_json_key_user_id(), target_user_id, 'anonymised', affected = 1, 'anonymised_at', CURRENT_TIMESTAMP);
END;
$$;

CREATE OR REPLACE FUNCTION public.gdpr_export_my_data()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  current_user_id INTEGER;
  response JSONB;
BEGIN
  current_user_id := gdpr_require_authenticated_user();

  SELECT jsonb_build_object(
    gdpr_json_key_policy_version(), gdpr_policy_version(),
    'generated_at', CURRENT_TIMESTAMP,
    'data_subject', jsonb_build_object(gdpr_json_key_user_id(), u.id, 'email', u.email),
    'users', to_jsonb(u) - 'password_hash',
    'user_tokens', COALESCE((SELECT jsonb_agg(to_jsonb(t) - 'token') FROM user_tokens t WHERE t.user_id = current_user_id), '[]'::jsonb),
    'sessions', COALESCE((SELECT jsonb_agg(to_jsonb(s) - 'session_token') FROM sessions s WHERE s.user_id = current_user_id), '[]'::jsonb),
    'user_activities', COALESCE((SELECT jsonb_agg(to_jsonb(a)) FROM user_activities a WHERE a.user_id = current_user_id), '[]'::jsonb),
    'user_consents', COALESCE((SELECT jsonb_agg(to_jsonb(c)) FROM user_consents c WHERE c.user_id = current_user_id), '[]'::jsonb),
    'format', 'machine-readable JSON; CSV export planned for a future iteration'
  ) INTO response
  FROM users u
  WHERE u.id = current_user_id;

  RETURN response;
END;
$$;

CREATE OR REPLACE FUNCTION gdpr_request_deletion()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  current_user_id INTEGER;
  expected_deletion_at TIMESTAMP;
BEGIN
  current_user_id := gdpr_require_authenticated_user();
  expected_deletion_at := CURRENT_TIMESTAMP + gdpr_response_deadline();

  UPDATE users
  SET deletion_requested_at = CURRENT_TIMESTAMP,
      updated_at = CURRENT_TIMESTAMP
  WHERE id = current_user_id;

  INSERT INTO gdpr_requests (user_id, email, request_type, details, due_at)
  SELECT current_user_id, email, gdpr_request_type_deletion(), jsonb_build_object(gdpr_json_key_source(), 'rpc', gdpr_json_key_policy_version(), gdpr_policy_version()), expected_deletion_at
  FROM users WHERE id = current_user_id;

  RETURN jsonb_build_object(
    gdpr_json_key_status(), gdpr_request_status_received(),
    'request_type', gdpr_request_type_deletion(),
    gdpr_json_key_user_id(), current_user_id,
    'expected_deletion_at', expected_deletion_at,
    'message', 'Deletion request recorded. Soft deletion is the first step; hard deletion or anonymisation follows after the retention window unless a legal hold applies.'
  );
END;
$$;

CREATE OR REPLACE FUNCTION gdpr_withdraw_consent(consent_type TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  current_user_id INTEGER;
  normalized_type TEXT;
BEGIN
  current_user_id := gdpr_require_authenticated_user();
  normalized_type := lower(consent_type);

  IF normalized_type <> ALL (gdpr_allowed_consent_types()) THEN
    RAISE EXCEPTION 'Unsupported consent_type' USING ERRCODE = gdpr_sqlstate_invalid_parameter();
  END IF;

  UPDATE user_consents
  SET granted = FALSE,
      withdrawn_at = CURRENT_TIMESTAMP,
      updated_at = CURRENT_TIMESTAMP
  WHERE user_id = current_user_id
    AND user_consents.consent_type = normalized_type
    AND withdrawn_at IS NULL;

  INSERT INTO gdpr_requests (user_id, email, request_type, details)
  SELECT current_user_id, email, gdpr_request_type_consent_withdrawal(), jsonb_build_object(gdpr_json_key_consent_type(), normalized_type, gdpr_json_key_policy_version(), gdpr_policy_version())
  FROM users WHERE id = current_user_id;

  RETURN jsonb_build_object(gdpr_json_key_status(), gdpr_status_updated(), gdpr_json_key_consent_type(), normalized_type, gdpr_json_key_granted(), false, gdpr_json_key_withdrawn_at(), CURRENT_TIMESTAMP);
END;
$$;

CREATE OR REPLACE FUNCTION gdpr_set_newsletter(granted BOOLEAN)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  current_user_id INTEGER;
  policy_version CONSTANT TEXT := gdpr_policy_version();
BEGIN
  current_user_id := gdpr_require_authenticated_user();

  INSERT INTO user_consents (user_id, consent_type, granted, granted_at, withdrawn_at, ip_at_consent, user_agent_at_consent, version)
  VALUES (
    current_user_id,
    gdpr_consent_type_newsletter(),
    granted,
    CURRENT_TIMESTAMP,
    CASE WHEN granted THEN NULL ELSE CURRENT_TIMESTAMP END,
    COALESCE(current_setting('request.header.x-forwarded-for', true), current_setting('request.header.x-real-ip', true)),
    current_setting('request.header.user-agent', true),
    policy_version
  )
  ON CONFLICT (user_id, consent_type, version)
  DO UPDATE SET
    granted = EXCLUDED.granted,
    granted_at = CASE WHEN EXCLUDED.granted THEN CURRENT_TIMESTAMP ELSE user_consents.granted_at END,
    withdrawn_at = CASE WHEN EXCLUDED.granted THEN NULL ELSE CURRENT_TIMESTAMP END,
    ip_at_consent = EXCLUDED.ip_at_consent,
    user_agent_at_consent = EXCLUDED.user_agent_at_consent,
    updated_at = CURRENT_TIMESTAMP;

  INSERT INTO gdpr_requests (user_id, email, request_type, details)
  SELECT current_user_id, email, gdpr_request_type_newsletter(), jsonb_build_object(gdpr_json_key_granted(), granted, gdpr_json_key_policy_version(), policy_version)
  FROM users WHERE id = current_user_id;

  RETURN jsonb_build_object(gdpr_json_key_status(), gdpr_status_updated(), gdpr_json_key_consent_type(), gdpr_consent_type_newsletter(), gdpr_json_key_granted(), granted, gdpr_json_key_policy_version(), policy_version);
END;
$$;

CREATE OR REPLACE FUNCTION gdpr_request_newsletter_optin(email TEXT, token TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  normalized_email TEXT;
  raw_token TEXT;
  matched_user_id INTEGER;
BEGIN
  normalized_email := lower(trim(email));
  IF normalized_email !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' THEN
    RAISE EXCEPTION 'Invalid email' USING ERRCODE = gdpr_sqlstate_invalid_parameter();
  END IF;

  raw_token := COALESCE(NULLIF(token, ''), encode(gen_random_bytes(32), 'hex'));
  SELECT id INTO matched_user_id FROM users WHERE lower(users.email) = normalized_email AND deleted_at IS NULL LIMIT 1;

  INSERT INTO newsletter_optins (email, user_id, token_hash, status, version, ip_at_request, user_agent_at_request)
  VALUES (
    normalized_email,
    matched_user_id,
    gdpr_hash_token(raw_token),
    gdpr_status_pending(),
    gdpr_policy_version(),
    COALESCE(current_setting('request.header.x-forwarded-for', true), current_setting('request.header.x-real-ip', true)),
    current_setting('request.header.user-agent', true)
  )
  ON CONFLICT (token_hash) DO NOTHING;

  INSERT INTO gdpr_requests (user_id, email, request_type, details)
  VALUES (matched_user_id, normalized_email, gdpr_request_type_newsletter(), jsonb_build_object('stage', 'double_opt_in_requested', gdpr_json_key_policy_version(), gdpr_policy_version()));

  RETURN jsonb_build_object(gdpr_json_key_status(), 'pending_confirmation', 'message', 'If the address is eligible, a confirmation email will be sent.');
END;
$$;

CREATE OR REPLACE FUNCTION gdpr_confirm_newsletter_optin(token TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  optin RECORD;
  policy_version CONSTANT TEXT := gdpr_policy_version();
BEGIN
  SELECT * INTO optin
  FROM newsletter_optins
  WHERE token_hash = gdpr_hash_token(token)
    AND status = gdpr_status_pending()
    AND expires_at > CURRENT_TIMESTAMP
  ORDER BY requested_at DESC
  LIMIT 1;

  IF optin.id IS NULL THEN
    RAISE EXCEPTION 'Invalid or expired newsletter token' USING ERRCODE = gdpr_sqlstate_invalid_authorization();
  END IF;

  UPDATE newsletter_optins
  SET status = gdpr_status_confirmed(), confirmed_at = CURRENT_TIMESTAMP
  WHERE id = optin.id;

  IF optin.user_id IS NOT NULL THEN
    INSERT INTO user_consents (user_id, consent_type, granted, granted_at, withdrawn_at, ip_at_consent, user_agent_at_consent, version)
    VALUES (optin.user_id, gdpr_consent_type_newsletter(), TRUE, CURRENT_TIMESTAMP, NULL, optin.ip_at_request, optin.user_agent_at_request, policy_version)
    ON CONFLICT (user_id, consent_type, version)
    DO UPDATE SET
      granted = TRUE,
      granted_at = CURRENT_TIMESTAMP,
      withdrawn_at = NULL,
      ip_at_consent = EXCLUDED.ip_at_consent,
      user_agent_at_consent = EXCLUDED.user_agent_at_consent,
      updated_at = CURRENT_TIMESTAMP;
  END IF;

  INSERT INTO gdpr_requests (user_id, email, request_type, details)
  VALUES (optin.user_id, optin.email, gdpr_request_type_newsletter(), jsonb_build_object('stage', 'double_opt_in_confirmed', gdpr_json_key_policy_version(), policy_version));

  RETURN jsonb_build_object(gdpr_json_key_status(), gdpr_status_confirmed(), 'email', optin.email, gdpr_json_key_consent_type(), gdpr_consent_type_newsletter(), gdpr_json_key_policy_version(), policy_version);
END;
$$;

DROP FUNCTION IF EXISTS gdpr_withdraw_consent(TEXT);

CREATE OR REPLACE FUNCTION gdpr_withdraw_consent(consent_type TEXT, token TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  current_user_id INTEGER;
  normalized_type TEXT;
  optin RECORD;
BEGIN
  normalized_type := lower(consent_type);

  IF normalized_type <> ALL (gdpr_allowed_consent_types()) THEN
    RAISE EXCEPTION 'Unsupported consent_type' USING ERRCODE = gdpr_sqlstate_invalid_parameter();
  END IF;

  IF token IS NOT NULL AND token <> '' THEN
    IF normalized_type <> gdpr_consent_type_newsletter() THEN
      RAISE EXCEPTION 'Token withdrawal is only supported for newsletter consent' USING ERRCODE = gdpr_sqlstate_invalid_parameter();
    END IF;

    SELECT * INTO optin
    FROM newsletter_optins
    WHERE token_hash = gdpr_hash_token(token)
      AND status = ANY (ARRAY[gdpr_status_pending(), gdpr_status_confirmed()])
    ORDER BY requested_at DESC
    LIMIT 1;

    IF optin.id IS NULL THEN
      RAISE EXCEPTION 'Invalid newsletter token' USING ERRCODE = gdpr_sqlstate_invalid_authorization();
    END IF;

    UPDATE newsletter_optins
    SET status = gdpr_status_unsubscribed(), unsubscribed_at = CURRENT_TIMESTAMP
    WHERE id = optin.id;

    IF optin.user_id IS NOT NULL THEN
      UPDATE user_consents
      SET granted = FALSE,
          withdrawn_at = CURRENT_TIMESTAMP,
          updated_at = CURRENT_TIMESTAMP
      WHERE user_id = optin.user_id
        AND user_consents.consent_type = gdpr_consent_type_newsletter();
    END IF;

    INSERT INTO gdpr_requests (user_id, email, request_type, details)
    VALUES (optin.user_id, optin.email, gdpr_request_type_consent_withdrawal(), jsonb_build_object(gdpr_json_key_consent_type(), normalized_type, gdpr_json_key_source(), 'newsletter_token', gdpr_json_key_policy_version(), gdpr_policy_version()));

    RETURN jsonb_build_object(gdpr_json_key_status(), gdpr_status_updated(), 'email', optin.email, gdpr_json_key_consent_type(), normalized_type, gdpr_json_key_granted(), false, gdpr_json_key_withdrawn_at(), CURRENT_TIMESTAMP);
  END IF;

  current_user_id := gdpr_require_authenticated_user();

  UPDATE user_consents
  SET granted = FALSE,
      withdrawn_at = CURRENT_TIMESTAMP,
      updated_at = CURRENT_TIMESTAMP
  WHERE user_id = current_user_id
    AND user_consents.consent_type = normalized_type
    AND withdrawn_at IS NULL;

  INSERT INTO gdpr_requests (user_id, email, request_type, details)
  SELECT current_user_id, email, gdpr_request_type_consent_withdrawal(), jsonb_build_object(gdpr_json_key_consent_type(), normalized_type, gdpr_json_key_policy_version(), gdpr_policy_version())
  FROM users WHERE id = current_user_id;

  RETURN jsonb_build_object(gdpr_json_key_status(), gdpr_status_updated(), gdpr_json_key_consent_type(), normalized_type, gdpr_json_key_granted(), false, gdpr_json_key_withdrawn_at(), CURRENT_TIMESTAMP);
END;
$$;

CREATE OR REPLACE FUNCTION gdpr_submit_request(request_type TEXT, email TEXT, details JSONB DEFAULT '{}'::jsonb)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  normalized_type TEXT;
  matched_user_id INTEGER;
  request_id INTEGER;
BEGIN
  normalized_type := lower(request_type);
  IF normalized_type <> ALL (ARRAY[
    gdpr_request_type_access(),
    gdpr_request_type_deletion(),
    gdpr_request_type_rectification(),
    gdpr_request_type_portability(),
    gdpr_request_type_restriction(),
    gdpr_request_type_objection()
  ]) THEN
    RAISE EXCEPTION 'Unsupported request_type' USING ERRCODE = gdpr_sqlstate_invalid_parameter();
  END IF;

  SELECT id INTO matched_user_id FROM users WHERE users.email = gdpr_submit_request.email LIMIT 1;

  INSERT INTO gdpr_requests (user_id, email, request_type, details)
  VALUES (matched_user_id, email, normalized_type, COALESCE(details, '{}'::jsonb) || jsonb_build_object(gdpr_json_key_source(), 'public_form', gdpr_json_key_policy_version(), gdpr_policy_version()))
  RETURNING id INTO request_id;

  RETURN jsonb_build_object(gdpr_json_key_status(), gdpr_request_status_received(), 'request_id', request_id, 'request_type', normalized_type, 'due_at', CURRENT_TIMESTAMP + gdpr_response_deadline());
END;
$$;

ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_consents ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_activities ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE gdpr_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE newsletter_optins ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS users_public_read ON users;
DROP POLICY IF EXISTS users_public_insert ON users;
DROP POLICY IF EXISTS users_anon_public_read ON users;
CREATE POLICY users_anon_public_read ON users FOR SELECT TO anon USING (deleted_at IS NULL);
DROP POLICY IF EXISTS users_authenticated_own_read ON users;
CREATE POLICY users_authenticated_own_read ON users FOR SELECT TO authenticated USING (id = gdpr_current_user_id());
DROP POLICY IF EXISTS users_authenticated_own_update ON users;
CREATE POLICY users_authenticated_own_update ON users FOR UPDATE TO authenticated USING (id = gdpr_current_user_id()) WITH CHECK (id = gdpr_current_user_id());

DROP POLICY IF EXISTS user_consents_own_read ON user_consents;
CREATE POLICY user_consents_own_read ON user_consents FOR SELECT TO authenticated USING (user_id = gdpr_current_user_id());
DROP POLICY IF EXISTS user_consents_own_write ON user_consents;
CREATE POLICY user_consents_own_write ON user_consents FOR ALL TO authenticated USING (user_id = gdpr_current_user_id()) WITH CHECK (user_id = gdpr_current_user_id());

DROP POLICY IF EXISTS activities_public_read ON user_activities;
DROP POLICY IF EXISTS user_activities_own_read ON user_activities;
CREATE POLICY user_activities_own_read ON user_activities FOR SELECT TO authenticated USING (user_id = gdpr_current_user_id());

DROP POLICY IF EXISTS sessions_own_read ON sessions;
CREATE POLICY sessions_own_read ON sessions FOR SELECT TO authenticated USING (user_id = gdpr_current_user_id());

DROP POLICY IF EXISTS user_tokens_own_read ON user_tokens;
CREATE POLICY user_tokens_own_read ON user_tokens FOR SELECT TO authenticated USING (user_id = gdpr_current_user_id());

DROP POLICY IF EXISTS gdpr_requests_own_read ON gdpr_requests;
CREATE POLICY gdpr_requests_own_read ON gdpr_requests FOR SELECT TO authenticated USING (user_id = gdpr_current_user_id());

REVOKE ALL ON users FROM anon, authenticated;
GRANT SELECT (id, username, email, avatar_url, bio, theme, notifications_enabled, is_email_verified, created_at, updated_at) ON users TO anon;
GRANT SELECT (id, username, email, avatar_url, bio, theme, notifications_enabled, is_email_verified, created_at, updated_at, deletion_requested_at, deleted_at) ON users TO authenticated;
GRANT UPDATE (username, avatar_url, bio, theme, notifications_enabled, deletion_requested_at, updated_at) ON users TO authenticated;

REVOKE ALL ON user_consents, user_activities, sessions, user_tokens FROM anon;
REVOKE ALL ON user_consents, user_activities, sessions, user_tokens FROM authenticated;
REVOKE ALL ON newsletter_optins FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON user_consents TO authenticated;
GRANT SELECT ON user_activities, sessions, user_tokens TO authenticated;
GRANT INSERT ON gdpr_requests TO anon, authenticated;
GRANT SELECT ON gdpr_requests TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION gdpr_export_my_data() TO authenticated;
GRANT EXECUTE ON FUNCTION gdpr_request_deletion() TO authenticated;
GRANT EXECUTE ON FUNCTION gdpr_withdraw_consent(TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION gdpr_set_newsletter(BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION gdpr_request_newsletter_optin(TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION gdpr_confirm_newsletter_optin(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION gdpr_submit_request(TEXT, TEXT, JSONB) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION gdpr_hash_token(TEXT) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION anonymise_user(INT) FROM anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Scheduled operations to configure in production:
-- 1. Purge or anonymise user_activities rows older than 13 months.
-- 2. Hard-delete or anonymise users 30 days after deletion_requested_at unless legal hold applies.
-- 3. Purge expired user_tokens and sessions on a daily schedule.

COMMIT;
