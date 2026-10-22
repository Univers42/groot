-- The account plane's checks (models/osionos-account-foundation-migration.sql, ADR 0028).
--
-- Append-only file of its own: run_checks pipes `cat checks.sql account-checks.sql`
-- into ONE psql, so the output stays a single stream and the two isolation rows
-- stay last. The account role osionos_account_user reaches the tables marked
-- COMMENT ... 'osionos:account-plane' and nothing else.
--
-- Every query returns exactly ONE row of <label>|<count>|<detail>, like checks.sql.

-- account_secdef_exec: SECURITY DEFINER osionos_% functions the account role may
-- execute. The account role is the third role that can hold EXECUTE, and a
-- SECURITY DEFINER function runs with its owner's rights — a grant here would
-- hand the account role the owner's reach (checks.sql's own secdef_exec row
-- covers anon and authenticated only).
SELECT 'account_secdef_exec', count(*), coalesce(string_agg(p.oid::regprocedure::text, ' '), '')
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.prosecdef AND p.proname LIKE 'osionos\_%'
   AND has_function_privilege('osionos_account_user', p.oid, 'EXECUTE');

-- account_role_reach: relations the account role reaches that anon does not
-- reach, and that are not marked as account-plane. anon is the yardstick on
-- purpose: a privilege both roles hold through PUBLIC is not a reach the account
-- role gained.
-- The comparison is PER PRIVILEGE, not per relation: a relation where the
-- account role holds UPDATE and anon holds only SELECT is a reach, and so is a
-- relation where the account role holds TRUNCATE and anon holds nothing.
-- Column privileges are compared for SELECT/INSERT/UPDATE/REFERENCES, table
-- privileges for DELETE/TRUNCATE/TRIGGER (the three that have no column form).
-- Caveat: the column form answers "any column", so a grant on one column of a
-- wide table counts as a reach of that table.
SELECT 'account_role_reach', count(*), coalesce(string_agg(c.relname, ' ' ORDER BY c.relname), '')
  FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
 WHERE ns.nspname NOT IN ('pg_catalog','information_schema')
   AND c.relkind IN ('r','p','v','m','f')
   AND coalesce(obj_description(c.oid, 'pg_class'), '') <> 'osionos:account-plane'
   AND (
     EXISTS (SELECT 1 FROM unnest(ARRAY['SELECT','INSERT','UPDATE','REFERENCES']) AS p(priv)
              WHERE has_any_column_privilege('osionos_account_user', c.oid, p.priv)
                AND NOT has_any_column_privilege('anon', c.oid, p.priv))
     OR EXISTS (SELECT 1 FROM unnest(ARRAY['DELETE','TRUNCATE','TRIGGER']) AS p(priv)
              WHERE has_table_privilege('osionos_account_user', c.oid, p.priv)
                AND NOT has_table_privilege('anon', c.oid, p.priv))
   );

-- account_plane_rls: every marked relation is an ordinary table with RLS on, whose
-- policies name no role but service_role and osionos_account_user (PUBLIC, oid 0,
-- is outside), with at least one policy for the account role, and whose
-- account-role policy filters on the uid helper.
-- The filter is keyed on what the policy does: SELECT and DELETE read rows
-- through polqual, INSERT writes them through polwithcheck, UPDATE and ALL
-- constrain the written row through polwithcheck (falling back to polqual).
-- A single rule for all three would flag a valid INSERT policy — it has no
-- USING clause at all — and would miss an UPDATE policy whose WITH CHECK is
-- wider than its USING.
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
                   AND NOT CASE p.polcmd
                             WHEN 'r' THEN coalesce(pg_get_expr(p.polqual, p.polrelid), '') LIKE '%osionos_account_uid%'
                             WHEN 'd' THEN coalesce(pg_get_expr(p.polqual, p.polrelid), '') LIKE '%osionos_account_uid%'
                             WHEN 'a' THEN coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') LIKE '%osionos_account_uid%'
                             WHEN 'w' THEN coalesce(pg_get_expr(p.polwithcheck, p.polrelid), coalesce(pg_get_expr(p.polqual, p.polrelid), '')) LIKE '%osionos_account_uid%'
                             WHEN '*' THEN coalesce(pg_get_expr(p.polwithcheck, p.polrelid), coalesce(pg_get_expr(p.polqual, p.polrelid), '')) LIKE '%osionos_account_uid%'
                           END)
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
-- A membership the account role holds is a way in as well: it inherits that
-- role's privileges, whoever granted it.
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
-- nothing. The two counts come from custom GUCs: a role switch cannot happen
-- inside one SELECT, so each count is written where the next statement reads
-- it. No coalesce here: an unset GUC is a missing measurement, and a missing
-- measurement must FAIL, not pass as 0.
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
       current_setting('osionos.check.k6_forged', true)::bigint
     + current_setting('osionos.check.k6_svc', true)::bigint,
       'forged claims see no rows';
ROLLBACK;
