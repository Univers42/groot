-- Every query below returns exactly ONE row of <label>|<count>|<detail>, so the caller can
-- find it by its label prefix and split it with cut -d'|'. Run with -At (unaligned, tuples
-- only): the label is then the first field of a line and nothing else lands on stdout.
\set ON_ERROR_STOP on

-- The service_role-only set: every osionos_% relation, plus public.auth_session_cutoffs
-- (models/auth-session-cutoffs.sql), which carries no osionos_ prefix.

-- privileged: every such relation anon/authenticated can touch (column grants included)
SELECT 'privileged', count(*), coalesce(string_agg(c.relname, ' ' ORDER BY c.relname), '')
  FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
 WHERE ns.nspname = 'public' AND (c.relname LIKE 'osionos\_%' OR c.relname = 'auth_session_cutoffs') AND c.relkind IN ('r','p','v','m','f')
   AND (has_any_column_privilege('anon', c.oid, 'SELECT') OR has_any_column_privilege('anon', c.oid, 'INSERT')
     OR has_any_column_privilege('anon', c.oid, 'UPDATE') OR has_table_privilege('anon', c.oid, 'DELETE')
     OR has_any_column_privilege('authenticated', c.oid, 'SELECT') OR has_any_column_privilege('authenticated', c.oid, 'INSERT')
     OR has_any_column_privilege('authenticated', c.oid, 'UPDATE') OR has_table_privilege('authenticated', c.oid, 'DELETE'));

-- member_policies: policies on the set for PUBLIC (oid 0), anon or authenticated
SELECT 'member_policies', count(*), coalesce(string_agg(c.relname || ':' || p.polname, ' ' ORDER BY 1), '')
  FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid JOIN pg_namespace ns ON ns.oid = c.relnamespace
 WHERE ns.nspname = 'public' AND (c.relname LIKE 'osionos\_%' OR c.relname = 'auth_session_cutoffs')
   AND (0::oid = ANY (p.polroles) OR p.polroles && ARRAY(SELECT oid FROM pg_roles WHERE rolname IN ('anon','authenticated')));

-- service_role_gaps: tables in the set service_role cannot fully CRUD
SELECT 'service_role_gaps', count(*), coalesce(string_agg(c.relname, ' ' ORDER BY c.relname), '')
  FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
 WHERE ns.nspname = 'public' AND (c.relname LIKE 'osionos\_%' OR c.relname = 'auth_session_cutoffs') AND c.relkind IN ('r','p')
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
-- (the account role counts too: it is the third role that may hold EXECUTE).
SELECT 'secdef_exec', count(*), coalesce(string_agg(p.oid::regprocedure::text, ' '), '')
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.prosecdef AND p.proname LIKE 'osionos\_%'
   AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
     OR CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'osionos_account_user')
             THEN has_function_privilege('osionos_account_user', p.oid, 'EXECUTE')
             ELSE false END);
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

-- The account plane (models/osionos-account-foundation-migration.sql). The role
-- osionos_account_user reaches the tables marked COMMENT ... 'osionos:account-plane'
-- and nothing else; k1-k8 are the acceptance checks of that (ADR 0028).

-- account_role_reach: relations the account role reaches that anon does not reach,
-- and that are not marked as account-plane. anon is the yardstick on purpose: a
-- privilege both roles hold through PUBLIC is not a reach the account role gained.
SELECT 'account_role_reach', count(*), coalesce(string_agg(c.relname, ' ' ORDER BY c.relname), '')
  FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
 WHERE ns.nspname NOT IN ('pg_catalog','information_schema')
   AND c.relkind IN ('r','p','v','m','f')
   AND coalesce(obj_description(c.oid, 'pg_class'), '') <> 'osionos:account-plane'
   AND (has_any_column_privilege('osionos_account_user', c.oid, 'SELECT')
     OR has_any_column_privilege('osionos_account_user', c.oid, 'INSERT')
     OR has_any_column_privilege('osionos_account_user', c.oid, 'UPDATE')
     OR has_table_privilege('osionos_account_user', c.oid, 'DELETE'))
   AND NOT (has_any_column_privilege('anon', c.oid, 'SELECT')
     OR has_any_column_privilege('anon', c.oid, 'INSERT')
     OR has_any_column_privilege('anon', c.oid, 'UPDATE')
     OR has_table_privilege('anon', c.oid, 'DELETE'));

