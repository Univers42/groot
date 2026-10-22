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
  FROM unnest(ARRAY['osionos_sessions',
                   'osionos_profiles',
                   'osionos_user_settings',
                   'osionos_username_history',
                   'osionos_account_deletion_requests']) AS t
 WHERE to_regclass('public.' || t) IS NULL
    OR coalesce(obj_description(to_regclass('public.' || t), 'pg_class'), '') <> 'osionos:account-plane';

-- account_indexes_missing: the indexes the account plane and today's queries
-- need, compared on what the index IS, not on its key columns alone.
--
-- The old comparison matched the key columns only, so an index on an
-- EXPRESSION was invisible (indkey holds 0 for an expression column, and the
-- join to pg_attribute dropped the row): the lower(username) index could not
-- be seen, and a unique index made plain still passed. The comparison is now
-- on the whole shape:
--   cols     the key columns, with an expression rendered as its expression
--            (pg_get_indexdef(index, n) prints the expression for an
--            expression column and the column name for a plain one)
--   opclass  the access method, except for GIN where the opclass is the point
--            (gin_trgm_ops is a trigram index, text_ops is not)
--   uniq     whether the index is unique
--   pred     the partial predicate, normalised (the outer parentheses the
--            catalog adds are dropped)
-- Caveat: textual — the comparison is on the rendered expression, so an
-- expression that differs only in its text is a different index here.
WITH expected(tbl, cols, opclass, uniq, pred) AS (
  VALUES
    -- P0-1: the foundation's indexes, unchanged.
    ('osionos_bridge_identities',  'email_hash',                  'btree',         false, NULL),
    ('osionos_feed_shares',         'user_id,target,created_at',   'btree',         false, NULL),
    ('osionos_sessions',            'user_id,created_at',           'btree',         false, 'revoked_at is null'),
    ('osionos_sessions',            'revoked_at',                   'btree',         false, 'revoked_at is not null'),
    ('osionos_sessions',            'expires_at',                   'btree',         false, NULL),
    ('osionos_bridge_audit_events', 'actor_id,created_at',          'btree',         false, 'actor_id is not null'),
    -- P1-1: the profiles, the settings, the history, the deletion requests.
    ('osionos_profiles',             'user_id',                     'btree',         true,  NULL),
    ('osionos_profiles',             'lower(username)',             'btree',         true,  NULL),
    ('osionos_profiles',             'display_name,user_id',        'btree',         false, NULL),
    ('osionos_profiles',             'search_doc',                  'tsvector_ops',  false, NULL),
    ('osionos_profiles',             'display_name',                'gin_trgm_ops',  false, NULL),
    ('osionos_profiles',             'username',                    'gin_trgm_ops',  false, NULL),
    ('osionos_profiles',             'headline',                    'gin_trgm_ops',  false, NULL),
    ('osionos_user_settings',        'user_id,section',             'btree',         true,  NULL),
    ('osionos_username_history',     'id',                          'btree',         true,  NULL),
    ('osionos_username_history',     'lower(username),released_at', 'btree',         false, NULL),
    ('osionos_account_deletion_requests', 'user_id',               'btree',         true,  NULL)
),
found AS (
  SELECT c.relname AS tbl,
         lower(regexp_replace(string_agg(pg_get_indexdef(i.indexrelid, k.ord, true), ',' ORDER BY k.ord), '\s+', ' ', 'g')) AS cols,
         lower(CASE WHEN bool_and(am.amname = 'btree') THEN 'btree'
                    ELSE string_agg(o.opcname, ',' ORDER BY k.ord) END) AS opclass,
         i.indisunique AS uniq,
         lower(regexp_replace(regexp_replace(btrim(coalesce(pg_get_expr(i.indpred, i.indrelid), '')), '\s+', ' ', 'g'), '^\((.*)\)$', '\1')) AS pred
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indrelid
    JOIN pg_namespace ns ON ns.oid = c.relnamespace AND ns.nspname = 'public'
    CROSS JOIN LATERAL generate_series(1, i.indnkeyatts) AS k(ord)
    LEFT JOIN LATERAL unnest(i.indclass::oid[]) WITH ORDINALITY AS oc(oid, ord) ON oc.ord = k.ord
    LEFT JOIN pg_opclass o ON o.oid = oc.oid
    LEFT JOIN pg_am am ON am.oid = o.opcmethod
   GROUP BY c.relname, i.indexrelid, i.indisunique
)
SELECT 'account_indexes_missing', count(*), coalesce(string_agg(e.tbl || '(' || e.cols || ')', ' ' ORDER BY e.tbl, e.cols), '')
  FROM expected e
 WHERE NOT EXISTS (SELECT 1 FROM found f
                    WHERE f.tbl = e.tbl
                      AND f.cols = lower(e.cols)
                      AND f.opclass = lower(e.opclass)
                      AND f.uniq = e.uniq
                      AND coalesce(f.pred, '') = coalesce(lower(e.pred), ''));

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

