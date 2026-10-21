-- Every query below returns exactly ONE row of <label>|<count>|<detail>, so the caller can
-- find it by its label prefix and split it with cut -d'|'. Run with -At (unaligned, tuples
-- only): the label is then the first field of a line and nothing else lands on stdout.
\set ON_ERROR_STOP on

-- The service_role-only set: every osionos_% and ai_% relation, plus public.auth_session_cutoffs
-- (models/auth-session-cutoffs.sql), which carries no osionos_ prefix. ai_% includes the hash
-- partitions of ai_chunks and ai_page_vectors: a partition is a table of its own, readable
-- directly, and it does not inherit its parent's grants or RLS flag.

-- privileged: every such relation anon/authenticated can touch (column grants included)
SELECT 'privileged', count(*), coalesce(string_agg(c.relname, ' ' ORDER BY c.relname), '')
  FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
 WHERE ns.nspname = 'public' AND (c.relname LIKE 'osionos\_%' OR c.relname LIKE 'ai\_%' OR c.relname = 'auth_session_cutoffs') AND c.relkind IN ('r','p','v','m','f')
   AND (has_any_column_privilege('anon', c.oid, 'SELECT') OR has_any_column_privilege('anon', c.oid, 'INSERT')
     OR has_any_column_privilege('anon', c.oid, 'UPDATE') OR has_table_privilege('anon', c.oid, 'DELETE')
     OR has_any_column_privilege('authenticated', c.oid, 'SELECT') OR has_any_column_privilege('authenticated', c.oid, 'INSERT')
     OR has_any_column_privilege('authenticated', c.oid, 'UPDATE') OR has_table_privilege('authenticated', c.oid, 'DELETE'));

-- member_policies: policies on the set for PUBLIC (oid 0), anon or authenticated
SELECT 'member_policies', count(*), coalesce(string_agg(c.relname || ':' || p.polname, ' ' ORDER BY 1), '')
  FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid JOIN pg_namespace ns ON ns.oid = c.relnamespace
 WHERE ns.nspname = 'public' AND (c.relname LIKE 'osionos\_%' OR c.relname LIKE 'ai\_%' OR c.relname = 'auth_session_cutoffs')
   AND (0::oid = ANY (p.polroles) OR p.polroles && ARRAY(SELECT oid FROM pg_roles WHERE rolname IN ('anon','authenticated')));

-- service_role_gaps: tables in the set service_role cannot fully CRUD
SELECT 'service_role_gaps', count(*), coalesce(string_agg(c.relname, ' ' ORDER BY c.relname), '')
  FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
 WHERE ns.nspname = 'public' AND (c.relname LIKE 'osionos\_%' OR c.relname LIKE 'ai\_%' OR c.relname = 'auth_session_cutoffs') AND c.relkind IN ('r','p')
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

-- svc_cutoff: the auth-gateway's write, as PostgREST runs a merge-duplicates upsert, twice,
-- so the second takes the ON CONFLICT path. The auth.users row is the shim's. Rolled back.
BEGIN;
INSERT INTO auth.users (id) VALUES ('dddddddd-dddd-dddd-dddd-dddddddddddd');
SET LOCAL ROLE service_role;
INSERT INTO public.auth_session_cutoffs (user_id, sessions_valid_after) VALUES ('dddddddd-dddd-dddd-dddd-dddddddddddd', '2026-10-15 12:00:00+00')
  ON CONFLICT (user_id) DO UPDATE SET sessions_valid_after = EXCLUDED.sessions_valid_after;
INSERT INTO public.auth_session_cutoffs (user_id, sessions_valid_after) VALUES ('dddddddd-dddd-dddd-dddd-dddddddddddd', '2026-10-15 12:00:01+00')
  ON CONFLICT (user_id) DO UPDATE SET sessions_valid_after = EXCLUDED.sessions_valid_after;
SELECT 'svc_cutoff', count(*) FROM public.auth_session_cutoffs
 WHERE user_id = 'dddddddd-dddd-dddd-dddd-dddddddddddd' AND sessions_valid_after = '2026-10-15 12:00:01+00';
ROLLBACK;