-- account_plane_rls: every marked relation is an ordinary table with RLS on, whose
-- policies name no role but service_role and osionos_account_user (PUBLIC, oid 0,
-- is outside), with at least one policy for the account role, and whose
-- account-role policy filters on the uid helper.
-- Caveat: textual — pg_get_expr is compared as text, so a policy that names the
-- helper in a string literal passes, and one that reaches the same rows another
-- way (a session variable, a security-barrier view) fails.
SELECT 'account_plane_rls', count(*), coalesce(string_agg(c.relname, ' ' ORDER BY c.relname), '')
  FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
 WHERE ns.nspname NOT IN ('pg_catalog','information_schema')
   AND c.relkind IN ('r','p','v','m','f')
   AND coalesce(obj_description(c.oid, 'pg_class'), '') = 'osionos:account-plane'
   AND (
     c.relkind NOT IN ('r','p')
     OR NOT c.relrowsecurity
     OR EXISTS (SELECT 1 FROM pg_policy p
                 WHERE p.polrelid = c.oid
                   AND NOT (p.polroles <@ ARRAY(SELECT oid FROM pg_roles WHERE rolname IN ('service_role','osionos_account_user'))))
     OR NOT EXISTS (SELECT 1 FROM pg_policy p
                     WHERE p.polrelid = c.oid
                       AND (SELECT oid FROM pg_roles WHERE rolname = 'osionos_account_user') = ANY (p.polroles))
     OR EXISTS (SELECT 1 FROM pg_policy p
                 WHERE p.polrelid = c.oid
                   AND (SELECT oid FROM pg_roles WHERE rolname = 'osionos_account_user') = ANY (p.polroles)
                   AND (coalesce(pg_get_expr(p.polqual, p.polrelid), '') NOT LIKE '%osionos_account_uid%'
                     OR (p.polcmd <> 'r' AND coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') NOT LIKE '%osionos_account_uid%')))
   );

-- account_plane_expected: the account-plane tables this package promises. Later
-- packages append theirs.
SELECT 'account_plane_expected', count(*), coalesce(string_agg(t, ' ' ORDER BY t), '')
  FROM unnest(ARRAY['osionos_sessions']) AS t
 WHERE to_regclass('public.' || t) IS NULL
    OR coalesce(obj_description(to_regclass('public.' || t), 'pg_class'), '') <> 'osionos:account-plane';

-- account_indexes_missing: the indexes the account plane and today's queries
-- need, by key columns. The key list is the first indnkeyatts entries of indkey,
-- in order; a partial index still counts (the key is what the planner matches on).
WITH expected(tbl, cols) AS (
  VALUES ('osionos_bridge_identities','email_hash'),
         ('osionos_feed_shares','user_id,target,created_at'),
         ('osionos_sessions','user_id,created_at'),
         ('osionos_sessions','revoked_at'),
         ('osionos_sessions','expires_at'),
         ('osionos_bridge_audit_events','actor_id,created_at')
),
found AS (
  SELECT c.relname AS tbl, string_agg(a.attname, ',' ORDER BY k.ord) AS cols
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indrelid
    JOIN pg_class ic ON ic.oid = i.indexrelid
    JOIN pg_namespace ns ON ns.oid = c.relnamespace AND ns.nspname = 'public'
    CROSS JOIN LATERAL unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
   WHERE k.ord <= i.indnkeyatts
   GROUP BY c.relname, ic.relname
)
SELECT 'account_indexes_missing', count(*), coalesce(string_agg(e.tbl || '(' || e.cols || ')', ' ' ORDER BY e.tbl, e.cols), '')
  FROM expected e
 WHERE NOT EXISTS (SELECT 1 FROM found f WHERE f.tbl = e.tbl AND f.cols = e.cols);

-- account_role_shape: the role's shape. Every one of these is a way out of the
-- account plane: LOGIN lets it connect, INHERIT lets it pick up another role's
-- privileges, BYPASSRLS ignores the policies, SUPERUSER ignores everything.
SELECT 'account_role_shape', count(*), coalesce(string_agg(v, ' ' ORDER BY v), '')
  FROM (
    SELECT 'role_missing' AS v WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'osionos_account_user')
    UNION ALL SELECT 'login' WHERE (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'osionos_account_user')
    UNION ALL SELECT 'inherit' WHERE (SELECT rolinherit FROM pg_roles WHERE rolname = 'osionos_account_user')
    UNION ALL SELECT 'bypassrls' WHERE (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'osionos_account_user')
    UNION ALL SELECT 'superuser' WHERE (SELECT rolsuper FROM pg_roles WHERE rolname = 'osionos_account_user')
    UNION ALL SELECT 'createdb' WHERE (SELECT rolcreatedb FROM pg_roles WHERE rolname = 'osionos_account_user')
    UNION ALL SELECT 'createrole' WHERE (SELECT rolcreaterole FROM pg_roles WHERE rolname = 'osionos_account_user')
    UNION ALL SELECT 'replication' WHERE (SELECT rolreplication FROM pg_roles WHERE rolname = 'osionos_account_user')
    UNION ALL SELECT 'member_of:' || g.rolname
      FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid
     WHERE m.member = (SELECT oid FROM pg_roles WHERE rolname = 'osionos_account_user')
    UNION ALL SELECT 'has_member:' || u.rolname
      FROM pg_auth_members m JOIN pg_roles u ON u.oid = m.member
     WHERE m.roleid = (SELECT oid FROM pg_roles WHERE rolname = 'osionos_account_user')
       AND u.rolname <> 'authenticator'
    UNION ALL SELECT 'authenticator_cannot_set'
     WHERE CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator')
                 AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'osionos_account_user')
                THEN NOT pg_has_role('authenticator', 'osionos_account_user', 'SET')
                ELSE true END
    UNION ALL SELECT 'authenticator_inherits'
     WHERE CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator')
                 AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'osionos_account_user')
                THEN pg_has_role('authenticator', 'osionos_account_user', 'USAGE')
                ELSE false END
  ) AS violations;

