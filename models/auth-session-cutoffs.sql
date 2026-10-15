-- public.auth_session_cutoffs: per user, the instant before which every session is void.
-- A password reset ends with `logout?scope=global`, which revokes GoTrue refresh tokens
-- but not the osionos_v1 tokens the bridge has already minted. The auth-gateway therefore
-- upserts this row (service_role, Kong /rest/v1, on_conflict=user_id) and the bridge
-- verifier refuses a token issued before it (verdict B C8, PLAN.md §7.1).
-- Only service_role reaches it: anon and authenticated get no grant and no policy
-- (make models-grants-verify, checks c, d, e1 and probes S1-S3).
-- It references auth.users (GoTrue) and nothing in models/, so the runner's plain
-- alphabetical order is enough; realtime-cdc-off-migration.sql (ORDERED_LAST) drops the
-- realtime trigger grobase's CREATE TABLE hook gives it. Idempotent: a replay moves no
-- grant, policy or RLS flag (check g).
-- DOWN (manual): DROP TABLE public.auth_session_cutoffs;

BEGIN;

CREATE TABLE IF NOT EXISTS public.auth_session_cutoffs (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  sessions_valid_after TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.auth_session_cutoffs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS auth_session_cutoffs_service_role_all ON public.auth_session_cutoffs;
CREATE POLICY auth_session_cutoffs_service_role_all ON public.auth_session_cutoffs
  FOR ALL TO service_role USING (true) WITH CHECK (true);

REVOKE ALL ON public.auth_session_cutoffs FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.auth_session_cutoffs TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';
