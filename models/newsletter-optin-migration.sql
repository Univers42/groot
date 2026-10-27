-- public.newsletter_optins and the three newsletter RPCs, uuid-native, on grobase's postgres.
-- The auth-gateway calls them over Kong /rest/v1/rpc with the service key
-- (apps/opposite-osiris/scripts/auth-gateway.mjs serviceRpc()):
--   gdpr_request_newsletter_optin(email, token)  POST /api/newsletter/subscribe
--   gdpr_confirm_newsletter_optin(token)         POST /api/newsletter/confirm
--   gdpr_withdraw_consent(consent_type, token)   POST /api/newsletter/unsubscribe
--
-- Why a second file next to gdpr-migration.sql: that one is skipped by
-- scripts/apply-models-migrations.sh (its users.id is INTEGER, grobase's is uuid), so these
-- functions never existed here and every newsletter call answered 404 "Could not find the
-- function ... in the schema cache" (measured on b2b 2026-10-27). This file carries the newsletter
-- double opt-in only; the opt-in row is the consent evidence (requested_at, confirmed_at,
-- version, ip/user agent), there is no user_consents or gdpr_requests table here.
--
-- Differences from gdpr-migration.sql, on purpose:
--   * EXECUTE is granted to service_role only. The anon grant let anyone call request with a
--     token of their choosing for someone else's address and then confirm it themselves:
--     a double opt-in that proves nothing about the mailbox.
--   * The token is required; the server never invents one it cannot mail.
--   * The hash uses core sha256(), no pgcrypto dependency.
--
-- Skips itself (a NOTICE, exit 0) unless public.users.id is uuid and public.user_consents is
-- absent: on the auth-gateway's integer-users database gdpr-migration.sql owns these names, and
-- replacing its functions there would drop their user_consents writes. The guard is psql
-- \gset/\if, so every statement below sits inside the guarded branch.
--
-- Retention: each request purges pending rows expired over 30 days and unsubscribed rows over
-- 30 days. Caveat: there is no scheduler, so the purge runs only when someone subscribes;
-- with no new subscription, stale rows outlive the 30 days.
--
-- Runner position: plain alphabetical order; depends only on public.users (grobase
-- 001_initial_schema.sql). Idempotent.
--
-- DOWN (manual): DROP FUNCTION public.gdpr_withdraw_consent(TEXT, TEXT);
--                DROP FUNCTION public.gdpr_confirm_newsletter_optin(TEXT);
--                DROP FUNCTION public.gdpr_request_newsletter_optin(TEXT, TEXT);
--                DROP TABLE public.newsletter_optins;

SELECT COALESCE(to_regclass('public.user_consents') IS NULL
         AND (SELECT atttypid = 'uuid'::regtype FROM pg_attribute
               WHERE attrelid = to_regclass('public.users') AND attname = 'id'), false) AS newsletter_uuid_target \gset

\if :newsletter_uuid_target
BEGIN;

CREATE TABLE IF NOT EXISTS public.newsletter_optins (
  id BIGSERIAL PRIMARY KEY,
  email VARCHAR(255) NOT NULL,
  user_id uuid NULL REFERENCES public.users(id) ON DELETE SET NULL,
  token_hash VARCHAR(128) NOT NULL UNIQUE,
  status VARCHAR(32) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'unsubscribed')),
  version VARCHAR(32) NOT NULL DEFAULT '1.0.0',
  requested_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at TIMESTAMP NOT NULL DEFAULT (CURRENT_TIMESTAMP + INTERVAL '24 hours'),
  confirmed_at TIMESTAMP NULL,
  unsubscribed_at TIMESTAMP NULL,
  ip_at_request VARCHAR(255),
  user_agent_at_request VARCHAR(1024)
);

CREATE INDEX IF NOT EXISTS newsletter_optins_email_idx ON public.newsletter_optins (lower(email));
CREATE INDEX IF NOT EXISTS newsletter_optins_user_id_idx ON public.newsletter_optins (user_id);

COMMENT ON TABLE public.newsletter_optins IS 'data_retention_policy: newsletter double opt-in tokens are retained until confirmation/expiry and purged within 30 days; a confirmed row is the consent evidence and is kept until unsubscribe.';

ALTER TABLE public.newsletter_optins ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.newsletter_optins FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.newsletter_optins_id_seq FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.newsletter_optins TO service_role;
GRANT ALL ON SEQUENCE public.newsletter_optins_id_seq TO service_role;