-- account_session_columns: the account role's exact reach on the sessions table.
-- The nine columns and nothing else: a table-level grant would hand over ip_hash,
-- refresh_hash and the user_id of every row, and TRUNCATE ignores RLS entirely.
WITH granted(col) AS (
  SELECT unnest(ARRAY['id','created_at','expires_at','last_seen_at','auth_method',
                       'ip_prefix','user_agent','revoked_at','revoked_reason'])
),
t AS (SELECT to_regclass('public.osionos_sessions') AS oid)
SELECT 'account_session_columns', count(*), coalesce(string_agg(v, ' ' ORDER BY v), '')
  FROM (
    SELECT 'selects:' || a.attname AS v
      FROM t, pg_attribute a
     WHERE t.oid IS NOT NULL AND a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped
       AND has_column_privilege('osionos_account_user', a.attrelid, a.attname, 'SELECT')
       AND a.attname NOT IN (SELECT col FROM granted)
    UNION ALL
    SELECT 'missing:' || g.col
      FROM t, granted g
     WHERE t.oid IS NOT NULL
       AND NOT has_column_privilege('osionos_account_user', t.oid, g.col, 'SELECT')
    UNION ALL
    SELECT 'table_privilege:' || p.priv
      FROM t, unnest(ARRAY['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) AS p(priv)
     WHERE t.oid IS NOT NULL AND has_table_privilege('osionos_account_user', t.oid, p.priv)
    UNION ALL
    SELECT 'column_privilege:' || p.priv
      FROM t, unnest(ARRAY['INSERT','UPDATE','REFERENCES']) AS p(priv)
     WHERE t.oid IS NOT NULL AND has_any_column_privilege('osionos_account_user', t.oid, p.priv)
  ) AS violations;

-- The two isolation rows are LAST: a regressed regex in the uid helper raises
-- 22P02 and blanks every row after it.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
                               ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
INSERT INTO public.osionos_sessions (id, user_id, expires_at, auth_method) VALUES
  ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', now() + interval '1 hour', 'password'),
  ('22222222-2222-2222-2222-222222222222', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', now() + interval '1 hour', 'password');
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
-- account_isolation_own: the account role sees exactly its own rows — one, not two.
SELECT 'account_isolation_own', count(*), 'own rows visible' FROM public.osionos_sessions;
-- account_isolation_forged: the sum of the counts under five forged claim sets
-- (wrong aud, wrong role, malformed sub, array aud, upper-cased sub) and under
-- the valid claims while the session runs as service_role. Must be 0, must raise
-- nothing.
DO $$
DECLARE
  total bigint := 0;
  n bigint;
  claims text;
BEGIN
  FOREACH claims IN ARRAY ARRAY[
    '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"authenticated","role":"osionos_account_user"}',
    '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"authenticated"}',
    '{"sub":"not-a-uuid","aud":"osionos-account","role":"osionos_account_user"}',
    '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":["osionos-account"],"role":"osionos_account_user"}',
    '{"sub":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","aud":"osionos-account","role":"osionos_account_user"}'
  ] LOOP
    PERFORM set_config('request.jwt.claims', claims, true);
    SELECT count(*) INTO n FROM public.osionos_sessions;
    total := total + n;
  END LOOP;
  PERFORM set_config('osionos.check.k6_forged', total::text, true);
END
$$;
RESET ROLE;
SET LOCAL ROLE service_role;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
  PERFORM set_config('osionos.check.k6_svc', (SELECT count(*) FROM public.osionos_sessions WHERE public.osionos_account_uid() IS NOT NULL)::text, true);
END $$;
RESET ROLE;
SELECT 'account_isolation_forged',
       coalesce(current_setting('osionos.check.k6_forged', true), '0')::bigint
     + coalesce(current_setting('osionos.check.k6_svc', true), '0')::bigint,
       'forged claims see no rows';
ROLLBACK;
