-- One line per osionos_% relation, then one per osionos_% public function. Diffed against
-- itself around a second runner pass (check g): any GRANT, policy, RLS flag or function ACL
-- that a replay moves must show up here as a changed line.
-- relname|relkind|relacl|rowsecurity|forcerowsecurity|policies — and proname(args)|proacl.
\set ON_ERROR_STOP on

-- polcmd is "char", and text || "char" is not unique without the cast.
SELECT c.relname, c.relkind, c.relacl::text, c.relrowsecurity, c.relforcerowsecurity,
       coalesce((SELECT string_agg(p.polname || ':' || p.polcmd::text || ':' || p.polroles::text, ' ' ORDER BY p.polname)
                   FROM pg_policy p WHERE p.polrelid = c.oid), '')
  FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
 WHERE ns.nspname = 'public' AND c.relname LIKE 'osionos\_%' AND c.relkind IN ('r','p','v','m','f')
 ORDER BY c.relname;

SELECT p.proname || '(' || pg_get_function_arguments(p.oid) || ')', p.proacl::text
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname LIKE 'osionos\_%'
 ORDER BY 1;