-- p1_role_column_acl: the account role's exact reach on the four P1-1 tables.
-- The column privileges come from information_schema.column_privileges (the
-- column ACLs), the three table-only privileges from has_table_privilege.
-- The set is compared in both directions, so a privilege that is missing AND
-- one that is extra are both a failure.
-- The expected set is the spec's: SELECT on every column of the profiles (they
-- are all public profile fields), UPDATE on the thirteen the user owns, the
-- settings' SELECT/INSERT/UPDATE, the history's SELECT on three columns, and
-- the deletion request's SELECT/INSERT plus the table-level DELETE (a cancel).
-- Caveat: a table-level grant is reported as a table privilege, not as a
-- column one, so the two are kept apart with the '*' column name.
WITH expected(tbl, col, priv) AS (
            SELECT 'osionos_profiles', c, 'SELECT' FROM unnest(ARRAY['user_id','display_name','username','pronouns','headline','bio','location','company','website','links','timezone','orcid','patreon','avatar_url','banner_url','directory_opt_out','version','created_at','updated_at','search_doc']) c
  UNION ALL SELECT 'osionos_profiles', c, 'UPDATE' FROM unnest(ARRAY['display_name','username','pronouns','headline','bio','location','company','website','links','timezone','orcid','patreon','directory_opt_out']) c
  UNION ALL SELECT 'osionos_user_settings', c, 'SELECT' FROM unnest(ARRAY['user_id','section','value','version','updated_at']) c
  UNION ALL SELECT 'osionos_user_settings', c, 'INSERT' FROM unnest(ARRAY['user_id','section','value']) c
  UNION ALL SELECT 'osionos_user_settings', c, 'UPDATE' FROM unnest(ARRAY['user_id','section','value','version','updated_at']) c
  UNION ALL SELECT 'osionos_username_history', c, 'SELECT' FROM unnest(ARRAY['username','changed_at','released_at']) c
  UNION ALL SELECT 'osionos_account_deletion_requests', c, 'SELECT' FROM unnest(ARRAY['user_id','requested_at','scheduled_for','successor_user_id']) c
  UNION ALL SELECT 'osionos_account_deletion_requests', c, 'INSERT' FROM unnest(ARRAY['user_id','successor_user_id']) c
  UNION ALL SELECT 'osionos_account_deletion_requests', '*', 'DELETE'
),
actual AS (
  SELECT table_name, column_name, privilege_type
    FROM information_schema.column_privileges
   WHERE grantee = 'osionos_account_user' AND table_schema = 'public'
     AND table_name IN ('osionos_profiles','osionos_user_settings','osionos_username_history','osionos_account_deletion_requests')
  UNION ALL
  SELECT c.relname, '*', p.priv
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
    CROSS JOIN unnest(ARRAY['DELETE','TRUNCATE','TRIGGER']) AS p(priv)
   WHERE ns.nspname = 'public'
     AND c.relname IN ('osionos_profiles','osionos_user_settings','osionos_username_history','osionos_account_deletion_requests')
     AND has_table_privilege('osionos_account_user', c.oid, p.priv)
)
SELECT 'p1_role_column_acl', count(*),
       coalesce(string_agg(d.tbl || '.' || d.col || ':' || d.priv, ' ' ORDER BY d.tbl, d.col, d.priv), '')
  FROM (
    (SELECT * FROM expected EXCEPT ALL SELECT * FROM actual)
    UNION ALL
    (SELECT * FROM actual EXCEPT ALL SELECT * FROM expected)
  ) AS d;