-- Parameter names are the RPC contract (PostgREST binds the JSON keys to them).
CREATE OR REPLACE FUNCTION public.gdpr_request_newsletter_optin(email TEXT, token TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  normalized_email TEXT;
  matched_user_id public.newsletter_optins.user_id%TYPE;
BEGIN
  normalized_email := lower(trim(email));
  IF normalized_email !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' THEN
    RAISE EXCEPTION 'Invalid email' USING ERRCODE = '22023';
  END IF;
  IF length(COALESCE(token, '')) < 32 THEN
    RAISE EXCEPTION 'A confirmation token is required' USING ERRCODE = '22023';
  END IF;

  DELETE FROM public.newsletter_optins
   WHERE (status = 'pending' AND expires_at < CURRENT_TIMESTAMP - INTERVAL '30 days')
      OR (status = 'unsubscribed' AND unsubscribed_at < CURRENT_TIMESTAMP - INTERVAL '30 days');

  SELECT id INTO matched_user_id FROM public.users WHERE lower(users.email) = normalized_email LIMIT 1;

  INSERT INTO public.newsletter_optins (email, user_id, token_hash, ip_at_request, user_agent_at_request)
  VALUES (
    normalized_email,
    matched_user_id,
    encode(sha256(convert_to(token, 'UTF8')), 'hex'),
    COALESCE(current_setting('request.header.x-forwarded-for', true), current_setting('request.header.x-real-ip', true)),
    current_setting('request.header.user-agent', true)
  )
  ON CONFLICT (token_hash) DO NOTHING;

  RETURN jsonb_build_object('status', 'pending_confirmation', 'message', 'If the address is eligible, a confirmation email will be sent.');
END;
$$;

CREATE OR REPLACE FUNCTION public.gdpr_confirm_newsletter_optin(token TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  optin public.newsletter_optins%ROWTYPE;
BEGIN
  IF length(COALESCE(token, '')) < 32 THEN
    RAISE EXCEPTION 'Invalid or expired newsletter token' USING ERRCODE = '28000';
  END IF;

  UPDATE public.newsletter_optins
     SET status = 'confirmed', confirmed_at = CURRENT_TIMESTAMP
   WHERE token_hash = encode(sha256(convert_to(token, 'UTF8')), 'hex')
     AND status = 'pending'
     AND expires_at > CURRENT_TIMESTAMP
  RETURNING * INTO optin;

  IF optin.id IS NULL THEN
    RAISE EXCEPTION 'Invalid or expired newsletter token' USING ERRCODE = '28000';
  END IF;

  RETURN jsonb_build_object('status', 'confirmed', 'email', optin.email, 'consent_type', 'newsletter', 'policy_version', optin.version);
END;
$$;

CREATE OR REPLACE FUNCTION public.gdpr_withdraw_consent(consent_type TEXT, token TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  optin public.newsletter_optins%ROWTYPE;
BEGIN
  IF lower(COALESCE(consent_type, '')) <> 'newsletter' THEN
    RAISE EXCEPTION 'Only newsletter consent can be withdrawn here' USING ERRCODE = '22023';
  END IF;
  IF length(COALESCE(token, '')) < 32 THEN
    RAISE EXCEPTION 'Invalid newsletter token' USING ERRCODE = '28000';
  END IF;

  UPDATE public.newsletter_optins
     SET status = 'unsubscribed', unsubscribed_at = CURRENT_TIMESTAMP
   WHERE token_hash = encode(sha256(convert_to(token, 'UTF8')), 'hex')
     AND status IN ('pending', 'confirmed')
  RETURNING * INTO optin;

  IF optin.id IS NULL THEN
    RAISE EXCEPTION 'Invalid newsletter token' USING ERRCODE = '28000';
  END IF;

  RETURN jsonb_build_object('status', 'updated', 'email', optin.email, 'consent_type', 'newsletter', 'granted', false, 'withdrawn_at', optin.unsubscribed_at);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.gdpr_request_newsletter_optin(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.gdpr_confirm_newsletter_optin(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.gdpr_withdraw_consent(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gdpr_request_newsletter_optin(TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.gdpr_confirm_newsletter_optin(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.gdpr_withdraw_consent(TEXT, TEXT) TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';
\else
DO $$ BEGIN RAISE NOTICE 'newsletter-optin-migration.sql skipped: public.users.id is not uuid or public.user_consents exists (gdpr-migration.sql owns the newsletter functions here)'; END $$;
\endif
