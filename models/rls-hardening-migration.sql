-- =====================================================================
-- RLS hardening migration — track-binocle BaaS
-- Closes F1-F7 from wiki/security/baas-rls-audit.md (live-verified findings).
--
-- The Kong anon apikey is public by design; there is no Kong ACL plugin on
-- /rest/v1, so Postgres RLS + grants are the ONLY data wall. This migration
-- removes the leaked PUBLIC execute on destructive SECURITY DEFINER functions,
-- enables/forces RLS on the two open internal tables, strips the blanket
-- anon/authenticated CRUD grants, role-scopes tenant_databases, caps anon
-- enumeration of users, and FORCEs RLS everywhere for defense in depth.
--
-- Signatures verified live (pg_proc). All SECDEF functions are owned by
-- `postgres` (superuser+bypassrls) and service_role has bypassrls, so FORCE RLS
-- does not affect the RPC/service-role paths. Atomic: any error rolls back.
-- =====================================================================
BEGIN;
SET LOCAL search_path = public;

-- ---------------------------------------------------------------------
-- F1 (CRITICAL) / F2 (HIGH): revoke the leaked PUBLIC execute on SECURITY
-- DEFINER functions. REVOKE ... FROM anon/authenticated does NOT remove the
-- default PUBLIC grant, which is what anon actually inherited.
-- ---------------------------------------------------------------------
-- anonymise_user: destructive (wipes account + deletes sessions/tokens).
-- Must be callable by NO API role — owner/service_role only.
REVOKE EXECUTE ON FUNCTION public.anonymise_user(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.anonymise_user(integer) FROM anon, authenticated;

-- auth_record_audit_event: service_role only (the gateway calls it with the
-- service key); anon must not be able to forge audit rows.
REVOKE EXECUTE ON FUNCTION public.auth_record_audit_event(text, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.auth_record_audit_event(text, text, jsonb) FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.auth_record_audit_event(text, text, jsonb) TO service_role;

-- gdpr_* functions carry a redundant PUBLIC execute on top of their intended
-- anon/authenticated grants. Drop PUBLIC, keep the explicit role grants.
REVOKE EXECUTE ON FUNCTION public.gdpr_export_my_data()                     FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.gdpr_request_deletion()                   FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.gdpr_set_newsletter(boolean)             FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.gdpr_withdraw_consent(text, text)        FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.gdpr_submit_request(text, text, jsonb)   FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.gdpr_request_newsletter_optin(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.gdpr_confirm_newsletter_optin(text)      FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gdpr_export_my_data()                     TO authenticated;
GRANT EXECUTE ON FUNCTION public.gdpr_request_deletion()                   TO authenticated;
GRANT EXECUTE ON FUNCTION public.gdpr_set_newsletter(boolean)             TO authenticated;
GRANT EXECUTE ON FUNCTION public.gdpr_withdraw_consent(text, text)        TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gdpr_submit_request(text, text, jsonb)   TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gdpr_request_newsletter_optin(text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gdpr_confirm_newsletter_optin(text)      TO anon, authenticated;

-- ---------------------------------------------------------------------
-- F3 (HIGH): schema_registry — enable + force RLS, drop anon/authenticated.
-- ---------------------------------------------------------------------
REVOKE ALL ON public.schema_registry FROM anon, authenticated;
ALTER TABLE public.schema_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.schema_registry FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS schema_registry_service_role_all ON public.schema_registry;
CREATE POLICY schema_registry_service_role_all ON public.schema_registry
  FOR ALL TO service_role USING (true) WITH CHECK (true);
GRANT ALL ON public.schema_registry TO service_role;

-- ---------------------------------------------------------------------
-- F4 (HIGH): track_binocle_runtime_migrations — enable + force RLS, drop anon.
-- ---------------------------------------------------------------------
REVOKE ALL ON public.track_binocle_runtime_migrations FROM anon, authenticated;
ALTER TABLE public.track_binocle_runtime_migrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.track_binocle_runtime_migrations FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS trk_runtime_migrations_service_role_all ON public.track_binocle_runtime_migrations;
CREATE POLICY trk_runtime_migrations_service_role_all ON public.track_binocle_runtime_migrations
  FOR ALL TO service_role USING (true) WITH CHECK (true);
GRANT ALL ON public.track_binocle_runtime_migrations TO service_role;

-- ---------------------------------------------------------------------
-- F7: strip the blanket anon/authenticated CRUD grant + the default-privilege
-- grant so future tables are not auto-opened. Re-grant ONLY the verbs each
-- table's existing policies actually use (writes go through service_role RPCs).
-- ---------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM anon, authenticated;

REVOKE ALL ON public.osionos_bridge_identities, public.osionos_workspaces,
              public.osionos_workspace_members, public.osionos_pages,
              public.osionos_page_configurations, public.osionos_page_action_events,
              public.osionos_bridge_audit_events
  FROM anon, authenticated;
GRANT SELECT ON public.osionos_bridge_identities  TO authenticated;
GRANT SELECT ON public.osionos_workspaces         TO authenticated;
GRANT SELECT ON public.osionos_workspace_members  TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.osionos_pages TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.osionos_page_configurations TO authenticated;
GRANT SELECT, INSERT ON public.osionos_page_action_events TO authenticated;
-- osionos_bridge_audit_events: service_role only (no anon/authenticated grant).

-- gdpr_requests: DSAR submission flows through gdpr_submit_request() (SECDEF);
-- authenticated may read its own rows. No direct anon table grant needed.
REVOKE ALL ON public.gdpr_requests FROM anon, authenticated;
GRANT SELECT ON public.gdpr_requests TO authenticated;

-- newsletter_optins: written only by SECDEF RPCs -> no table grant.
REVOKE ALL ON public.newsletter_optins FROM anon, authenticated;

-- ---------------------------------------------------------------------
-- F6: tenant_databases — role-scope the policies (was TO public) and drop the
-- anon/authenticated table grant. Holds ENCRYPTED tenant connection material.
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- F5 (MED): users — stop anon harvesting emails. Option B (minimal, keeps any
-- public-profile feature working): anon may read only non-PII columns of
-- non-deleted users; email/bio/etc. are no longer anon-readable. Authenticated
-- still reads its own full row via users_select_own.
-- ---------------------------------------------------------------------
REVOKE SELECT ON public.users FROM anon;
GRANT SELECT (id, username, avatar_url, is_email_verified) ON public.users TO anon;

-- ---------------------------------------------------------------------
-- Defense-in-depth: FORCE RLS on every policy-protected table. All SECDEF
-- helpers are owned by postgres (bypassrls) and service_role has bypassrls, so
-- the RPC/service paths are unaffected; only the SET ROLE anon/authenticated
-- request paths are governed by RLS, as intended.
-- ---------------------------------------------------------------------
ALTER TABLE public.users                        FORCE ROW LEVEL SECURITY;
ALTER TABLE public.user_consents                FORCE ROW LEVEL SECURITY;
ALTER TABLE public.user_activities              FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sessions                     FORCE ROW LEVEL SECURITY;
ALTER TABLE public.user_tokens                  FORCE ROW LEVEL SECURITY;
ALTER TABLE public.gdpr_requests                FORCE ROW LEVEL SECURITY;
ALTER TABLE public.newsletter_optins            FORCE ROW LEVEL SECURITY;
ALTER TABLE public.auth_audit_events            FORCE ROW LEVEL SECURITY;
ALTER TABLE public.calendar_accounts            FORCE ROW LEVEL SECURITY;
ALTER TABLE public.calendar_sources             FORCE ROW LEVEL SECURITY;
ALTER TABLE public.calendar_event_cache         FORCE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_bridge_identities    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_workspaces           FORCE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_workspace_members    FORCE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_pages                FORCE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_page_configurations  FORCE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_page_action_events   FORCE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_bridge_audit_events  FORCE ROW LEVEL SECURITY;

NOTIFY pgrst, 'reload schema';
COMMIT;
