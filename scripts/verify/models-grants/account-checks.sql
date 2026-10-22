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
                   'osionos_account_deletion_requests',
                   'osionos_published_pages']) AS t
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

-- p1_sync_changed_only: the legacy sync copies what CHANGED on the identity
-- row, and nothing else. A typed value the user set through the account route
-- must survive an identity write that moved a different field.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.osionos_profiles (user_id, display_name, username, bio) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A', 'syncname', 'typed');
INSERT INTO public.osionos_bridge_identities (provider, subject, user_id, email_hash, display_name, profile)
VALUES ('prismatica', '11111111-1111-1111-1111-111111111111',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'p1sync', 'A', '{"bio":"legacy"}');
-- The identity row's insert copies everything, so the legacy bio is on the
-- profile now; the typed one is what the account route wrote after it.
UPDATE public.osionos_profiles SET bio = 'typed'
 WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
-- An identity write that moves the username alone must not touch the bio.
UPDATE public.osionos_bridge_identities SET username = 'renamed'
 WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DO $$
DECLARE
  v_bio text;
BEGIN
  SELECT bio INTO v_bio FROM public.osionos_profiles
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p1_sync_after_username', coalesce(v_bio, '-'), true);
END $$;
-- An identity write that moves the profile blob copies the blob's fields.
UPDATE public.osionos_bridge_identities SET profile = '{"bio":"legacy2"}'
 WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DO $$
DECLARE
  v_bio text;
BEGIN
  SELECT bio INTO v_bio FROM public.osionos_profiles
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p1_sync_after_profile', coalesce(v_bio, '-'), true);
END $$;
-- The bio is typed again, and the identity write that follows moves another
-- key of the blob (the avatar) and not the bio: the bio keeps the typed
-- value. The avatar package rewrites that key for every user with a data:
-- avatar, so a copy of the whole blob would take the bio back.
UPDATE public.osionos_profiles SET bio = 'typed'
 WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
UPDATE public.osionos_bridge_identities SET profile = jsonb_set(profile, '{avatar}', '"x"')
 WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DO $$
DECLARE
  v_bio text;
BEGIN
  SELECT bio INTO v_bio FROM public.osionos_profiles
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p1_sync_after_avatar', coalesce(v_bio, '-'), true);
END $$;
SELECT 'p1_sync_changed_only',
       (CASE WHEN current_setting('osionos.check.p1_sync_after_username') = 'typed' THEN 0 ELSE 1 END)
     + (CASE WHEN current_setting('osionos.check.p1_sync_after_profile') = 'legacy2' THEN 0 ELSE 1 END)
     + (CASE WHEN current_setting('osionos.check.p1_sync_after_avatar') = 'typed' THEN 0 ELSE 1 END),
       'a username write and an avatar write leave the typed bio, a bio write copies it';
ROLLBACK;

-- p1_noop_no_bump: a write that changes nothing leaves the profile's version
-- where it was. A version that moves on a no-op makes the next If-Match fail
-- for nothing.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.osionos_profiles (user_id, display_name, username) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A', 'noopname');
INSERT INTO public.osionos_bridge_identities (provider, subject, user_id, email_hash, display_name, username)
VALUES ('prismatica', '11111111-1111-1111-1111-111111111111',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'p1noop', 'A', 'noopname');
-- The identity's insert copied the name; the profile's version is what it is.
DO $$
DECLARE
  v_version integer;
BEGIN
  SELECT version INTO v_version FROM public.osionos_profiles
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p1_noop_base', v_version::text, true);
END $$;
-- A write that sets the column to its own value changes nothing.
UPDATE public.osionos_profiles SET username = username
 WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DO $$
DECLARE
  v_version integer;
BEGIN
  SELECT version INTO v_version FROM public.osionos_profiles
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p1_noop_after_same', v_version::text, true);
END $$;
-- An identity write that sets the name to the name the profile already has
-- changes nothing either.
UPDATE public.osionos_bridge_identities SET username = 'noopname'
 WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DO $$
DECLARE
  v_version integer;
BEGIN
  SELECT version INTO v_version FROM public.osionos_profiles
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p1_noop_after_sync', v_version::text, true);
END $$;
-- A real change moves the version by exactly one.
UPDATE public.osionos_profiles SET bio = 'changed'
 WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DO $$
DECLARE
  v_version integer;
