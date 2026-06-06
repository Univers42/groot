-- =====================================================================
-- RLS hardening migration — track-binocle BaaS  (idempotent + portable)
-- Closes F1-F7 from wiki/security/baas-rls-audit.md (live-verified findings).
--
-- The Kong anon apikey is public by design; there is no Kong ACL plugin on
-- /rest/v1, so Postgres RLS + grants are the ONLY data wall. This migration
-- removes the leaked PUBLIC execute on destructive SECURITY DEFINER functions,
-- enables/forces RLS on the two open internal tables, strips the blanket
-- anon/authenticated CRUD grants, role-scopes tenant_databases, caps anon
-- enumeration of users, and FORCEs RLS everywhere for defense in depth.
--
-- EXISTENCE-GUARDED so it runs cleanly on BOTH the full local stack AND a LEAN
-- fresh install (objects that only exist in the heavier BaaS planes — e.g.
-- schema_registry, tenant_databases — are skipped rather than erroring).
-- Idempotent and safe to re-run on every startup. Run AFTER the base schema +
-- the inline column grants in apply-project-sql.sh so its grants are final.
-- =====================================================================
BEGIN;
SET LOCAL search_path = public;

-- ---------------------------------------------------------------------
-- F1/F2: revoke the leaked PUBLIC execute on SECURITY DEFINER functions.
-- REVOKE ... FROM anon/authenticated does NOT remove the default PUBLIC grant,
-- which is what anon actually inherited. PUBLIC-revoke every sensitive SECDEF
-- function that is present.
-- ---------------------------------------------------------------------
DO $$
DECLARE fn record;
BEGIN
  FOR fn IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN (
      'anonymise_user','auth_record_audit_event','gdpr_export_my_data',
      'gdpr_request_deletion','gdpr_set_newsletter','gdpr_withdraw_consent',
      'gdpr_submit_request','gdpr_request_newsletter_optin','gdpr_confirm_newsletter_optin')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', fn.sig);
  END LOOP;
END $$;

