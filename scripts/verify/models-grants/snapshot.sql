-- One line per osionos_% relation and public.auth_session_cutoffs, one per osionos_% public function, then the realtime
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
 WHERE ns.nspname = 'public' AND (c.relname LIKE 'osionos\_%' OR c.relname LIKE 'ai\_%' OR c.relname = 'auth_session_cutoffs') AND c.relkind IN ('r','p','v','m','f')
 ORDER BY c.relname;

SELECT p.proname || '(' || pg_get_function_arguments(p.oid) || ')', p.proacl::text
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND (p.proname LIKE 'osionos\_%' OR p.proname LIKE 'ai\_%')
 ORDER BY 1;

-- The realtime broadcast state: a replay that re-arms a table or re-enables the hook shows here.
SELECT 'realtime_trigger', c.relname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
 WHERE c.relnamespace = 'public'::regnamespace AND NOT t.tgisinternal
   AND t.tgfoid = to_regproc('public.realtime_notify')
 ORDER BY 2;
SELECT 'realtime_event_trigger', evtenabled::text FROM pg_event_trigger
 WHERE evtname = 'realtime_auto_trigger_on_create';
-- users ACL per column: a replay that moves a public.users grant shows as a changed line.
SELECT 'users_acl', attname, attacl::text FROM pg_attribute
 WHERE attrelid = 'public.users'::regclass AND attnum > 0 AND NOT attisdropped ORDER BY attnum;
SELECT 'users_acl', relname, relacl::text FROM pg_class WHERE oid = 'public.users'::regclass;
-- Column ACLs of the same relation set: a replay that moves a column-level grant
-- (the account role's nine session columns) shows as a changed line.
SELECT 'col_acl', c.relname, a.attname, a.attacl::text
  FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid
 WHERE ns.nspname = 'public' AND (c.relname LIKE 'osionos\_%' OR c.relname = 'auth_session_cutoffs') AND c.relkind IN ('r','p','v','m','f')
   AND a.attnum > 0 AND NOT a.attisdropped AND a.attacl IS NOT NULL
 ORDER BY c.relname, a.attnum;
-- The account role's memberships: a replay that adds or re-grants a membership
-- shows as a changed line. set_option is what lets PostgREST switch to the role;
-- inherit_option must stay off, or authenticator would hold the role's privileges
-- without switching.
SELECT 'auth_members', r.rolname, m.rolname, am.grantor::regrole::text,
       am.admin_option, am.inherit_option, am.set_option
  FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.roleid JOIN pg_roles m ON m.oid = am.member
 WHERE r.rolname = 'osionos_account_user' OR m.rolname = 'osionos_account_user'
 ORDER BY 2, 3;
-- The role's own attributes: a replay that re-grants LOGIN or BYPASSRLS shows here.
SELECT 'role_attrs', rolname, rolsuper, rolinherit, rolcreaterole, rolcreatedb,
       rolcanlogin, rolreplication, rolbypassrls, rolconnlimit
  FROM pg_roles WHERE rolname = 'osionos_account_user';