-- svc_cutoff_monotonic: T2 is written, then an older T1 arrives through the same upsert; the row
-- must still hold T2 (the monotonic trigger). Rolled back.
BEGIN;
INSERT INTO auth.users (id) VALUES ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee');
SET LOCAL ROLE service_role;
INSERT INTO public.auth_session_cutoffs (user_id, sessions_valid_after) VALUES ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', '2026-10-19 10:00:00+00')
  ON CONFLICT (user_id) DO UPDATE SET sessions_valid_after = EXCLUDED.sessions_valid_after;
INSERT INTO public.auth_session_cutoffs (user_id, sessions_valid_after) VALUES ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', '2026-10-19 09:59:00+00')
  ON CONFLICT (user_id) DO UPDATE SET sessions_valid_after = EXCLUDED.sessions_valid_after;
SELECT 'svc_cutoff_monotonic', count(*) FROM public.auth_session_cutoffs
 WHERE user_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' AND sessions_valid_after = '2026-10-19 10:00:00+00';
ROLLBACK;

-- secdef_exec: SECURITY DEFINER osionos_% functions anon/authenticated may execute
SELECT 'secdef_exec', count(*), coalesce(string_agg(p.oid::regprocedure::text, ' '), '')
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.prosecdef AND p.proname LIKE 'osionos\_%'
   AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE'));
-- ai_write_fn_exec: VOLATILE, non-trigger ai_% functions anon/authenticated may execute (the
-- writers of the AI tables), plus 1 per named writer that is missing, so a rename cannot pass.
SELECT 'ai_write_fn_exec',
       count(*) + 2 - (to_regprocedure('public.ai_write_page_vector(uuid,uuid,halfvec,text)') IS NOT NULL)::int
                    - (to_regprocedure('public.ai_drop_page_vector(uuid)') IS NOT NULL)::int,
       coalesce(string_agg(p.oid::regprocedure::text, ' '), '')
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname LIKE 'ai\_%' AND p.provolatile = 'v' AND p.prorettype <> 'trigger'::regtype
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

-- realtime_triggers: public tables whose row changes grobase's realtime_notify() broadcasts
-- (SECURITY DEFINER, full row, no grant or RLS check at the gateway).
SELECT 'realtime_triggers', count(*), coalesce(string_agg(c.relname, ' ' ORDER BY c.relname), '')
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
 WHERE c.relnamespace = 'public'::regnamespace
   AND NOT t.tgisinternal AND t.tgfoid = to_regproc('public.realtime_notify');

-- realtime_event_trigger: 1 when grobase's CREATE TABLE hook would arm the next table, or when
-- it is missing — both scenarios apply 012, so a missing hook means this check proves nothing.
SELECT 'realtime_event_trigger',
       CASE WHEN coalesce(min(evtenabled::text), 'missing') = 'D' THEN 0 ELSE 1 END,
       coalesce(min(evtenabled::text), 'missing')
  FROM pg_event_trigger WHERE evtname = 'realtime_auto_trigger_on_create';

-- cutoff_realtime_triggers: realtime_notify() triggers on public.auth_session_cutoffs itself, plus 1 when
-- the table is missing. The sweep above is generic and prints nothing for a clean run; this row names the
-- table, so a runner that stops dropping its trigger, or a renamed table, cannot pass silently.
SELECT 'cutoff_realtime_triggers',
       CASE WHEN to_regclass('public.auth_session_cutoffs') IS NULL THEN 1
            ELSE (SELECT count(*) FROM pg_trigger t
                   WHERE t.tgrelid = 'public.auth_session_cutoffs'::regclass
                     AND NOT t.tgisinternal AND t.tgfoid = to_regproc('public.realtime_notify')) END,
       coalesce(to_regclass('public.auth_session_cutoffs')::text, 'public.auth_session_cutoffs MISSING');

-- users_pii: the credential/PII columns of public.users a role can SELECT. has_column_privilege is
-- true for a table-level grant too, so a blanket GRANT SELECT or a PUBLIC grant shows here. The
-- allowed set is anon: none of these, authenticated: email only (ADR 0014).
SELECT 'users_pii', count(*), coalesce(string_agg(r || '.' || c, ' ' ORDER BY r, c), '')
  FROM (VALUES ('anon','email'), ('anon','password_hash'), ('authenticated','password_hash')) AS x(r, c)
 WHERE has_column_privilege(r, 'public.users', c, 'SELECT');
