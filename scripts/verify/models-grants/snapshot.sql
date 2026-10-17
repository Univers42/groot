-- One line per osionos_% relation and public.auth_session_cutoffs and public.auth_audit_events, one per osionos_% public function and auth_record_audit_event, then the realtime
-- broadcast state. Diffed against itself around a second runner pass (check g): any GRANT,
-- policy, RLS flag, function ACL or realtime trigger that a replay moves must show up here
-- as a changed line.
-- relname|relkind|relacl|rowsecurity|forcerowsecurity|policies — and proname(args)|proacl.
\set ON_ERROR_STOP on

-- polcmd is "char", and text || "char" is not unique without the cast.
SELECT c.relname, c.relkind, c.relacl::text, c.relrowsecurity, c.relforcerowsecurity,
       coalesce((SELECT string_agg(p.polname || ':' || p.polcmd::text || ':' || p.polroles::text, ' ' ORDER BY p.polname)
                   FROM pg_policy p WHERE p.polrelid = c.oid), '')
  FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
 WHERE ns.nspname = 'public' AND (c.relname LIKE 'osionos\_%' OR c.relname IN ('auth_session_cutoffs','auth_audit_events','auth_audit_events_legacy_int')) AND c.relkind IN ('r','p','v','m','f')
 ORDER BY c.relname;

SELECT p.proname || '(' || pg_get_function_arguments(p.oid) || ')', p.proacl::text
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND (p.proname LIKE 'osionos\_%' OR p.proname = 'auth_record_audit_event')
 ORDER BY 1;

-- The realtime broadcast state: a replay that re-arms a table or re-enables the hook shows here.
SELECT 'realtime_trigger', c.relname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
 WHERE c.relnamespace = 'public'::regnamespace AND NOT t.tgisinternal
   AND t.tgfoid = to_regproc('public.realtime_notify')
 ORDER BY 2;
SELECT 'realtime_event_trigger', evtenabled::text FROM pg_event_trigger
 WHERE evtname = 'realtime_auto_trigger_on_create';