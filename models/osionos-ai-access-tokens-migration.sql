-- ai_access_tokens — personal access tokens for outside agents (G4, the remote
-- MCP endpoint). Devil verdict on (d), C112–C116 (records:
-- g-graph-diagrams-mcp-verdict.md). ai-dev only until C112–C120 are merged
-- with their tests; the public stack never routes /api/ai/mcp before that.
--
-- What this file holds and what it does not:
--   - the token is NEVER stored: only its sha256 (hex), a display prefix and
--     its last 4 characters (C112). The service mints the 256-bit secret,
--     shows it once, and hashes it before it reaches this table;
--   - a token is valid when it is not revoked, not expired, and was created
--     AFTER the user's session cutoff (C113): a password reset, a global
--     sign-out or a membership cutoff (osionos-membership-cutoff-migration.sql)
--     writes auth_session_cutoffs, and every older token stops at once;
--   - the scope is data (scopes, workspace_ids); the service intersects
--     workspace_ids with the LIVE membership in liveMemberWorkspaces (C115).
--     This file does not decide what a scope may reach;
--   - minting freshness (session iat ≤ 10 min) and "a PAT never manages PATs"
--     are the service's rules (C113, C114): the database cannot see sessions.
--
-- Caveat: the cutoff is per user, not per workspace — a membership change in
-- ONE workspace revokes the user's tokens for ALL of them. Over-revocation is
-- the safe direction; the user mints again.
-- Caveat: last_used_at is written at most once a minute per token, so it can
-- lag the true last use by up to a minute.
--
-- Ordering: auth_session_cutoffs (auth-session-cutoffs.sql) is read through
-- to_regclass + EXECUTE, so this file applies on a database without it (the AI
-- service's test harness) and the two files work in either order.
--
-- Idempotent: IF NOT EXISTS / OR REPLACE / DROP ... IF EXISTS, replayed on boot.

-- -----------------------------------------------------------------------------
-- 1. The table.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_access_tokens (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID NOT NULL,
    name          TEXT NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 64),
    token_sha256  TEXT NOT NULL UNIQUE CHECK (token_sha256 ~ '^[0-9a-f]{64}$'),
    last4         TEXT NOT NULL CHECK (last4 ~ '^[A-Za-z0-9_-]{4}$'),
    scopes        TEXT[] NOT NULL CHECK (
                      cardinality(scopes) BETWEEN 1 AND 2
                      AND scopes <@ ARRAY['read', 'write_approval']::TEXT[]),
    workspace_ids UUID[] NOT NULL CHECK (cardinality(workspace_ids) BETWEEN 1 AND 50),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at    TIMESTAMPTZ NOT NULL,
    last_used_at  TIMESTAMPTZ,
    revoked_at    TIMESTAMPTZ,
    CONSTRAINT ai_access_tokens_expiry_check
        CHECK (expires_at > created_at AND expires_at <= created_at + INTERVAL '366 days')
);

COMMENT ON TABLE public.ai_access_tokens IS
    'Personal access tokens for the remote MCP endpoint (G4, C112–C116). Stores '
    'the sha256 of the token, never the token. Valid = not revoked, not expired, '
    'created after the user''s auth_session_cutoffs row. service_role only.';

-- The settings list: a user's tokens, newest first.
CREATE INDEX IF NOT EXISTS ai_access_tokens_user_idx
    ON public.ai_access_tokens (user_id, created_at DESC);

-- -----------------------------------------------------------------------------
-- 2. Create. At most 20 live tokens per user; the advisory lock makes the count
--    and the insert one step, so two parallel mints cannot both pass at 19.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_access_token_create(
    p_user UUID,
    p_name TEXT,
    p_token_sha256 TEXT,
    p_last4 TEXT,
    p_scopes TEXT[],
    p_workspace_ids UUID[],
    p_expires_at TIMESTAMPTZ
) RETURNS UUID
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_live INTEGER;
    v_id   UUID;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended('ai_access_tokens:' || p_user::TEXT, 0));
    SELECT count(*) INTO v_live
      FROM public.ai_access_tokens t
     WHERE t.user_id = p_user
       AND t.revoked_at IS NULL
       AND t.expires_at > now();
    IF v_live >= 20 THEN
        RAISE EXCEPTION 'ai_access_token_create: at most 20 live tokens per user' USING ERRCODE = '54000';
    END IF;

    INSERT INTO public.ai_access_tokens
           (user_id, name, token_sha256, last4, scopes, workspace_ids, expires_at)
    VALUES (p_user, btrim(p_name), p_token_sha256, p_last4, p_scopes, p_workspace_ids, p_expires_at)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;