BEGIN
  SELECT version INTO v_version FROM public.osionos_profiles
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p1_noop_after_change', v_version::text, true);
END $$;
SELECT 'p1_noop_no_bump',
       (CASE WHEN current_setting('osionos.check.p1_noop_after_same')::integer
                = current_setting('osionos.check.p1_noop_base')::integer THEN 0 ELSE 1 END)
     + (CASE WHEN current_setting('osionos.check.p1_noop_after_sync')::integer
                = current_setting('osionos.check.p1_noop_base')::integer THEN 0 ELSE 1 END)
     + (CASE WHEN current_setting('osionos.check.p1_noop_after_change')::integer
                = current_setting('osionos.check.p1_noop_base')::integer + 1 THEN 0 ELSE 1 END),
       'a no-op leaves the version, a real change moves it by one';
ROLLBACK;

-- p1_deletion_grace: the grace on a deletion request is the server's, not
-- the caller's.
-- (a) The account role may not choose the date: its INSERT grant names only
--     (user_id, successor_user_id), so a scheduled_for column is refused with
--     42501.
-- (b) The account role may not move the date either: it holds no UPDATE
--     grant on the table at all, so the UPDATE is refused with 42501.
-- (c) The executor's path (P5-6, the service role) may write the row, but
--     the grace is a floor: a request that asks for less than 14 days is
--     refused with 23514.
-- (d) A request that names the user as their own successor is refused with
--     23514.
-- Each statement is caught and its SQLSTATE read, so an expectation that is
-- not met is counted instead of aborting the whole check. The role is set
-- again before the second statement: an exception handler's rollback can take
-- the role with it.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
                               ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'),
                               ('cccccccc-cccc-cccc-cccc-cccccccccccc');
INSERT INTO public.osionos_account_deletion_requests (user_id)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
DO $$
DECLARE
  v_state text := '';
BEGIN
  SET LOCAL ROLE osionos_account_user;
  -- The table is created here, by the role: the role owns it, so it can
  -- write its outcome, and the superuser can read it back.
  CREATE TEMP TABLE IF NOT EXISTS p1_grace_out (what text PRIMARY KEY, state text) ON COMMIT DROP;
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
  BEGIN
    INSERT INTO public.osionos_account_deletion_requests (user_id, scheduled_for)
    VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', now());
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  INSERT INTO p1_grace_out VALUES ('insert', v_state);
  v_state := '';
  SET LOCAL ROLE osionos_account_user;
  BEGIN
    UPDATE public.osionos_account_deletion_requests SET scheduled_for = now()
     WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  INSERT INTO p1_grace_out VALUES ('update', v_state);
  RESET ROLE;
END $$;
DO $$
DECLARE
  v_state text := '';
BEGIN
  BEGIN
    INSERT INTO public.osionos_account_deletion_requests (user_id, scheduled_for)
    VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', now());
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  INSERT INTO p1_grace_out VALUES ('floor', v_state);
  v_state := '';
  BEGIN
    INSERT INTO public.osionos_account_deletion_requests (user_id, successor_user_id)
    VALUES ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'cccccccc-cccc-cccc-cccc-cccccccccccc');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  INSERT INTO p1_grace_out VALUES ('successor', v_state);
END $$;
SELECT 'p1_deletion_grace',
       (CASE WHEN (SELECT state FROM p1_grace_out WHERE what = 'insert') = '42501' THEN 0 ELSE 1 END)
     + (CASE WHEN (SELECT state FROM p1_grace_out WHERE what = 'update') = '42501' THEN 0 ELSE 1 END)
     + (CASE WHEN (SELECT state FROM p1_grace_out WHERE what = 'floor') = '23514' THEN 0 ELSE 1 END)
     + (CASE WHEN (SELECT state FROM p1_grace_out WHERE what = 'successor') = '23514' THEN 0 ELSE 1 END),
       'the role cannot set the date, the grace is a floor, the successor is not the user';
ROLLBACK;

-- p1_view_opt_out: the directory view reports the profile's own opt-out, and
-- it keeps the columns the old bridge image selects by name — a dropped or
-- renamed column has to fail the gate.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
                               ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
INSERT INTO public.osionos_profiles (user_id, display_name, directory_opt_out) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A', true),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'B', false);
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_optout text;
BEGIN
  SELECT coalesce(directory_opt_out::text, 'missing') INTO v_optout
    FROM public.osionos_people_directory
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p1_optout_true', v_optout, true);
  SELECT coalesce(directory_opt_out::text, 'missing') INTO v_optout
    FROM public.osionos_people_directory
   WHERE user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  PERFORM set_config('osionos.check.p1_optout_false', v_optout, true);
END $$;
RESET ROLE;
DO $$
DECLARE
  v_cols text;
