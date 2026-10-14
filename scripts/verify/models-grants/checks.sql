-- Every query below returns exactly ONE row of <label>|<count>|<detail>, so the caller can
-- find it by its label prefix and split it with cut -d'|'. Run with -At (unaligned, tuples
-- only): the label is then the first field of a line and nothing else lands on stdout.
\set ON_ERROR_STOP on

-- privileged: every osionos_% relation anon/authenticated can touch (column grants included)
SELECT 'privileged', count(*), coalesce(string_agg(c.relname, ' ' ORDER BY c.relname), '')
  FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
 WHERE ns.nspname = 'public' AND c.relname LIKE 'osionos\_%' AND c.relkind IN ('r','p','v','m','f')
   AND (has_any_column_privilege('anon', c.oid, 'SELECT') OR has_any_column_privilege('anon', c.oid, 'INSERT')
     OR has_any_column_privilege('anon', c.oid, 'UPDATE') OR has_table_privilege('anon', c.oid, 'DELETE')
     OR has_any_column_privilege('authenticated', c.oid, 'SELECT') OR has_any_column_privilege('authenticated', c.oid, 'INSERT')
     OR has_any_column_privilege('authenticated', c.oid, 'UPDATE') OR has_table_privilege('authenticated', c.oid, 'DELETE'));

-- member_policies: policies on osionos_% for PUBLIC (oid 0), anon or authenticated
SELECT 'member_policies', count(*), coalesce(string_agg(c.relname || ':' || p.polname, ' ' ORDER BY 1), '')
  FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid JOIN pg_namespace ns ON ns.oid = c.relnamespace
 WHERE ns.nspname = 'public' AND c.relname LIKE 'osionos\_%'
   AND (0::oid = ANY (p.polroles) OR p.polroles && ARRAY(SELECT oid FROM pg_roles WHERE rolname IN ('anon','authenticated')));

-- service_role_gaps: osionos tables service_role cannot fully CRUD
SELECT 'service_role_gaps', count(*), coalesce(string_agg(c.relname, ' ' ORDER BY c.relname), '')
  FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
 WHERE ns.nspname = 'public' AND c.relname LIKE 'osionos\_%' AND c.relkind IN ('r','p')
   AND NOT (has_table_privilege('service_role', c.oid, 'SELECT') AND has_table_privilege('service_role', c.oid, 'INSERT')
        AND has_table_privilege('service_role', c.oid, 'UPDATE') AND has_table_privilege('service_role', c.oid, 'DELETE'));

-- svc_rows: the bridge can still write and read back. Rolled back, so nothing is left behind.
BEGIN;
SET LOCAL ROLE service_role;
INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES ('22222222-2222-2222-2222-222222222222','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','w2','w2');
INSERT INTO public.osionos_pages (id, workspace_id, owner_id, title) VALUES ('99999999-0000-0000-0000-0000000000aa','22222222-2222-2222-2222-222222222222','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','svc');
UPDATE public.osionos_pages SET title = 'svc2' WHERE id = '99999999-0000-0000-0000-0000000000aa';
SELECT 'svc_rows', count(*) FROM public.osionos_pages WHERE id = '99999999-0000-0000-0000-0000000000aa' AND title = 'svc2';
DELETE FROM public.osionos_pages WHERE id = '99999999-0000-0000-0000-0000000000aa';
ROLLBACK;

-- secdef_exec: SECURITY DEFINER osionos_% functions anon/authenticated may execute
SELECT 'secdef_exec', count(*), coalesce(string_agg(p.oid::regprocedure::text, ' '), '')
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.prosecdef AND p.proname LIKE 'osionos\_%'
   AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE'));
-- notify_types_missing: types the final notifications CHECK refuses. Three models files redefine
-- the cumulative list and the last one applied wins, so a short list there drops a type silently.
-- Ponytail: matches quoted literals in pg_get_constraintdef — a CHECK rewritten as anything but an
-- IN-list reports every type missing (a false FAIL, never a false pass).
SELECT 'notify_types_missing', count(*), coalesce(string_agg(t, ' ' ORDER BY t), '')
  FROM unnest(ARRAY['mention','dm','reply','reaction','connection','system','feed_reaction',
                    'feed_comment','feed_share','task_due','page_comment']) AS t
 WHERE NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'osionos_notifications_type_check'
                      AND pg_get_constraintdef(oid) LIKE '%''' || t || '''%');

-- realtime_triggers: osionos_% tables whose row changes grobase's realtime_notify() broadcasts
-- (SECURITY DEFINER, full row, no grant or RLS check at the gateway).
SELECT 'realtime_triggers', count(*), coalesce(string_agg(c.relname, ' ' ORDER BY c.relname), '')
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
 WHERE c.relnamespace = 'public'::regnamespace AND c.relname LIKE 'osionos\_%'
   AND NOT t.tgisinternal AND t.tgfoid = to_regproc('public.realtime_notify');