-- -----------------------------------------------------------------------------
-- 3. Resolve: the one check every PAT request runs (C116 — no cache). Returns
--    no row for an unknown, revoked, expired or cut-off token; the caller
--    answers 401 for all four alike.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_access_token_resolve(p_token_sha256 TEXT)
RETURNS TABLE (token_id UUID, user_id UUID, name TEXT, scopes TEXT[], workspace_ids UUID[])
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    t        public.ai_access_tokens%ROWTYPE;
    v_cutoff TIMESTAMPTZ;
BEGIN
    SELECT * INTO t FROM public.ai_access_tokens a WHERE a.token_sha256 = p_token_sha256;
    IF NOT FOUND OR t.revoked_at IS NOT NULL OR t.expires_at <= now() THEN
        RETURN;
    END IF;

    IF to_regclass('public.auth_session_cutoffs') IS NOT NULL THEN
        EXECUTE 'SELECT sessions_valid_after FROM public.auth_session_cutoffs WHERE user_id = $1'
           INTO v_cutoff USING t.user_id;
        IF v_cutoff IS NOT NULL AND t.created_at < v_cutoff THEN
            RETURN;
        END IF;
    END IF;

    IF t.last_used_at IS NULL OR t.last_used_at < now() - INTERVAL '1 minute' THEN
        UPDATE public.ai_access_tokens a SET last_used_at = now() WHERE a.id = t.id;
    END IF;

    RETURN QUERY SELECT t.id, t.user_id, t.name, t.scopes, t.workspace_ids;
END;
$$;

-- -----------------------------------------------------------------------------
-- 4. Revoke (owner only) and erase (C113: account erase deletes them).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_access_token_revoke(p_user UUID, p_token_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SET search_path = public, pg_temp
AS $$
    WITH revoked AS (
        UPDATE public.ai_access_tokens t
           SET revoked_at = now()
         WHERE t.id = p_token_id
           AND t.user_id = p_user
           AND t.revoked_at IS NULL
        RETURNING 1
    )
    SELECT EXISTS (SELECT 1 FROM revoked);
$$;

CREATE OR REPLACE FUNCTION public.ai_access_tokens_erase_user(p_user UUID)
RETURNS BIGINT
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    n BIGINT;
BEGIN
    DELETE FROM public.ai_access_tokens WHERE user_id = p_user;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

COMMENT ON FUNCTION public.ai_access_token_resolve(TEXT) IS
    'The PAT check (C116): no row = 401 (unknown, revoked, expired or created '
    'before the user''s session cutoff). Touches last_used_at at most once a '
    'minute. service_role only.';

-- -----------------------------------------------------------------------------
-- 5. RLS: service_role only. The catalog-wide revoke of
--    osionos-service-role-only-migration.sql matches osionos\_% only, so this
--    table closes itself, on every replay.
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_access_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_access_tokens_service_role_all ON public.ai_access_tokens;
CREATE POLICY ai_access_tokens_service_role_all ON public.ai_access_tokens
    FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_access_tokens TO service_role;
REVOKE ALL ON public.ai_access_tokens FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.ai_access_token_create(UUID, TEXT, TEXT, TEXT, TEXT[], UUID[], TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION public.ai_access_token_resolve(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.ai_access_token_revoke(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.ai_access_tokens_erase_user(UUID) TO service_role;
REVOKE ALL ON FUNCTION public.ai_access_token_create(UUID, TEXT, TEXT, TEXT, TEXT[], UUID[], TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_access_token_resolve(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_access_token_revoke(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_access_tokens_erase_user(UUID) FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