-- p1_role_writes_profile: the account role, with A's claims, updates A's
-- profile and exactly one row changes.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
                               ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
INSERT INTO public.osionos_profiles (user_id, display_name) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'B');
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  n bigint;
BEGIN
  UPDATE public.osionos_profiles SET display_name = 'x';
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM set_config('osionos.check.p1_write', n::text, true);
END $$;
RESET ROLE;
SELECT 'p1_role_writes_profile', abs(current_setting('osionos.check.p1_write')::bigint - 1),
       'the role changed one row of its own profile';
ROLLBACK;

-- p1_settings_merge: two merges into one section both land, and a null in the
-- second patch deletes the key the first one set. The function is called as the
-- role, never as postgres: as postgres it would key on the session's uid and
-- write nobody's row.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  v_first jsonb;
  v_second jsonb;
BEGIN
  v_first := public.osionos_user_settings_merge('demo', '{"a":1,"b":2}');
  v_second := public.osionos_user_settings_merge('demo', '{"b":null,"c":3}');
  PERFORM set_config('osionos.check.p1_merge', (CASE
      WHEN v_first ->> 'a' = '1' AND v_first ->> 'b' = '2'
       AND v_second ->> 'a' = '1' AND v_second ->> 'b' IS NULL AND v_second ->> 'c' = '3'
      THEN 0 ELSE 1 END)::text, true);
END $$;
RESET ROLE;
SELECT 'p1_settings_merge', current_setting('osionos.check.p1_merge')::bigint,
       'two merges land, a null deletes a key';
ROLLBACK;

-- p1_hold: a name released less than 90 days ago is held by the user who
-- released it. B may not take it; A may reclaim it.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
                               ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
INSERT INTO public.osionos_profiles (user_id, display_name, username) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A', 'heldname'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'B', NULL);
-- A releases the name: the AFTER UPDATE trigger records the hold.
UPDATE public.osionos_profiles SET username = 'releasedname'
 WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  refused boolean := false;
BEGIN
  BEGIN
    UPDATE public.osionos_profiles SET username = 'heldname'
     WHERE user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  EXCEPTION WHEN others THEN
    refused := true;
  END;
  PERFORM set_config('osionos.check.p1_hold_b', refused::text, true);
END $$;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  reclaimed boolean := false;
BEGIN
  BEGIN
    UPDATE public.osionos_profiles SET username = 'heldname'
     WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
    reclaimed := true;
  EXCEPTION WHEN others THEN
    reclaimed := false;
  END;
  PERFORM set_config('osionos.check.p1_hold_a', reclaimed::text, true);
END $$;
RESET ROLE;
SELECT 'p1_hold',
       (CASE WHEN current_setting('osionos.check.p1_hold_b')::boolean THEN 0 ELSE 1 END)
     + (CASE WHEN current_setting('osionos.check.p1_hold_a')::boolean THEN 0 ELSE 1 END),
       'B is refused the held name, A reclaims it';
ROLLBACK;

-- p1_never_raises: nothing the bridge or the gateway does may fail a
-- registration. An insert whose username collides with a profile, an insert
-- with no auth.users row, and the legacy identity write all succeed — and the
-- legacy write reaches the profile.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
                               ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