DO $$
BEGIN
  -- anonymise_user: destructive — callable by NO API role.
  IF to_regprocedure('public.anonymise_user(integer)') IS NOT NULL THEN
    REVOKE EXECUTE ON FUNCTION public.anonymise_user(integer) FROM anon, authenticated;
  END IF;
  -- auth_record_audit_event: service_role only (gateway calls it with the service key).
  IF to_regprocedure('public.auth_record_audit_event(text,text,jsonb)') IS NOT NULL THEN
    REVOKE EXECUTE ON FUNCTION public.auth_record_audit_event(text,text,jsonb) FROM anon, authenticated;
    GRANT  EXECUTE ON FUNCTION public.auth_record_audit_event(text,text,jsonb) TO service_role;
  END IF;
  -- gdpr_*: keep the intended anon/authenticated grants (PUBLIC already revoked above).
  IF to_regprocedure('public.gdpr_export_my_data()') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.gdpr_export_my_data() TO authenticated; END IF;
  IF to_regprocedure('public.gdpr_request_deletion()') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.gdpr_request_deletion() TO authenticated; END IF;
  IF to_regprocedure('public.gdpr_set_newsletter(boolean)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.gdpr_set_newsletter(boolean) TO authenticated; END IF;
  IF to_regprocedure('public.gdpr_withdraw_consent(text,text)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.gdpr_withdraw_consent(text,text) TO anon, authenticated; END IF;
  IF to_regprocedure('public.gdpr_submit_request(text,text,jsonb)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.gdpr_submit_request(text,text,jsonb) TO anon, authenticated; END IF;
  IF to_regprocedure('public.gdpr_request_newsletter_optin(text,text)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.gdpr_request_newsletter_optin(text,text) TO anon, authenticated; END IF;
  IF to_regprocedure('public.gdpr_confirm_newsletter_optin(text)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION public.gdpr_confirm_newsletter_optin(text) TO anon, authenticated; END IF;
END $$;

-- ---------------------------------------------------------------------
-- F3/F4: internal tables — enable+force RLS, drop anon/authenticated, service_role only.
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['schema_registry','track_binocle_runtime_migrations'] LOOP
    IF to_regclass('public.'||t) IS NOT NULL THEN
      EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
      EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
      EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', t);
      EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t||'_service_role_all', t);
      EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL TO service_role USING (true) WITH CHECK (true)', t||'_service_role_all', t);
      EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- F7: strip the blanket default-privilege grant so future tables are not
-- auto-opened (always valid — no object dependency).
-- ---------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM anon, authenticated;

-- ---------------------------------------------------------------------
-- F7: per-table grant hygiene — revoke anon; re-grant authenticated exactly the
-- verbs each table's policies use (writes mostly flow through service_role RPCs).
-- ---------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.osionos_bridge_identities') IS NOT NULL THEN
    REVOKE ALL ON public.osionos_bridge_identities FROM anon, authenticated;
    GRANT SELECT ON public.osionos_bridge_identities TO authenticated; END IF;
  IF to_regclass('public.osionos_workspaces') IS NOT NULL THEN
    REVOKE ALL ON public.osionos_workspaces FROM anon, authenticated;
    GRANT SELECT ON public.osionos_workspaces TO authenticated; END IF;
  IF to_regclass('public.osionos_workspace_members') IS NOT NULL THEN
    REVOKE ALL ON public.osionos_workspace_members FROM anon, authenticated;
    GRANT SELECT ON public.osionos_workspace_members TO authenticated; END IF;
  IF to_regclass('public.osionos_pages') IS NOT NULL THEN
    REVOKE ALL ON public.osionos_pages FROM anon, authenticated;
    GRANT SELECT, INSERT, UPDATE, DELETE ON public.osionos_pages TO authenticated; END IF;
  IF to_regclass('public.osionos_page_configurations') IS NOT NULL THEN
    REVOKE ALL ON public.osionos_page_configurations FROM anon, authenticated;
    GRANT SELECT, INSERT, UPDATE ON public.osionos_page_configurations TO authenticated; END IF;
  IF to_regclass('public.osionos_page_action_events') IS NOT NULL THEN
    REVOKE ALL ON public.osionos_page_action_events FROM anon, authenticated;
    GRANT SELECT, INSERT ON public.osionos_page_action_events TO authenticated; END IF;
  IF to_regclass('public.osionos_bridge_audit_events') IS NOT NULL THEN
    REVOKE ALL ON public.osionos_bridge_audit_events FROM anon, authenticated; END IF;
  IF to_regclass('public.gdpr_requests') IS NOT NULL THEN
    REVOKE ALL ON public.gdpr_requests FROM anon, authenticated;
    GRANT SELECT ON public.gdpr_requests TO authenticated; END IF;
  IF to_regclass('public.newsletter_optins') IS NOT NULL THEN
    REVOKE ALL ON public.newsletter_optins FROM anon, authenticated; END IF;
END $$;

-- ---------------------------------------------------------------------
-- F6: tenant_databases — role-scope policies (only if present, with its GUC fn).
-- ---------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.tenant_databases') IS NOT NULL
     AND to_regprocedure('public.current_tenant_id()') IS NOT NULL THEN
    REVOKE ALL ON public.tenant_databases FROM anon, authenticated;
    DROP POLICY IF EXISTS tenant_databases_select ON public.tenant_databases;
    DROP POLICY IF EXISTS tenant_databases_insert ON public.tenant_databases;
    DROP POLICY IF EXISTS tenant_databases_update ON public.tenant_databases;
    CREATE POLICY tenant_databases_select ON public.tenant_databases
      FOR SELECT TO authenticated USING (tenant_id = current_tenant_id());
    CREATE POLICY tenant_databases_insert ON public.tenant_databases
      FOR INSERT TO authenticated WITH CHECK (tenant_id = current_tenant_id());
    CREATE POLICY tenant_databases_update ON public.tenant_databases
      FOR UPDATE TO authenticated USING (tenant_id = current_tenant_id())
                                  WITH CHECK (tenant_id = current_tenant_id());
    DROP POLICY IF EXISTS tenant_databases_service_role_all ON public.tenant_databases;
    CREATE POLICY tenant_databases_service_role_all ON public.tenant_databases
      FOR ALL TO service_role USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- F5: users — cap anon enumeration to non-PII columns (keeps the public-profile
-- read policy but drops email/bio/etc. from the anon column grant).
-- ---------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.users') IS NOT NULL THEN
    REVOKE SELECT ON public.users FROM anon;
    GRANT SELECT (id, username, avatar_url, is_email_verified) ON public.users TO anon;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- Defense-in-depth: FORCE RLS on every policy-protected table that exists.
-- All SECDEF helpers are owned by postgres (bypassrls) and service_role has
-- bypassrls, so the RPC/service paths are unaffected.
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'users','user_consents','user_activities','sessions','user_tokens',
    'gdpr_requests','newsletter_optins','auth_audit_events',
    'calendar_accounts','calendar_sources','calendar_event_cache',
    'osionos_bridge_identities','osionos_workspaces','osionos_workspace_members',
    'osionos_pages','osionos_page_configurations','osionos_page_action_events',
    'osionos_bridge_audit_events'] LOOP
    IF to_regclass('public.'||t) IS NOT NULL THEN
      EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', t);
    END IF;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
COMMIT;