BEGIN
  SELECT coalesce(string_agg(column_name, ',' ORDER BY ordinal_position), '') INTO v_cols
    FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'osionos_people_directory';
  PERFORM set_config('osionos.check.p1_view_columns', v_cols, true);
END $$;
SELECT 'p1_view_opt_out',
       (CASE WHEN current_setting('osionos.check.p1_optout_true') = 'true' THEN 0 ELSE 1 END)
     + (CASE WHEN current_setting('osionos.check.p1_optout_false') = 'false' THEN 0 ELSE 1 END)
     + (CASE WHEN current_setting('osionos.check.p1_view_columns')
                 = 'user_id,display_name,username,profile,last_seen_at,directory_opt_out,search_doc,headline'
            THEN 0 ELSE 1 END),
       'the view reports the opt-out and keeps the columns the bridge selects';
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

-- p5_published_read: the account role reads its OWN published pages and nothing
-- else. Four facts, one row:
--   (a) with A's claims the role sees exactly A's own published row (1);
--   (b) B's published row is invisible to it (0);
--   (c) the snapshot body is out of reach: SELECT content is refused with
--       42501, because the grant names five columns and content is not one of
--       them;
--   (d) the service role still reads the table — the public GET depends on it.
-- The fixture is the FK chain the table carries: an auth.users row per user, a
-- workspace and a page per published row (osionos_published_pages.page_id ->
-- osionos_pages.id -> osionos_workspaces.id).
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
                               ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES
  ('33333333-3333-3333-3333-333333333333', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'p5 a', 'p5-a'),
  ('44444444-4444-4444-4444-444444444444', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'p5 b', 'p5-b');
INSERT INTO public.osionos_pages (id, workspace_id, owner_id, title) VALUES
  ('55555555-5555-5555-5555-555555555555', '33333333-3333-3333-3333-333333333333', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'p5 a page'),
  ('66666666-6666-6666-6666-666666666666', '44444444-4444-4444-4444-444444444444', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'p5 b page');
INSERT INTO public.osionos_published_pages (token, page_id, owner_id, title, icon, content) VALUES
  ('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', '55555555-5555-5555-5555-555555555555', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'p5 a published', 'doc', '{"blocks":[]}'),
  ('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', '66666666-6666-6666-6666-666666666666', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'p5 b published', 'doc', '{"blocks":[]}');
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
-- (a) and (b): the rows the role may see. B's row is named by its token, not
-- by owner_id: the role holds no privilege on owner_id, so a filter on it
-- would be refused with 42501 instead of answering the question.
-- Every read is caught: a check that raises takes the whole stream with it,
-- and the two isolation rows come after this one.
DO $$
DECLARE
  v_own text := 'err';
  v_other text := 'err';
  v_state text := '';
BEGIN
  BEGIN
    SELECT count(*)::text INTO v_own FROM public.osionos_published_pages;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    v_own := 'err:' || v_state;
  END;
  BEGIN
    SELECT count(*)::text INTO v_other FROM public.osionos_published_pages
     WHERE token = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    v_other := 'err:' || v_state;
  END;
  PERFORM set_config('osionos.check.p5_own', v_own, true);
  PERFORM set_config('osionos.check.p5_other', v_other, true);
END $$;
-- (c) the body is out of reach. The refusal is caught and its SQLSTATE read:
-- an expectation that is not met is counted, not raised.
DO $$
DECLARE
  v_state text := '';
BEGIN
  BEGIN
    PERFORM content FROM public.osionos_published_pages;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p5_content', v_state, true);
END $$;
RESET ROLE;
-- (d) the service role still reads the table: the public GET reads the
-- snapshot as service_role.
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_svc text := 'err';
  v_state text := '';
BEGIN
  BEGIN
    SELECT count(*)::text INTO v_svc FROM public.osionos_published_pages;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    v_svc := 'err:' || v_state;
  END;
  PERFORM set_config('osionos.check.p5_svc', v_svc, true);
END $$;
RESET ROLE;
-- A missing measurement fails: an unset GUC is not a zero.
SELECT 'p5_published_read',
       (CASE WHEN coalesce(current_setting('osionos.check.p5_own', true), '') = '1' THEN 0 ELSE 1 END)
     + (CASE WHEN coalesce(current_setting('osionos.check.p5_other', true), '') = '0' THEN 0 ELSE 1 END)
     + (CASE WHEN coalesce(current_setting('osionos.check.p5_content', true), '') = '42501' THEN 0 ELSE 1 END)
     + (CASE WHEN coalesce(current_setting('osionos.check.p5_svc', true), '') = '2' THEN 0 ELSE 1 END),
       'A sees its own published row, B sees none, the body is refused, the service role reads all';
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