INSERT INTO public.osionos_profiles (user_id, display_name, username) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A', 'collidename');
INSERT INTO public.osionos_bridge_identities (provider, subject, user_id, email_hash, display_name)
VALUES ('prismatica', '11111111-1111-1111-1111-111111111111',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'p1hash', 'A');
-- The username collides with a profile: the insert must still land, and the
-- profile it creates must have no username.
INSERT INTO public.users (id, email, name, username) VALUES
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'p1-b@example.com', 'B', 'collidename');
-- No auth.users row: the insert must still land, and no profile may exist.
INSERT INTO public.users (id, email, name) VALUES
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'p1-c@example.com', 'C');
SET LOCAL ROLE service_role;
UPDATE public.osionos_bridge_identities SET profile = '{"headline":"legacy headline"}';
RESET ROLE;
SELECT 'p1_never_raises',
       (CASE WHEN EXISTS (SELECT 1 FROM public.users WHERE id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') THEN 0 ELSE 1 END)
     + (CASE WHEN EXISTS (SELECT 1 FROM public.osionos_profiles WHERE user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') THEN 0 ELSE 1 END)
     + (CASE WHEN EXISTS (SELECT 1 FROM public.users WHERE id = 'cccccccc-cccc-cccc-cccc-cccccccccccc') THEN 0 ELSE 1 END)
     + (CASE WHEN EXISTS (SELECT 1 FROM public.osionos_profiles WHERE user_id = 'cccccccc-cccc-cccc-cccc-cccccccccccc') THEN 1 ELSE 0 END)
     + (CASE WHEN EXISTS (SELECT 1 FROM public.osionos_profiles
                           WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                             AND headline = 'legacy headline') THEN 0 ELSE 1 END),
       'the two inserts and the legacy write all succeed';
ROLLBACK;

-- p1_isolation_own and p1_isolation_forged: with A's claims, A sees exactly
-- its own row in each of the four tables, and B's rows are neither readable
-- nor changed — not by an UPDATE, not by the settings merge (which keys on
-- the caller, so it cannot write B's row), and not by the DELETE that cancels
-- a deletion request.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
                               ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
INSERT INTO public.osionos_profiles (user_id, display_name) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'B');
INSERT INTO public.osionos_user_settings (user_id, section, value) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'demo', '{}'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'demo', '{}');
INSERT INTO public.osionos_username_history (user_id, username) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'namea'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'nameb');
INSERT INTO public.osionos_account_deletion_requests (user_id) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
-- How many of the four tables show A exactly one row: four.
DO $$
DECLARE
  n bigint := 0;
BEGIN
  IF (SELECT count(*) FROM public.osionos_profiles) = 1 THEN n := n + 1; END IF;
  IF (SELECT count(*) FROM public.osionos_user_settings) = 1 THEN n := n + 1; END IF;
  IF (SELECT count(*) FROM public.osionos_username_history) = 1 THEN n := n + 1; END IF;
  IF (SELECT count(*) FROM public.osionos_account_deletion_requests) = 1 THEN n := n + 1; END IF;
  PERFORM set_config('osionos.check.p1_own', n::text, true);
END $$;
-- How many of B's rows the role can read: none.
DO $$
DECLARE
  n bigint := 0;
BEGIN
  n := n + (SELECT count(*) FROM public.osionos_profiles WHERE user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
  n := n + (SELECT count(*) FROM public.osionos_user_settings WHERE user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
  n := n + (SELECT count(*) FROM public.osionos_username_history WHERE username = 'nameb');
  n := n + (SELECT count(*) FROM public.osionos_account_deletion_requests WHERE user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
  PERFORM set_config('osionos.check.p1_read', n::text, true);
END $$;
-- The three writes, all as the role: they may only touch A's rows.
UPDATE public.osionos_profiles SET bio = 'x';
DO $$ BEGIN
  PERFORM public.osionos_user_settings_merge('demo', '{"leaked":true}');
END $$;
DELETE FROM public.osionos_account_deletion_requests;
RESET ROLE;
SELECT 'p1_isolation_own', current_setting('osionos.check.p1_own')::bigint,
       'A sees its own row in each of the four tables';
-- B's rows: not readable, not changed by the UPDATE, not changed by the merge,
-- and not deleted by the DELETE.
SELECT 'p1_isolation_forged',
       current_setting('osionos.check.p1_read')::bigint
     + (SELECT count(*) FROM public.osionos_profiles
         WHERE user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' AND bio = 'x')
     + (SELECT count(*) FROM public.osionos_user_settings
         WHERE user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' AND value ? 'leaked')
     + (CASE WHEN EXISTS (SELECT 1 FROM public.osionos_account_deletion_requests
                           WHERE user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') THEN 0 ELSE 1 END),
       'B is neither readable nor changed';
ROLLBACK;

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
