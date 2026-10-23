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
-- ONE function is exempt, by signature: osionos_account_change_username(text)
-- (models/osionos-account-username-migration.sql). It is the one SECURITY
-- DEFINER function the account role may call, because it re-reads the caller's
-- claims itself (inside a SECURITY DEFINER function current_user is the owner,
-- so the uid helper cannot answer) and writes only the caller's own rows. Any
-- other function still counts.
SELECT 'account_secdef_exec', count(*), coalesce(string_agg(p.oid::regprocedure::text, ' '), '')
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.prosecdef AND p.proname LIKE 'osionos\_%'
   AND has_function_privilege('osionos_account_user', p.oid, 'EXECUTE')
   AND p.oid::regprocedure::text <> 'osionos_account_change_username(text)';

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
                   'osionos_published_pages',
                   'osionos_personal_access_tokens',
                   'osionos_follows',
                   'osionos_presence']) AS t
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
    ('osionos_account_deletion_requests', 'user_id',               'btree',         true,  NULL),
    -- P5-1-a: the personal access tokens. The unique index on the hash is the
    -- lookup a bearer token is resolved with; the owner index is the list.
    ('osionos_personal_access_tokens', 'token_hash',               'btree',         true,  NULL),
    ('osionos_personal_access_tokens', 'user_id,created_at',       'btree',         false, NULL)
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
-- The ten columns and nothing else: a table-level grant would hand over ip_hash,
-- refresh_hash and the user_id of every row, and TRUNCATE ignores RLS entirely.
WITH granted(col) AS (
  SELECT unnest(ARRAY['id','created_at','expires_at','last_seen_at','auth_method',
                       'ip_prefix','user_agent','revoked_at','revoked_reason','family_id'])
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
-- are all public profile fields), UPDATE on the thirteen the user owns — the
-- username is NOT one of them since P1-2s, the settings' SELECT/INSERT/UPDATE,
-- the history's SELECT on three columns, and the deletion request's
-- SELECT/INSERT plus the table-level DELETE (a cancel).
-- Caveat: a table-level grant is reported as a table privilege, not as a
-- column one, so the two are kept apart with the '*' column name.
-- Caveat: a table-level grant on the profiles would be reported by
-- information_schema.column_privileges as a column privilege on EVERY column,
-- so it shows up here as an extra row and not as a missing one.
WITH expected(tbl, col, priv) AS (
            SELECT 'osionos_profiles', c, 'SELECT' FROM unnest(ARRAY['user_id','display_name','username','pronouns','headline','bio','location','company','website','links','timezone','orcid','patreon','avatar_url','banner_url','directory_opt_out','version','created_at','updated_at','search_doc','profession','status_emoji','status_text','status_expires_at','status_busy','readme_page_id']) c
  UNION ALL SELECT 'osionos_profiles', c, 'UPDATE' FROM unnest(ARRAY['display_name','pronouns','headline','bio','location','company','website','links','timezone','orcid','patreon','directory_opt_out','profession','status_emoji','status_text','status_expires_at','status_busy','readme_page_id']) c
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
-- Both calls go through osionos_account_change_username: since P1-2s the role
-- holds no UPDATE grant on the username column, so a direct UPDATE is refused
-- with 42501 — and B's refusal would then pass for the wrong reason. The
-- SQLSTATE is read, not "did it raise": B must be refused with 23505 (the
-- hold), and A must succeed.
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
  v_state text := '';
BEGIN
  BEGIN
    PERFORM public.osionos_account_change_username('heldname');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p1_hold_b', v_state, true);
END $$;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  v_state text := '';
BEGIN
  BEGIN
    PERFORM public.osionos_account_change_username('heldname');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p1_hold_a', v_state, true);
END $$;
RESET ROLE;
SELECT 'p1_hold',
       (CASE WHEN current_setting('osionos.check.p1_hold_b') = '23505' THEN 0 ELSE 1 END)
     + (CASE WHEN current_setting('osionos.check.p1_hold_a') = '' THEN 0 ELSE 1 END),
       'B is refused the held name (23505), A reclaims it';
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

-- The P1-2s checks: the atomic username change
-- (models/osionos-account-username-migration.sql). Every one of them runs as
-- the account role with forged claims, in a transaction that is rolled back.
-- Every sample name is a valid one (^[A-Za-z0-9_][A-Za-z0-9_.-]{2,31}$): a
-- short name is refused as a format error (22023) before any lock is taken,
-- and would prove nothing.

-- p2s_function_config: the function's own settings, pinned. The search_path
-- and the 3 s lock_timeout are the contract's, and nothing else may be set on
-- the function: a call without the lock_timeout holds a PostgREST pool
-- connection for the whole duration of a boot replay.
-- The comparison is on the WHOLE set, so a setting that is removed, added or
-- changed is a failure.
SELECT 'p2s_function_config',
       (CASE WHEN (SELECT array_agg(t.c ORDER BY t.c)
                     FROM pg_proc p CROSS JOIN LATERAL unnest(p.proconfig) AS t(c)
                    WHERE p.oid = to_regprocedure('public.osionos_account_change_username(text)'))
                  = ARRAY['lock_timeout=3s','search_path=pg_catalog, public']::text[]
             THEN 0 ELSE 1 END),
       'the function sets exactly search_path=pg_catalog, public and lock_timeout=3s';

-- p2s_change, p2s_history_once, p2s_version_once and p2s_keeps_typed_fields:
-- one change writes both tables, one history row and one version, and the
-- typed fields survive it.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.osionos_profiles (user_id, display_name, username) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A', 'alice1');
INSERT INTO public.osionos_bridge_identities (provider, subject, user_id, email_hash, display_name, username, profile)
VALUES ('prismatica', '11111111-1111-1111-1111-111111111111',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'p2shash', 'A', 'alice1',
        '{"bio":"legacy-bio","headline":"legacy-head","location":"legacy-loc"}');
-- The identity's insert copied the legacy blob onto the profile; the typed
-- values are what the account route wrote after it.
UPDATE public.osionos_profiles
   SET bio = 'typed-bio', headline = 'typed-head', location = 'typed-loc'
 WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DO $$
DECLARE
  v_version integer;
  v_history bigint;
BEGIN
  SELECT version INTO v_version FROM public.osionos_profiles
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  SELECT count(*) INTO v_history FROM public.osionos_username_history
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p2s_v0', v_version::text, true);
  PERFORM set_config('osionos.check.p2s_h0', v_history::text, true);
END $$;
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  v_state text := '';
BEGIN
  BEGIN
    PERFORM public.osionos_account_change_username('bobby1');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p2s_state', v_state, true);
END $$;
RESET ROLE;
DO $$
DECLARE
  v_version integer;
  v_history bigint;
BEGIN
  SELECT version INTO v_version FROM public.osionos_profiles
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  SELECT count(*) INTO v_history FROM public.osionos_username_history
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p2s_v1', v_version::text, true);
  PERFORM set_config('osionos.check.p2s_h1', v_history::text, true);
END $$;
SELECT 'p2s_change',
       (CASE WHEN current_setting('osionos.check.p2s_state') = ''
              AND (SELECT username FROM public.osionos_profiles
                    WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') = 'bobby1'
              AND (SELECT username FROM public.osionos_bridge_identities
                    WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') = 'bobby1'
              AND (SELECT count(*) FROM public.osionos_username_history
                    WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                      AND username = 'alice1') = 1
              AND current_setting('osionos.check.p2s_v1')::integer
                  - current_setting('osionos.check.p2s_v0')::integer = 1
             THEN 0 ELSE 1 END),
       'both tables say bobby1, one history row holds alice1, the version moved by one';
SELECT 'p2s_history_once',
       (CASE WHEN current_setting('osionos.check.p2s_h1')::bigint
                  - current_setting('osionos.check.p2s_h0')::bigint = 1
             THEN 0 ELSE 1 END),
       'the change wrote exactly one history row, the sync trigger wrote none';
SELECT 'p2s_version_once',
       (CASE WHEN current_setting('osionos.check.p2s_v1')::integer
                  - current_setting('osionos.check.p2s_v0')::integer = 1
             THEN 0 ELSE 1 END),
       'the version moved by exactly one';
SELECT 'p2s_keeps_typed_fields',
       (CASE WHEN (SELECT bio FROM public.osionos_profiles
                    WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') = 'typed-bio'
              AND (SELECT headline FROM public.osionos_profiles
                    WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') = 'typed-head'
              AND (SELECT location FROM public.osionos_profiles
                    WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') = 'typed-loc'
              AND (SELECT bio FROM public.osionos_profiles
                    WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
                  IS DISTINCT FROM (SELECT profile->>'bio' FROM public.osionos_bridge_identities
                                    WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
             THEN 0 ELSE 1 END),
       'the typed bio, headline and location survived the change';
ROLLBACK;

-- p2s_atomic: a name another identity still holds is refused with 23505 (not
-- 22023), and nothing of the caller's moves.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
                                ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
INSERT INTO public.osionos_profiles (user_id, display_name, username) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A', 'alice1');
INSERT INTO public.osionos_bridge_identities (provider, subject, user_id, email_hash, display_name, username) VALUES
  ('prismatica', '11111111-1111-1111-1111-111111111111',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'p2satom', 'A', 'alice1');
-- B's identity holds 'taken1' and B's profile has NO name: the pre-P1-1
-- collision state. The identity row is written BEFORE the profile row, so the
-- sync trigger has no profile to copy the name into.
INSERT INTO public.osionos_bridge_identities (provider, subject, user_id, email_hash, display_name, username) VALUES
  ('prismatica', '22222222-2222-2222-2222-222222222222',
        'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'p2satom2', 'B', 'taken1');
INSERT INTO public.osionos_profiles (user_id, display_name, username) VALUES
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'B', NULL);
DO $$
DECLARE
  v_profile jsonb;
  v_identity jsonb;
  v_history jsonb;
BEGIN
  SELECT to_jsonb(p) INTO v_profile FROM public.osionos_profiles p
   WHERE p.user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  SELECT to_jsonb(i) INTO v_identity FROM public.osionos_bridge_identities i
   WHERE i.user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  SELECT coalesce(jsonb_agg(to_jsonb(h) ORDER BY h.id), '[]'::jsonb) INTO v_history
    FROM public.osionos_username_history h
   WHERE h.user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p2s_atom_p0', coalesce(v_profile::text, '{}'), true);
  PERFORM set_config('osionos.check.p2s_atom_i0', coalesce(v_identity::text, '{}'), true);
  PERFORM set_config('osionos.check.p2s_atom_h0', coalesce(v_history::text, '[]'), true);
END $$;
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  v_state text := '';
BEGIN
  BEGIN
    PERFORM public.osionos_account_change_username('taken1');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p2s_atom_state', v_state, true);
END $$;
RESET ROLE;
DO $$
DECLARE
  v_profile jsonb;
  v_identity jsonb;
  v_history jsonb;
BEGIN
  SELECT to_jsonb(p) INTO v_profile FROM public.osionos_profiles p
   WHERE p.user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  SELECT to_jsonb(i) INTO v_identity FROM public.osionos_bridge_identities i
   WHERE i.user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  SELECT coalesce(jsonb_agg(to_jsonb(h) ORDER BY h.id), '[]'::jsonb) INTO v_history
    FROM public.osionos_username_history h
   WHERE h.user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p2s_atom_p1', coalesce(v_profile::text, '{}'), true);
  PERFORM set_config('osionos.check.p2s_atom_i1', coalesce(v_identity::text, '{}'), true);
  PERFORM set_config('osionos.check.p2s_atom_h1', coalesce(v_history::text, '[]'), true);
END $$;
SELECT 'p2s_atomic',
       (CASE WHEN current_setting('osionos.check.p2s_atom_state') = '23505'
              AND current_setting('osionos.check.p2s_atom_p0') = current_setting('osionos.check.p2s_atom_p1')
              AND current_setting('osionos.check.p2s_atom_i0') = current_setting('osionos.check.p2s_atom_i1')
              AND current_setting('osionos.check.p2s_atom_h0') = current_setting('osionos.check.p2s_atom_h1')
             THEN 0 ELSE 1 END),
       '23505, and the profile row, the identity row and the history rows are identical to before';
ROLLBACK;

-- p2s_taken_by_profile: the name is another user's PROFILE name — no identity
-- holds it and no history row holds it either. It is the pre-P1-1 collision
-- state that p2s_atomic sets up for the identities only.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
                                ('cccccccc-cccc-cccc-cccc-cccccccccccc');
INSERT INTO public.osionos_profiles (user_id, display_name, username) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A', 'alice1');
INSERT INTO public.osionos_bridge_identities (provider, subject, user_id, email_hash, display_name, username) VALUES
  ('prismatica', '11111111-1111-1111-1111-111111111111',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'p2staken', 'A', 'alice1');
-- C's profile holds 'taken2'. C has NO identity row, so no identity holds the
-- name, and the profile row was inserted directly, so no history row holds it
-- either: only the profile's unique index stands in the way.
INSERT INTO public.osionos_profiles (user_id, display_name, username) VALUES
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'C', 'taken2');
DO $$
DECLARE
  v_profile jsonb;
  v_identity jsonb;
  v_history jsonb;
BEGIN
  SELECT to_jsonb(p) INTO v_profile FROM public.osionos_profiles p
   WHERE p.user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  SELECT to_jsonb(i) INTO v_identity FROM public.osionos_bridge_identities i
   WHERE i.user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  SELECT coalesce(jsonb_agg(to_jsonb(h) ORDER BY h.id), '[]'::jsonb) INTO v_history
    FROM public.osionos_username_history h
   WHERE h.user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p2s_taken_p0', coalesce(v_profile::text, '{}'), true);
  PERFORM set_config('osionos.check.p2s_taken_i0', coalesce(v_identity::text, '{}'), true);
  PERFORM set_config('osionos.check.p2s_taken_h0', coalesce(v_history::text, '[]'), true);
END $$;
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  v_state text := '';
BEGIN
  BEGIN
    PERFORM public.osionos_account_change_username('taken2');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p2s_taken_state', v_state, true);
END $$;
RESET ROLE;
DO $$
DECLARE
  v_profile jsonb;
  v_identity jsonb;
  v_history jsonb;
BEGIN
  SELECT to_jsonb(p) INTO v_profile FROM public.osionos_profiles p
   WHERE p.user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  SELECT to_jsonb(i) INTO v_identity FROM public.osionos_bridge_identities i
   WHERE i.user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  SELECT coalesce(jsonb_agg(to_jsonb(h) ORDER BY h.id), '[]'::jsonb) INTO v_history
    FROM public.osionos_username_history h
   WHERE h.user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p2s_taken_p1', coalesce(v_profile::text, '{}'), true);
  PERFORM set_config('osionos.check.p2s_taken_i1', coalesce(v_identity::text, '{}'), true);
  PERFORM set_config('osionos.check.p2s_taken_h1', coalesce(v_history::text, '[]'), true);
END $$;
SELECT 'p2s_taken_by_profile',
       (CASE WHEN current_setting('osionos.check.p2s_taken_state') = '23505'
              AND current_setting('osionos.check.p2s_taken_p0') = current_setting('osionos.check.p2s_taken_p1')
              AND current_setting('osionos.check.p2s_taken_i0') = current_setting('osionos.check.p2s_taken_i1')
              AND current_setting('osionos.check.p2s_taken_h0') = current_setting('osionos.check.p2s_taken_h1')
             THEN 0 ELSE 1 END),
       'the name is held by another profile: 23505, and nothing of the caller moved';
ROLLBACK;

-- p2s_hold: a name A released less than 90 days ago belongs to A. B is
-- refused with 23505, A takes it back.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
                                ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
INSERT INTO public.osionos_profiles (user_id, display_name, username) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A', 'alice1'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'B', 'bobby1');
INSERT INTO public.osionos_bridge_identities (provider, subject, user_id, email_hash, display_name, username) VALUES
  ('prismatica', '11111111-1111-1111-1111-111111111111',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'p2shold', 'A', 'alice1'),
  ('prismatica', '22222222-2222-2222-2222-222222222222',
        'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'p2shold2', 'B', 'bobby1');
-- A releases the name: the history holds it for 90 days.
UPDATE public.osionos_profiles SET username = 'released1'
 WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
UPDATE public.osionos_bridge_identities SET username = 'released1'
 WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  v_state text := '';
BEGIN
  BEGIN
    PERFORM public.osionos_account_change_username('alice1');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p2s_hold_b', v_state, true);
END $$;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  v_state text := '';
BEGIN
  BEGIN
    PERFORM public.osionos_account_change_username('alice1');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p2s_hold_a', v_state, true);
END $$;
RESET ROLE;
SELECT 'p2s_hold',
       (CASE WHEN current_setting('osionos.check.p2s_hold_b') = '23505'
              AND current_setting('osionos.check.p2s_hold_a') = ''
             THEN 0 ELSE 1 END),
       'B cannot take the held name, A takes it back';
ROLLBACK;

-- p2s_invalid: a name that is not usable is refused with 22023, before any
-- lock is taken. 'ab' is too short, 'admin' is reserved, '-x1' starts with a
-- dash, and NULL is no name at all.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.osionos_profiles (user_id, display_name, username) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A', 'alice1');
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  v_names text[] := ARRAY['ab', 'admin', '-x1', NULL];
  v_name text;
  v_state text;
  v_seen integer := 0;
  v_bad integer := 0;
  v_states text := '';
BEGIN
  -- The subscripts, not FOREACH: a NULL element must be visited, and the
  -- fourth name IS the NULL one.
  FOR i IN 1..array_length(v_names, 1) LOOP
    v_seen := v_seen + 1;
    v_name := v_names[i];
    v_state := '';
    BEGIN
      PERFORM public.osionos_account_change_username(v_name);
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    END;
    IF v_state <> '22023' THEN
      v_bad := v_bad + 1;
    END IF;
    v_states := v_states || CASE WHEN v_states = '' THEN '' ELSE '/' END || coalesce(v_state, 'none');
  END LOOP;
  -- A name that was never tried is not a refused name.
  PERFORM set_config('osionos.check.p2s_invalid', (v_bad + abs(4 - v_seen))::text, true);
  PERFORM set_config('osionos.check.p2s_invalid_states', v_states, true);
END $$;
RESET ROLE;
SELECT 'p2s_invalid', current_setting('osionos.check.p2s_invalid')::bigint,
       'ab, admin, -x1 and NULL are all refused with 22023 — measured: '
       || current_setting('osionos.check.p2s_invalid_states');
ROLLBACK;

-- p2s_no_direct: the role may not write the username column itself. The
-- function is the only path.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.osionos_profiles (user_id, display_name, username) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A', 'alice1');
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  v_state text := '';
BEGIN
  BEGIN
    UPDATE public.osionos_profiles SET username = 'zelda1';
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p2s_direct', v_state, true);
END $$;
RESET ROLE;
SELECT 'p2s_no_direct',
       (CASE WHEN current_setting('osionos.check.p2s_direct') = '42501' THEN 0 ELSE 1 END),
       'the role cannot write the username column itself';
ROLLBACK;

-- p2s_no_uid: a caller the token does not identify is refused with 42501 —
-- never with a cast error (22P02). The five claim sets are: none, a wrong
-- aud, an array aud, an upper-case sub and a malformed sub.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.osionos_profiles (user_id, display_name, username) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A', 'alice1');
SET LOCAL ROLE osionos_account_user;
DO $$
DECLARE
  v_claims text[] := ARRAY[
    '',
    '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"other-aud","role":"osionos_account_user"}',
    '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":["osionos-account"],"role":"osionos_account_user"}',
    '{"sub":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","aud":"osionos-account","role":"osionos_account_user"}',
    '{"sub":"not-a-uuid","aud":"osionos-account","role":"osionos_account_user"}',
    '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"authenticated"}'
  ];
  v_claim text;
  v_state text;
  v_bad integer := 0;
  v_states text := '';
BEGIN
  FOR i IN 1..array_length(v_claims, 1) LOOP
    v_claim := v_claims[i];
    PERFORM set_config('request.jwt.claims', v_claim, true);
    v_state := '';
    BEGIN
      PERFORM public.osionos_account_change_username('bobby1');
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    END;
    IF v_state <> '42501' THEN
      v_bad := v_bad + 1;
    END IF;
    v_states := v_states || CASE WHEN v_states = '' THEN '' ELSE '/' END || coalesce(v_state, 'none');
  END LOOP;
  PERFORM set_config('osionos.check.p2s_nouid', v_bad::text, true);
  PERFORM set_config('osionos.check.p2s_nouid_states', v_states, true);
END $$;
RESET ROLE;
SELECT 'p2s_no_uid', current_setting('osionos.check.p2s_nouid')::bigint,
       'no claims, a wrong aud, an array aud, an upper-case sub, a malformed sub and a wrong role are all 42501 — measured: '
       || current_setting('osionos.check.p2s_nouid_states');
ROLLBACK;

-- p2s_case: a case-only rename is a real change. It writes, the version moves
-- by one, and the name it released is held like any other.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
                                ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
INSERT INTO public.osionos_profiles (user_id, display_name, username) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A', 'Bob'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'B', 'bobby1');
INSERT INTO public.osionos_bridge_identities (provider, subject, user_id, email_hash, display_name, username) VALUES
  ('prismatica', '11111111-1111-1111-1111-111111111111',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'p2scase', 'A', 'Bob'),
  ('prismatica', '22222222-2222-2222-2222-222222222222',
        'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'p2scase2', 'B', 'bobby1');
DO $$
DECLARE
  v_version integer;
BEGIN
  SELECT version INTO v_version FROM public.osionos_profiles
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p2s_case_v0', v_version::text, true);
END $$;
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  v_state text := '';
BEGIN
  BEGIN
    PERFORM public.osionos_account_change_username('bob');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p2s_case_a', v_state, true);
END $$;
RESET ROLE;
DO $$
DECLARE
  v_version integer;
BEGIN
  SELECT version INTO v_version FROM public.osionos_profiles
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p2s_case_v1', v_version::text, true);
END $$;
-- B may not take the name A released, and A may take it back.
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  v_state text := '';
BEGIN
  BEGIN
    PERFORM public.osionos_account_change_username('Bob');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p2s_case_b', v_state, true);
END $$;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  v_state text := '';
BEGIN
  BEGIN
    PERFORM public.osionos_account_change_username('Bob');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p2s_case_again', v_state, true);
END $$;
RESET ROLE;
SELECT 'p2s_case',
       (CASE WHEN current_setting('osionos.check.p2s_case_a') = ''
              AND current_setting('osionos.check.p2s_case_v1')::integer
                  - current_setting('osionos.check.p2s_case_v0')::integer = 1
              AND current_setting('osionos.check.p2s_case_b') = '23505'
              AND current_setting('osionos.check.p2s_case_again') = ''
              AND (SELECT username FROM public.osionos_profiles
                    WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') = 'Bob'
             THEN 0 ELSE 1 END),
       'Bob -> bob writes and moves the version by one, B cannot take Bob, A takes it back';
ROLLBACK;

-- p2s_no_identity: a user with a profile and no identities row has no legacy
-- name to keep in step, and can still change their name.
BEGIN;
INSERT INTO auth.users (id) VALUES ('cccccccc-cccc-cccc-cccc-cccccccccccc');
INSERT INTO public.osionos_profiles (user_id, display_name, username) VALUES
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'C', NULL);
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  v_state text := '';
BEGIN
  BEGIN
    PERFORM public.osionos_account_change_username('cname1');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p2s_noident', v_state, true);
END $$;
RESET ROLE;
SELECT 'p2s_no_identity',
       (CASE WHEN current_setting('osionos.check.p2s_noident') = ''
              AND (SELECT username FROM public.osionos_profiles
                    WHERE user_id = 'cccccccc-cccc-cccc-cccc-cccccccccccc') = 'cname1'
             THEN 0 ELSE 1 END),
       'a user with no identities row changes their name';
ROLLBACK;

-- p2s_same_name: the same name is not a change. The call returns the name, the
-- version stays where it was, and no history row is written.
-- The state is built so that both halves can be read from it: the identity row
-- is written BEFORE the profile row, with the drifted name 'alicia1', so the
-- sync trigger has no profile to copy it into. A plain UPDATE of the identity
-- row would fire that trigger, which would copy the name into the profile and
-- write a history row during the setup. The version and the history baseline
-- are taken only after the state is built.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.osionos_bridge_identities (provider, subject, user_id, email_hash, display_name, username) VALUES
  ('prismatica', '11111111-1111-1111-1111-111111111111',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'p2ssame', 'A', 'alicia1');
INSERT INTO public.osionos_profiles (user_id, display_name, username) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A', 'alice1');
DO $$
DECLARE
  v_version integer;
  v_history bigint;
BEGIN
  SELECT version INTO v_version FROM public.osionos_profiles
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  SELECT count(*) INTO v_history FROM public.osionos_username_history
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p2s_same_v0', v_version::text, true);
  PERFORM set_config('osionos.check.p2s_same_h0', v_history::text, true);
END $$;
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  v_state text := '';
BEGIN
  BEGIN
    PERFORM public.osionos_account_change_username('alice1');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p2s_same_drift', v_state, true);
END $$;
RESET ROLE;
DO $$
DECLARE
  v_version integer;
  v_history bigint;
BEGIN
  SELECT version INTO v_version FROM public.osionos_profiles
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  SELECT count(*) INTO v_history FROM public.osionos_username_history
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p2s_same_v1', v_version::text, true);
  PERFORM set_config('osionos.check.p2s_same_h1', v_history::text, true);
END $$;
-- The identity now holds 'alice1' too: the same call again is the same-name
-- case — the profile, the version and the history stay where they are.
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  v_state text := '';
BEGIN
  BEGIN
    PERFORM public.osionos_account_change_username('alice1');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p2s_same_plain', v_state, true);
END $$;
RESET ROLE;
DO $$
DECLARE
  v_version integer;
  v_history bigint;
BEGIN
  SELECT version INTO v_version FROM public.osionos_profiles
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  SELECT count(*) INTO v_history FROM public.osionos_username_history
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p2s_same_v2', v_version::text, true);
  PERFORM set_config('osionos.check.p2s_same_h2', v_history::text, true);
END $$;
SELECT 'p2s_same_name',
       (CASE WHEN current_setting('osionos.check.p2s_same_drift') = ''
              AND current_setting('osionos.check.p2s_same_v1')::integer
                  = current_setting('osionos.check.p2s_same_v0')::integer
              AND current_setting('osionos.check.p2s_same_h1')::bigint
                  = current_setting('osionos.check.p2s_same_h0')::bigint
              AND (SELECT username FROM public.osionos_bridge_identities
                    WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') = 'alice1'
              AND current_setting('osionos.check.p2s_same_plain') = ''
              AND current_setting('osionos.check.p2s_same_v2')::integer
                  = current_setting('osionos.check.p2s_same_v1')::integer
              AND current_setting('osionos.check.p2s_same_h2')::bigint
                  = current_setting('osionos.check.p2s_same_h1')::bigint
             THEN 0 ELSE 1 END),
       'the same name writes nothing, and the drifted identity is brought in step';
ROLLBACK;

-- p2s_no_profile: a user with an identities row and no profile row gets
-- P0002, and the identities row is left exactly as it was.
BEGIN;
INSERT INTO auth.users (id) VALUES ('dddddddd-dddd-dddd-dddd-dddddddddddd');
INSERT INTO public.osionos_bridge_identities (provider, subject, user_id, email_hash, display_name, username) VALUES
  ('prismatica', '33333333-3333-3333-3333-333333333333',
        'dddddddd-dddd-dddd-dddd-dddddddddddd', 'p2snoprof', 'D', 'dname1');
DO $$
DECLARE
  v_identity jsonb;
BEGIN
  SELECT to_jsonb(i) INTO v_identity FROM public.osionos_bridge_identities i
   WHERE i.user_id = 'dddddddd-dddd-dddd-dddd-dddddddddddd';
  PERFORM set_config('osionos.check.p2s_noprof_i0', coalesce(v_identity::text, '{}'), true);
END $$;
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"dddddddd-dddd-dddd-dddd-dddddddddddd","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  v_state text := '';
BEGIN
  BEGIN
    PERFORM public.osionos_account_change_username('dname2');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p2s_noprof_state', v_state, true);
END $$;
RESET ROLE;
DO $$
DECLARE
  v_identity jsonb;
BEGIN
  SELECT to_jsonb(i) INTO v_identity FROM public.osionos_bridge_identities i
   WHERE i.user_id = 'dddddddd-dddd-dddd-dddd-dddddddddddd';
  PERFORM set_config('osionos.check.p2s_noprof_i1', coalesce(v_identity::text, '{}'), true);
END $$;
SELECT 'p2s_no_profile',
       (CASE WHEN current_setting('osionos.check.p2s_noprof_state') = 'P0002'
              AND current_setting('osionos.check.p2s_noprof_i0') = current_setting('osionos.check.p2s_noprof_i1')
              AND NOT EXISTS (SELECT 1 FROM public.osionos_profiles
                               WHERE user_id = 'dddddddd-dddd-dddd-dddd-dddddddddddd')
             THEN 0 ELSE 1 END),
       'P0002, and the identities row is identical to before';
ROLLBACK;

-- p2s_reverse_drift: the identity holds 'alice1' and the profile 'alicia1'.
-- The change repairs the profile: it holds 'alice1', the version moved by one
-- and one history row holds 'alicia1'. The state is built as in p2s_same_name:
-- the identity row is written before the profile row, so the sync trigger
-- never copies a name into a profile that does not exist yet.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.osionos_bridge_identities (provider, subject, user_id, email_hash, display_name, username) VALUES
  ('prismatica', '11111111-1111-1111-1111-111111111111',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'p2srev', 'A', 'alice1');
INSERT INTO public.osionos_profiles (user_id, display_name, username) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A', 'alicia1');
DO $$
DECLARE
  v_version integer;
  v_history bigint;
BEGIN
  SELECT version INTO v_version FROM public.osionos_profiles
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  SELECT count(*) INTO v_history FROM public.osionos_username_history
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p2s_rev_v0', v_version::text, true);
  PERFORM set_config('osionos.check.p2s_rev_h0', v_history::text, true);
END $$;
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  v_state text := '';
BEGIN
  BEGIN
    PERFORM public.osionos_account_change_username('alice1');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p2s_rev_state', v_state, true);
END $$;
RESET ROLE;
DO $$
DECLARE
  v_version integer;
  v_history bigint;
BEGIN
  SELECT version INTO v_version FROM public.osionos_profiles
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  SELECT count(*) INTO v_history FROM public.osionos_username_history
   WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  PERFORM set_config('osionos.check.p2s_rev_v1', v_version::text, true);
  PERFORM set_config('osionos.check.p2s_rev_h1', v_history::text, true);
END $$;
SELECT 'p2s_reverse_drift',
       (CASE WHEN current_setting('osionos.check.p2s_rev_state') = ''
              AND (SELECT username FROM public.osionos_profiles
                    WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') = 'alice1'
              AND current_setting('osionos.check.p2s_rev_v1')::integer
                  - current_setting('osionos.check.p2s_rev_v0')::integer = 1
              AND (SELECT count(*) FROM public.osionos_username_history
                    WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                      AND username = 'alicia1') = 1
              AND current_setting('osionos.check.p2s_rev_h1')::bigint
                  - current_setting('osionos.check.p2s_rev_h0')::bigint = 1
             THEN 0 ELSE 1 END),
       'the profile is repaired, one version, one history row';
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

-- p2_4_profession_check: the profession column's CHECK (P2-4-d1,
-- models/osionos-account-profession-migration.sql). Three facts, one row: a
-- constraint named osionos_profiles_profession_check exists on
-- public.osionos_profiles, it is on the profession column, and its definition
-- names all eight ids.
-- The definition is read as TEXT (the notify_types_missing pattern): a CHECK
-- that is not an IN-list reports every id missing — a false FAIL, never a
-- false pass.
-- A missing table or a missing constraint is a violation, not a zero: a check
-- that reads 0 because it found nothing proves nothing.
WITH c AS (
  SELECT conkey, pg_get_constraintdef(oid) AS def
    FROM pg_constraint
   WHERE conrelid = to_regclass('public.osionos_profiles')
     AND conname = 'osionos_profiles_profession_check'
     AND contype = 'c'
),
ids(id) AS (
  SELECT unnest(ARRAY['student','developer','designer','data-analyst','researcher','creator','founder','teacher'])
)
SELECT 'p2_4_profession_check', count(*), coalesce(string_agg(v, ' ' ORDER BY v), '')
  FROM (
    SELECT 'no_constraint' AS v
      WHERE NOT EXISTS (SELECT 1 FROM c)
    UNION ALL
    SELECT 'not_on_profession'
      WHERE EXISTS (SELECT 1 FROM c)
        AND NOT EXISTS (SELECT 1 FROM c, pg_attribute a
                         WHERE a.attrelid = to_regclass('public.osionos_profiles')
                           AND a.attname = 'profession'
                           AND c.conkey = ARRAY[a.attnum])
    UNION ALL
    SELECT 'missing_id:' || i.id
      FROM ids i
     WHERE EXISTS (SELECT 1 FROM c)
       AND NOT EXISTS (SELECT 1 FROM c WHERE c.def LIKE '%''' || i.id || '''%')
  ) AS violations;

-- p2_1_readme_fk: the README pointer (P2-1-a,
-- models/osionos-account-readme-migration.sql). Two facts: readme_page_id is a
-- UUID column, and a foreign key on exactly that column references
-- public.osionos_pages(id) with ON DELETE SET NULL (confdeltype 'n').
-- A missing column or constraint is a violation, not a zero.
SELECT 'p2_1_readme_fk', count(*), coalesce(string_agg(v, ' ' ORDER BY v), '')
  FROM (
    SELECT 'not_uuid_column' AS v
      WHERE NOT EXISTS (SELECT 1 FROM pg_attribute a
                         WHERE a.attrelid = to_regclass('public.osionos_profiles')
                           AND a.attname = 'readme_page_id' AND NOT a.attisdropped
                           AND a.atttypid = 'uuid'::regtype)
    UNION ALL
    SELECT 'no_set_null_fk_to_pages'
      WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c, pg_attribute a
                         WHERE c.conrelid = to_regclass('public.osionos_profiles')
                           AND c.contype = 'f'
                           AND c.confrelid = to_regclass('public.osionos_pages')
                           AND c.confdeltype = 'n'
                           AND a.attrelid = c.conrelid AND a.attname = 'readme_page_id'
                           AND c.conkey = ARRAY[a.attnum])
  ) AS violations;

-- p23_social_grants (P2-3-root, models/osionos-social-follow-presence-migration.sql):
-- the follow and presence tables and the counts RPC reach exactly who they should.
-- Every violation is one string, so a failure names what is wrong.
SELECT 'p23_social_grants', count(*), coalesce(string_agg(v, ' ' ORDER BY v), '')
  FROM (
    SELECT t || ':missing' AS v
      FROM unnest(ARRAY['osionos_follows','osionos_presence']) AS t
     WHERE to_regclass('public.' || t) IS NULL
    UNION ALL
    SELECT t || ':no_rls'
      FROM unnest(ARRAY['osionos_follows','osionos_presence']) AS t
     WHERE to_regclass('public.' || t) IS NOT NULL
       AND NOT (SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.' || t))
    UNION ALL
    SELECT t || ':' || r || ' reaches it'
      FROM unnest(ARRAY['osionos_follows','osionos_presence']) AS t,
           unnest(ARRAY['anon','authenticated']) AS r
     WHERE to_regclass('public.' || t) IS NOT NULL
       AND (has_any_column_privilege(r, to_regclass('public.' || t), 'SELECT')
         OR has_any_column_privilege(r, to_regclass('public.' || t), 'INSERT')
         OR has_any_column_privilege(r, to_regclass('public.' || t), 'UPDATE')
         OR has_table_privilege(r, to_regclass('public.' || t), 'DELETE'))
    UNION ALL
    SELECT t || ':service_role lacks ' || p
      FROM unnest(ARRAY['osionos_follows','osionos_presence']) AS t,
           unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE']) AS p
     WHERE to_regclass('public.' || t) IS NOT NULL
       AND NOT has_table_privilege('service_role', to_regclass('public.' || t), p)
    UNION ALL
    SELECT 'osionos_follows:account role holds ' || p
      FROM unnest(ARRAY['INSERT','UPDATE','DELETE']) AS p
     WHERE to_regclass('public.osionos_follows') IS NOT NULL
       AND (has_table_privilege('osionos_account_user', to_regclass('public.osionos_follows'), p)
         OR CASE WHEN p = 'DELETE' THEN false
                 ELSE has_any_column_privilege('osionos_account_user', to_regclass('public.osionos_follows'), p) END)
    UNION ALL
    SELECT 'osionos_presence:account role holds ' || p
      FROM unnest(ARRAY['INSERT','DELETE']) AS p
     WHERE to_regclass('public.osionos_presence') IS NOT NULL
       AND (has_table_privilege('osionos_account_user', to_regclass('public.osionos_presence'), p)
         OR CASE WHEN p = 'DELETE' THEN false
                 ELSE has_any_column_privilege('osionos_account_user', to_regclass('public.osionos_presence'), p) END)
    UNION ALL
    SELECT 'osionos_follow_counts:' || r || ' may execute'
      FROM unnest(ARRAY['anon','authenticated','osionos_account_user']) AS r
     WHERE to_regprocedure('public.osionos_follow_counts(uuid,uuid)') IS NOT NULL
       AND has_function_privilege(r, to_regprocedure('public.osionos_follow_counts(uuid,uuid)'), 'EXECUTE')
    UNION ALL
    SELECT 'osionos_follow_counts:' || CASE WHEN p.oid IS NULL THEN 'missing'
                                            WHEN NOT has_function_privilege('service_role', p.oid, 'EXECUTE') THEN 'service_role cannot execute'
                                            WHEN p.prosecdef THEN 'is SECURITY DEFINER' END
      FROM (SELECT 1) AS one
      LEFT JOIN pg_proc p ON p.oid = to_regprocedure('public.osionos_follow_counts(uuid,uuid)')
     WHERE p.oid IS NULL OR p.prosecdef OR NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
  ) AS violations;

-- p23_presence_state: a row created with no state is 'online'; a fifth state and
-- a 121-character text are refused with 23514 (the CHECKs, not the bridge).
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
                               ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
DO $$
DECLARE
  v_bad int := 0;
  v_state text;
BEGIN
  INSERT INTO public.osionos_presence (user_id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  SELECT state INTO v_state FROM public.osionos_presence WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  IF v_state IS DISTINCT FROM 'online' THEN v_bad := v_bad + 1; END IF;
  BEGIN
    INSERT INTO public.osionos_presence (user_id, state) VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'busy');
    v_bad := v_bad + 1;
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.osionos_presence (user_id, state, custom_text)
      VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'dnd', repeat('x', 121));
    v_bad := v_bad + 1;
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.osionos_presence (user_id, state, custom_text)
      VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'invisible', repeat('x', 120));
  EXCEPTION WHEN others THEN v_bad := v_bad + 1;
  END;
  PERFORM set_config('osionos.check.p23_presence', v_bad::text, true);
END $$;
SELECT 'p23_presence_state', current_setting('osionos.check.p23_presence')::bigint,
       'default online, unknown state and 121 chars refused, 120 chars kept';
ROLLBACK;

-- p23_status_columns: the limits hold, busy defaults to false, and the account
-- role changes its own status and one row only.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
                               ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
INSERT INTO public.osionos_profiles (user_id, display_name) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'B');
DO $$
DECLARE
  v_bad int := 0;
  v_busy boolean;
BEGIN
  SELECT status_busy INTO v_busy FROM public.osionos_profiles WHERE user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  IF v_busy IS DISTINCT FROM false THEN v_bad := v_bad + 1; END IF;
  BEGIN
    UPDATE public.osionos_profiles SET status_emoji = repeat('x', 9);
    v_bad := v_bad + 1;
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.osionos_profiles SET status_text = repeat('x', 121);
    v_bad := v_bad + 1;
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  PERFORM set_config('osionos.check.p23_status_limits', v_bad::text, true);
END $$;
SET LOCAL ROLE osionos_account_user;
DO $$ BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
END $$;
DO $$
DECLARE
  n bigint;
BEGIN
  UPDATE public.osionos_profiles SET status_emoji = 'x', status_text = 'focus', status_busy = true,
         status_expires_at = now() + interval '1 hour';
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM set_config('osionos.check.p23_status_rows', n::text, true);
END $$;
RESET ROLE;
SELECT 'p23_status_columns',
       current_setting('osionos.check.p23_status_limits')::bigint
     + abs(current_setting('osionos.check.p23_status_rows')::bigint - 1),
       'limits hold, busy defaults to false, the role changed one row of its own';
ROLLBACK;

-- p23_block_trigger: a block in EITHER direction refuses the follow with 23514
-- and the message follow_blocked; an unblocked follow, and the same follow twice
-- under ON CONFLICT DO NOTHING, go through. Run as service_role, the bridge's role.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
                               ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'),
                               ('cccccccc-cccc-cccc-cccc-cccccccccccc');
INSERT INTO public.osionos_user_blocks (blocker_id, blocked_id) VALUES
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'cccccccc-cccc-cccc-cccc-cccccccccccc');
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_bad int := 0;
  v_pair text[];
  v_state text;
  v_msg text;
BEGIN
  -- B blocked A: A -> B is refused. A blocked C: C -> A, and A -> C, are refused.
  FOREACH v_pair SLICE 1 IN ARRAY ARRAY[
    ['aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'],
    ['bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'],
    ['cccccccc-cccc-cccc-cccc-cccccccccccc','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'],
    ['aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','cccccccc-cccc-cccc-cccc-cccccccccccc']
  ] LOOP
    BEGIN
      INSERT INTO public.osionos_follows (follower_id, followee_id) VALUES (v_pair[1]::uuid, v_pair[2]::uuid);
      v_bad := v_bad + 1;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      IF v_state <> '23514' OR v_msg <> 'follow_blocked' THEN v_bad := v_bad + 1; END IF;
    END;
  END LOOP;
  BEGIN
    INSERT INTO public.osionos_follows (follower_id, followee_id)
      VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'cccccccc-cccc-cccc-cccc-cccccccccccc')
      ON CONFLICT DO NOTHING;
    INSERT INTO public.osionos_follows (follower_id, followee_id)
      VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'cccccccc-cccc-cccc-cccc-cccccccccccc')
      ON CONFLICT DO NOTHING;
  EXCEPTION WHEN others THEN v_bad := v_bad + 1;
  END;
  PERFORM set_config('osionos.check.p23_trigger', v_bad::text, true);
END $$;
RESET ROLE;
SELECT 'p23_block_trigger', current_setting('osionos.check.p23_trigger')::bigint,
       'four blocked follows refused with 23514 follow_blocked, an unblocked one kept';
ROLLBACK;

-- p23_counts_rpc: one row per call, the right three values, and one row of
-- zeros and false for a user nobody follows.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
                               ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'),
                               ('cccccccc-cccc-cccc-cccc-cccccccccccc');
INSERT INTO public.osionos_follows (follower_id, followee_id) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'cccccccc-cccc-cccc-cccc-cccccccccccc');
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_bad int := 0;
  v_rows int;
  r record;
BEGIN
  SELECT count(*) INTO v_rows FROM public.osionos_follow_counts('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  IF v_rows <> 1 THEN v_bad := v_bad + 1; END IF;
  SELECT * INTO r FROM public.osionos_follow_counts('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  IF r.follower_count <> 2 OR r.following_count <> 1 OR r.viewer_follows IS NOT TRUE THEN v_bad := v_bad + 1; END IF;
  SELECT * INTO r FROM public.osionos_follow_counts('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
  IF r.follower_count <> 0 OR r.following_count <> 1 OR r.viewer_follows IS NOT FALSE THEN v_bad := v_bad + 1; END IF;
  SELECT count(*) INTO v_rows FROM public.osionos_follow_counts(gen_random_uuid(), gen_random_uuid());
  IF v_rows <> 1 THEN v_bad := v_bad + 1; END IF;
  PERFORM set_config('osionos.check.p23_counts', v_bad::text, true);
END $$;
RESET ROLE;
SELECT 'p23_counts_rpc', current_setting('osionos.check.p23_counts')::bigint,
       'one row per call; followers, following and viewer_follows are right';
ROLLBACK;

-- p23_counts_plan: the three statements inside osionos_follow_counts() on 100K
-- edges use an index, never a sequential scan of osionos_follows. The statements
-- are written out here because EXPLAIN of a function call shows no inner plan.
-- Caveat: this copy of the function body can drift from the function; the row
-- p23_counts_rpc pins the function's answers, not its plan. And it is the
-- planner's choice on THIS data shape (10K users, 100K edges, one user with
-- about 200 followers): a different shape may legitimately pick another plan.
BEGIN;
CREATE TEMP TABLE p23_users ON COMMIT DROP AS
  SELECT n, gen_random_uuid() AS id FROM generate_series(1, 10000) AS n;
INSERT INTO auth.users (id) SELECT id FROM p23_users;
INSERT INTO public.osionos_follows (follower_id, followee_id)
  SELECT f.id, t.id
    FROM p23_users f
    CROSS JOIN generate_series(1, 10) AS g
    JOIN p23_users t ON t.n = ((f.n + g - 1) % 10000) + 1
   WHERE f.n <> t.n
  ON CONFLICT DO NOTHING;
INSERT INTO public.osionos_follows (follower_id, followee_id)
  SELECT f.id, (SELECT id FROM p23_users WHERE n = 1)
    FROM p23_users f WHERE f.n BETWEEN 5000 AND 5200
  ON CONFLICT DO NOTHING;
ANALYZE public.osionos_follows;
DO $$
DECLARE
  v_user uuid := (SELECT id FROM p23_users WHERE n = 1);
  v_viewer uuid := (SELECT id FROM p23_users WHERE n = 5000);
  v_stmt text;
  v_line text;
  v_seq int := 0;
  v_idx int := 0;
BEGIN
  FOREACH v_stmt IN ARRAY ARRAY[
    format('SELECT count(*) FROM public.osionos_follows WHERE followee_id = %L', v_user),
    format('SELECT count(*) FROM public.osionos_follows WHERE follower_id = %L', v_user),
    format('SELECT 1 FROM public.osionos_follows WHERE follower_id = %L AND followee_id = %L', v_viewer, v_user)
  ] LOOP
    FOR v_line IN EXECUTE 'EXPLAIN ' || v_stmt LOOP
      IF v_line LIKE '%Seq Scan on osionos_follows%' THEN v_seq := v_seq + 1; END IF;
      IF v_line LIKE '%Index%Scan%osionos_follows%' THEN v_idx := v_idx + 1; END IF;
    END LOOP;
  END LOOP;
  PERFORM set_config('osionos.check.p23_plan', (v_seq + CASE WHEN v_idx >= 3 THEN 0 ELSE 1 END)::text, true);
END $$;
SELECT 'p23_counts_plan', current_setting('osionos.check.p23_plan')::bigint,
       'no sequential scan of osionos_follows, an index scan for each of the three statements';
ROLLBACK;

-- p32_mfa_secrets (P3-2 root, models/osionos-mfa-migration.sql): the TOTP seed and
-- the recovery-code HMACs reach service_role and nobody else. Whoever reads either
-- passes the second factor. Every violation is one string, so a failure names it.
-- Caveat: the privilege rows read the catalog; the p32_mfa_secrets_read row below
-- actually runs a SELECT under each role, which is the proof that matters.
SELECT 'p32_mfa_secrets', count(*), coalesce(string_agg(v, ' ' ORDER BY v), '')
  FROM (
    SELECT t || ':missing' AS v
      FROM unnest(ARRAY['osionos_mfa_totp','osionos_mfa_recovery_codes']) AS t
     WHERE to_regclass('public.' || t) IS NULL
    UNION ALL
    SELECT t || ':no_rls'
      FROM unnest(ARRAY['osionos_mfa_totp','osionos_mfa_recovery_codes']) AS t
     WHERE to_regclass('public.' || t) IS NOT NULL
       AND NOT (SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.' || t))
    UNION ALL
    SELECT t || ':' || r || ' holds ' || p
      FROM unnest(ARRAY['osionos_mfa_totp','osionos_mfa_recovery_codes']) AS t,
           unnest(ARRAY['anon','authenticated','osionos_account_user']) AS r,
           unnest(ARRAY['SELECT','INSERT','UPDATE','REFERENCES']) AS p
     WHERE to_regclass('public.' || t) IS NOT NULL
       AND (has_table_privilege(r, to_regclass('public.' || t), p)
         OR has_any_column_privilege(r, to_regclass('public.' || t), p))
    UNION ALL
    SELECT t || ':' || r || ' holds ' || p
      FROM unnest(ARRAY['osionos_mfa_totp','osionos_mfa_recovery_codes']) AS t,
           unnest(ARRAY['anon','authenticated','osionos_account_user']) AS r,
           unnest(ARRAY['DELETE','TRUNCATE','TRIGGER']) AS p
     WHERE to_regclass('public.' || t) IS NOT NULL
       AND has_table_privilege(r, to_regclass('public.' || t), p)
    UNION ALL
    SELECT t || ':service_role lacks ' || p
      FROM unnest(ARRAY['osionos_mfa_totp','osionos_mfa_recovery_codes']) AS t,
           unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE']) AS p
     WHERE to_regclass('public.' || t) IS NOT NULL
       AND NOT has_table_privilege('service_role', to_regclass('public.' || t), p)
    UNION ALL
    SELECT c.relname || ':policy ' || pol.polname || ' names a role besides service_role'
      FROM pg_policy pol JOIN pg_class c ON c.oid = pol.polrelid
     WHERE c.relnamespace = 'public'::regnamespace
       AND c.relname IN ('osionos_mfa_totp','osionos_mfa_recovery_codes')
       AND (pol.polroles = '{0}'::oid[]
            OR EXISTS (SELECT 1 FROM unnest(pol.polroles) AS x(oid)
                        WHERE x.oid <> (SELECT oid FROM pg_roles WHERE rolname = 'service_role')))
    UNION ALL
    SELECT t || ':carries the account-plane comment'
      FROM unnest(ARRAY['osionos_mfa_totp','osionos_mfa_recovery_codes']) AS t
     WHERE to_regclass('public.' || t) IS NOT NULL
       AND coalesce(obj_description(to_regclass('public.' || t), 'pg_class'), '') = 'osionos:account-plane'
    UNION ALL
    SELECT c.relname || ':realtime trigger armed'
      FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid
     WHERE c.relnamespace = 'public'::regnamespace
       AND c.relname IN ('osionos_mfa_totp','osionos_mfa_recovery_codes')
       AND NOT tg.tgisinternal AND tg.tgfoid = to_regproc('public.realtime_notify')
    UNION ALL
    SELECT 'osionos_mfa_recovery_codes:column ' || col || ' missing'
      FROM unnest(ARRAY['code_hmac','generation','used_at']) AS col
     WHERE to_regclass('public.osionos_mfa_recovery_codes') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_attribute a
                        WHERE a.attrelid = to_regclass('public.osionos_mfa_recovery_codes')
                          AND a.attname = col AND NOT a.attisdropped)
    UNION ALL
    SELECT 'osionos_mfa_recovery_codes:no unique (user_id, code_hmac)'
     WHERE to_regclass('public.osionos_mfa_recovery_codes') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_index i
                        WHERE i.indrelid = to_regclass('public.osionos_mfa_recovery_codes')
                          AND i.indisunique AND i.indnatts = 2
                          AND (SELECT string_agg(a.attname, ',' ORDER BY a.attname)
                                 FROM pg_attribute a
                                WHERE a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)) = 'code_hmac,user_id')
    UNION ALL
    SELECT 'osionos_mfa_recovery_codes:no index (user_id, used_at)'
     WHERE to_regclass('public.osionos_mfa_recovery_codes') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_indexes
                        WHERE schemaname = 'public' AND tablename = 'osionos_mfa_recovery_codes'
                          AND indexdef LIKE '%(user_id, used_at)%')
  ) AS violations;

-- p32_mfa_secrets_read: a real SELECT of each secret column under each role that
-- must not read it. Counts the reads that SUCCEEDED (must be 0); a role switch
-- cannot happen inside one SELECT, so the DO block switches per attempt. No
-- coalesce on the GUC: an unset one is a missing measurement and must FAIL.
BEGIN;
DO $$
DECLARE
  r text;
  stmt text;
  leaked bigint := 0;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon','authenticated','osionos_account_user'] LOOP
    FOREACH stmt IN ARRAY ARRAY[
      'SELECT secret_enc FROM public.osionos_mfa_totp',
      'SELECT count(*) FROM public.osionos_mfa_totp',
      'SELECT code_hmac FROM public.osionos_mfa_recovery_codes',
      'SELECT count(*) FROM public.osionos_mfa_recovery_codes'
    ] LOOP
      BEGIN
        EXECUTE format('SET LOCAL ROLE %I', r);
        EXECUTE stmt;
        leaked := leaked + 1;
      EXCEPTION WHEN insufficient_privilege THEN
        NULL;
      END;
      RESET ROLE;
    END LOOP;
  END LOOP;
  PERFORM set_config('osionos.check.p32_read', leaked::text, true);
END
$$;
SELECT 'p32_mfa_secrets_read', current_setting('osionos.check.p32_read')::bigint,
       'statements that read a secret table under anon, authenticated or the account role';
ROLLBACK;

-- ===== P5-6-a: account data map, erase function, export jobs =====
CREATE OR REPLACE FUNCTION pg_temp.p5_literal(p_rel regclass, p_col text) RETURNS text
LANGUAGE sql AS $$
  SELECT (regexp_match(pg_get_constraintdef(c.oid), '''([^'']*)''::'))[1]
    FROM pg_constraint c
   WHERE c.conrelid = p_rel AND c.contype = 'c'
     AND pg_get_constraintdef(c.oid) ~ ('\(\(?' || p_col || ' (= ANY|IN|= .)|\(' || p_col || '\)::text = ANY')
   LIMIT 1
$$;

CREATE TEMP TABLE IF NOT EXISTS p5_seeded (user_id uuid, table_name text, ok boolean, err text);

-- Inserts one row into p_table. p_col is set to p_val (a SQL literal or expression);
-- every other registry column gets a random value, so only p_col can hold the user.
-- Single-column foreign keys get their parent row made first (depth-limited), because
-- PostgreSQL re-checks a foreign key on UPDATE for a row created in the same
-- transaction, and the erase UPDATEs (anonymise, transfer) would trip over a dangling one.
CREATE OR REPLACE FUNCTION pg_temp.p5_insert(p_table text, p_col text, p_val text, p_depth int DEFAULT 0, p_col2 text DEFAULT NULL, p_val2 text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  a record; fk record;
  v_rel regclass := to_regclass('public.' || quote_ident(p_table));
  v_cols text := ''; v_vals text := ''; v_val text; v_typ text; v_iscol boolean; v_force text;
  v_lit text; v_have boolean; v_parent_col text; v_parent text;
BEGIN
  IF p_table = 'users' AND EXISTS (SELECT 1 FROM public.users WHERE id::text = btrim(p_val, '''::uuid')) THEN RETURN; END IF;
  FOR a IN SELECT at.attname, at.attnum, format_type(at.atttypid, at.atttypmod) typ, at.attnotnull, at.atthasdef, at.attidentity, at.attgenerated
             FROM pg_attribute at WHERE at.attrelid = v_rel AND at.attnum > 0 AND NOT at.attisdropped ORDER BY at.attnum LOOP
    CONTINUE WHEN a.attidentity <> '' OR a.attgenerated <> '';
    v_iscol := EXISTS (SELECT 1 FROM public.osionos_account_data_map m WHERE m.table_name = p_table AND m.column_name = a.attname);
    v_force := CASE p_table || '.' || a.attname
      WHEN 'osionos_personal_access_tokens.scopes' THEN '''{read}''::text[]'
      WHEN 'ai_access_tokens.scopes' THEN '''{read}''::text[]'
      WHEN 'ai_access_tokens.workspace_ids' THEN 'ARRAY[gen_random_uuid()]'
      WHEN 'osionos_account_deletion_requests.successor_user_id' THEN 'NULL'
      WHEN 'osionos_mfa_totp.status' THEN '''pending'''
      WHEN 'ai_runs.conversation_id' THEN 'gen_random_uuid()'
      WHEN 'ai_approvals.origin' THEN '''run'''
      WHEN 'ai_approvals.run_id' THEN 'gen_random_uuid()'
      WHEN 'ai_approvals.conversation_id' THEN 'gen_random_uuid()'
      ELSE NULL END;
    CONTINUE WHEN v_force IS NULL AND NOT v_iscol AND a.attname <> p_col AND a.attname IS DISTINCT FROM p_col2 AND (a.atthasdef OR NOT a.attnotnull);
    v_typ := a.typ;
    IF a.attname = p_col THEN v_val := p_val;
    ELSIF a.attname = p_col2 THEN v_val := p_val2;
    ELSIF v_force IS NOT NULL THEN v_val := v_force;
    ELSIF v_typ = 'uuid' THEN v_val := 'gen_random_uuid()';
    ELSIF v_typ = 'text' AND (a.attname LIKE '%sha256' OR a.attname LIKE '%hmac' OR a.attname = 'token_hash') THEN v_val := 'md5(random()::text)||md5(random()::text)';
    ELSIF a.attname = 'last4' THEN v_val := '''abcd''';
    ELSIF v_typ LIKE 'vector(%' THEN v_val := format('(''[''||repeat(''0,'', %s)||''0]'')::%s', substring(v_typ from '\d+')::int - 1, v_typ);
    ELSIF a.attname LIKE 'expires%' AND v_typ LIKE 'timestamp%' THEN v_val := 'now() + interval ''1 day''';
    ELSIF v_typ = 'text' OR v_typ LIKE 'character%' THEN
      v_val := coalesce(quote_literal(pg_temp.p5_literal(v_rel, a.attname)), format('left(%L || gen_random_uuid()::text, 20)', 'p5'));
    ELSIF v_typ = 'jsonb' THEN v_val := '''{}''::jsonb';
    ELSIF v_typ LIKE 'timestamp%' THEN v_val := 'now()';
    ELSIF v_typ IN ('integer', 'bigint', 'smallint', 'numeric', 'double precision', 'real') THEN v_val := '1';
    ELSIF v_typ = 'boolean' THEN v_val := 'false';
    ELSIF v_typ = 'date' THEN v_val := 'current_date';
    ELSIF v_typ = 'bytea' THEN v_val := '''\x00''::bytea';
    ELSIF v_typ LIKE '%[]' THEN v_val := format('''{}''::%s', v_typ);
    ELSE v_val := 'NULL';
    END IF;
    -- A single-column foreign key: pin the value to a literal so the parent can be made for it.
    SELECT c.confrelid::regclass::text, (SELECT pa.attname FROM pg_attribute pa WHERE pa.attrelid = c.confrelid AND pa.attnum = c.confkey[1])
      INTO v_parent, v_parent_col
      FROM pg_constraint c
     WHERE c.conrelid = v_rel AND c.contype = 'f' AND array_length(c.conkey, 1) = 1 AND c.conkey[1] = a.attnum LIMIT 1;
    IF v_parent IS NOT NULL AND v_val <> 'NULL' THEN
      EXECUTE format('SELECT (%s)::text', v_val) INTO v_lit;
      v_val := quote_literal(v_lit) || '::' || v_typ;
      IF p_depth < 4 THEN
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s WHERE %I::text = %L)', v_parent, v_parent_col, v_lit) INTO v_have;
        IF NOT v_have THEN
          IF v_parent = 'auth.users' THEN
            INSERT INTO auth.users (id) VALUES (v_lit::uuid) ON CONFLICT DO NOTHING;
          ELSIF v_parent LIKE 'public.%' OR position('.' in v_parent) = 0 THEN
            PERFORM pg_temp.p5_insert(regexp_replace(v_parent, '^public\.', ''), v_parent_col, quote_literal(v_lit) || '::' ||
              (SELECT format_type(pa.atttypid, pa.atttypmod) FROM pg_attribute pa WHERE pa.attrelid = v_parent::regclass AND pa.attname = v_parent_col), p_depth + 1);
          END IF;
        END IF;
      END IF;
    END IF;
    v_cols := v_cols || CASE WHEN v_cols = '' THEN '' ELSE ',' END || quote_ident(a.attname);
    v_vals := v_vals || CASE WHEN v_vals = '' THEN '' ELSE ',' END || v_val;
  END LOOP;
  EXECUTE format('INSERT INTO public.%I (%s) VALUES (%s)', p_table, v_cols, v_vals);
END
$$;

-- A row's (owner_id, db_key) is a composite foreign key to its database: make both.
CREATE OR REPLACE FUNCTION pg_temp.p5_insert_db_row(p_col text, p_val text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_owner text; v_key text := 'p5db' || substr(md5(random()::text), 1, 12);
BEGIN
  v_owner := CASE WHEN p_col = 'owner_id' THEN p_val ELSE quote_literal(gen_random_uuid()::text) || '::uuid' END;
  PERFORM pg_temp.p5_insert('osionos_object_databases', 'owner_id', v_owner, 1, 'db_key', quote_literal(v_key));
  IF p_col = 'owner_id' THEN
    PERFORM pg_temp.p5_insert('osionos_object_database_rows', 'owner_id', v_owner, 1, 'db_key', quote_literal(v_key));
  ELSE
    PERFORM pg_temp.p5_insert('osionos_object_database_rows', p_col, p_val, 1, 'db_key', quote_literal(v_key));
    -- the other column is a random owner: pin it to the database's
    EXECUTE format('UPDATE public.osionos_object_database_rows SET owner_id = %s WHERE db_key = %L', v_owner, v_key);
  END IF;
END
$$;

-- Seeds one row per registry column of every registry table, holding p_user in that column only.
CREATE OR REPLACE FUNCTION pg_temp.p5_seed_user(p_user uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  rc record; v_typ text; v_val text;
BEGIN
  PERFORM set_config('session_replication_role', 'replica', true);
  INSERT INTO auth.users (id) VALUES (p_user) ON CONFLICT DO NOTHING;
  FOR rc IN SELECT m.table_name, m.column_name FROM public.osionos_account_data_map m ORDER BY 1, 2 LOOP
    -- A successor column needs a real second user; the checks seed that row themselves.
    CONTINUE WHEN rc.table_name = 'osionos_account_deletion_requests' AND rc.column_name = 'successor_user_id';
    BEGIN
      SELECT format_type(a.atttypid, a.atttypmod) INTO v_typ FROM pg_attribute a
       WHERE a.attrelid = to_regclass('public.' || quote_ident(rc.table_name)) AND a.attname = rc.column_name;
      v_val := CASE WHEN v_typ = 'uuid' THEN quote_literal(p_user::text) || '::uuid'
                    WHEN v_typ = 'jsonb' THEN CASE WHEN rc.column_name = 'collaborators' THEN format('jsonb_build_array(%L::text)', p_user::text)
                                                   ELSE format('jsonb_build_object(''type'', ''user'', ''user'', %L::text)', p_user::text) END
                    WHEN v_typ = 'uuid[]' THEN format('ARRAY[%L::uuid]', p_user::text)
                    ELSE quote_literal(p_user::text) END;
      IF rc.table_name = 'osionos_object_database_rows' THEN PERFORM pg_temp.p5_insert_db_row(rc.column_name, v_val);
      ELSE PERFORM pg_temp.p5_insert(rc.table_name, rc.column_name, v_val); END IF;
      INSERT INTO p5_seeded VALUES (p_user, rc.table_name, true, NULL);
    EXCEPTION WHEN others THEN
      INSERT INTO p5_seeded VALUES (p_user, rc.table_name, false, rc.column_name || ': ' || SQLERRM);
    END;
  END LOOP;
  PERFORM set_config('session_replication_role', 'origin', true);
END
$$;
-- Run `p_sql` as service_role; returns 'ok' or '<SQLSTATE>:<message>'. When it is a
-- single-value SELECT, the value lands in the GUC `p_key`. The role is switched
-- inside the function so a check never leaves it behind.
CREATE OR REPLACE FUNCTION pg_temp.p5_as_svc(p_sql text, p_key text DEFAULT NULL) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v_out text;
BEGIN
  SET LOCAL ROLE service_role;
  EXECUTE p_sql INTO v_out;
  RESET ROLE;
  IF p_key IS NOT NULL THEN PERFORM set_config(p_key, coalesce(v_out, ''), true); END IF;
  RETURN 'ok';
EXCEPTION WHEN others THEN
  RESET ROLE;
  RETURN SQLSTATE || ':' || SQLERRM;
END
$$;

-- Same, as the account role with `p_uid` as the caller.
CREATE OR REPLACE FUNCTION pg_temp.p5_as_acct(p_sql text, p_uid uuid) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  SET LOCAL ROLE osionos_account_user;
  PERFORM set_config('request.jwt.claims',
    format('{"sub":"%s","aud":"osionos-account","role":"osionos_account_user"}', p_uid), true);
  EXECUTE p_sql;
  RESET ROLE;
  RETURN 'ok';
EXCEPTION WHEN others THEN
  RESET ROLE;
  RETURN SQLSTATE || ':' || SQLERRM;
END
$$;

-- A fingerprint of every public base table (row count and md5 of the rows), or
-- of the rows mentioning p_like only. Two equal fingerprints mean no row changed.
-- Caveat: rows are compared as text, so a change that does not alter the text
-- (a column added later with the same rendering) is invisible; it fingerprints
-- whole rows, not the files the objects point at.
CREATE OR REPLACE FUNCTION pg_temp.p5_fp(p_like text DEFAULT NULL) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE r record; n bigint; h text; v_all text := ''; v_rows bigint := 0;
BEGIN
  FOR r IN SELECT c.relname FROM pg_class c
            WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p') AND NOT c.relispartition
            ORDER BY 1 LOOP
    EXECUTE format('SELECT count(*), md5(coalesce(string_agg(x::text, ''|'' ORDER BY x::text), '''')) FROM public.%I x WHERE %s',
                   r.relname, CASE WHEN p_like IS NULL THEN 'true' ELSE format('row_to_json(x)::text LIKE %L', p_like) END)
      INTO n, h;
    v_all := v_all || r.relname || '=' || n || ':' || h || ';';
    v_rows := v_rows + n;
  END LOOP;
  RETURN v_rows || '/' || md5(v_all);
END
$$;

-- Tables that still hold the user's uuid anywhere in a row, keep tables excepted.
CREATE OR REPLACE FUNCTION pg_temp.p5_hits(p_user uuid) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE r record; n bigint; v_out text := '';
BEGIN
  FOR r IN SELECT c.relname FROM pg_class c
            WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p') AND NOT c.relispartition
              AND NOT EXISTS (SELECT 1 FROM public.osionos_account_data_map m WHERE m.table_name = c.relname AND m.erase = 'keep')
            ORDER BY 1 LOOP
    EXECUTE format('SELECT count(*) FROM public.%I x WHERE row_to_json(x)::text LIKE %L', r.relname, '%' || p_user::text || '%') INTO n;
    IF n > 0 THEN v_out := v_out || r.relname || '(' || n || ') '; END IF;
  END LOOP;
  RETURN v_out;
END
$$;

-- Two users with a row in every registry table each, A's request due, B's not.
-- Caveat: seeded under session_replication_role = replica (no triggers, no FK
-- check), so a seeded row does not prove a trigger accepts it; the transfer check
-- builds its rows with triggers on.
CREATE OR REPLACE FUNCTION pg_temp.p5_world() RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  a constant uuid := 'a5a5a5a5-0000-4000-8000-00000000000a';
  b constant uuid := 'b5b5b5b5-0000-4000-8000-00000000000b';
BEGIN
  TRUNCATE p5_seeded;
  PERFORM set_config('session_replication_role', 'replica', true);
  INSERT INTO auth.users (id) VALUES (a), (b);
  INSERT INTO public.users (id, email, name, username, password_hash) VALUES
    (a, 'alice-p5@canary.test', 'Alice P5Canary', 'alicep5', 'hash-a'),
    (b, 'bob-p5@canary.test', 'Bob P5Canary', 'bobp5', 'hash-b');
  PERFORM set_config('session_replication_role', 'origin', true);
  PERFORM pg_temp.p5_seed_user(a);
  PERFORM pg_temp.p5_seed_user(b);
  UPDATE public.osionos_account_deletion_requests
     SET requested_at = now() - interval '30 days', scheduled_for = now() - interval '1 day'
   WHERE user_id = a;
END
$$;
CREATE TEMP TABLE IF NOT EXISTS p5_assert (name text, ok boolean);
CREATE OR REPLACE FUNCTION pg_temp.p5_ok(p_name text, p_cond boolean) RETURNS void
LANGUAGE sql AS $$ INSERT INTO p5_assert VALUES (p_name, coalesce(p_cond, false)) $$;

-- The one row a check emits: failed assertions, plus one if fewer than p_floor
-- assertions ran (a check that asserted nothing must not pass).
CREATE OR REPLACE FUNCTION pg_temp.p5_row(p_label text, p_floor int) RETURNS TABLE (label text, n bigint, detail text)
LANGUAGE sql AS $$
  SELECT p_label,
         count(*) FILTER (WHERE NOT ok) + (CASE WHEN count(*) < p_floor THEN 1 ELSE 0 END),
         'failing: ' || coalesce(string_agg(name, ', ') FILTER (WHERE NOT ok), 'none')
           || ' (' || count(*) || ' assertions, floor ' || p_floor || ')'
    FROM p5_assert
$$;

-- p5_erasure_complete: the registry covers every column that can name a user.
-- Candidates are columns whose NAME looks user-keyed, and every column with a
-- foreign key to auth.users or public.users; each must be in the registry or on
-- the allowlist below with the reason it is not a user key. The reverse is
-- checked too: every registry row must name a column that exists.
-- Caveat: the name pattern is a guess. A user id stored in a column whose name
-- matches nothing and has no foreign key is found only by p5_erase_canary, and
-- only if the seed puts the uuid in it.
BEGIN;
CREATE FUNCTION pg_temp.p5_unregistered() RETURNS SETOF text LANGUAGE sql AS $f$
    WITH allow(t, c, why) AS (VALUES
      ('auth_audit_events', 'email', 'the row goes by user_id; a failed-login row with no user_id is not reached'),
      ('auth_audit_events', 'user_agent', 'the row goes by user_id'),
      ('auth_audit_events_legacy_int', 'email', 'legacy rows from before the uuid retype (auth-audit-events-migration.sql:40-43), service_role only; reached by neither id nor address, a residual of the erase'),
      ('ai_jobs', 'subject_kind', 'label'), ('ai_moderation_events', 'subject_kind', 'label'), ('ai_sentiment', 'subject_kind', 'label'),
      ('calendar_accounts', 'account_email', 'mailbox address, not a user id'), ('calendar_sources', 'account_id', 'calendar account id'),
      ('mail_accounts', 'account_email', 'mailbox address, not a user id'), ('mail_messages', 'account_id', 'mail account id'),
      ('mail_messages', 'from_email', 'external sender'), ('osionos_app_connections', 'external_account', 'label of the external account; the row goes by owner_id'),
      ('osionos_bridge_audit_events', 'user_agent', 'nulled by the erase'), ('osionos_bridge_identities', 'email_hash', 'the row goes by subject'),
      ('osionos_bridge_identities', 'profile', 'the row goes by subject'), ('osionos_bridge_identities', 'username', 'the row goes by subject'),
      ('osionos_feed_shares', 'target', 'share kind'), ('osionos_page_links', 'target_page_id', 'page id'),
      ('osionos_profile_template_section_grants', 'principal_type', 'label'), ('osionos_profiles', 'username', 'the row goes by user_id'),
      ('osionos_sessions', 'user_agent', 'the row goes by user_id'), ('osionos_share_rules', 'target_key', 'derived from target, same row'),
      ('osionos_user_reports', 'decision', 'label'), ('osionos_user_reports', 'decision_note', 'moderator free text'),
      ('osionos_user_reports', 'subject_kind', 'label'), ('osionos_username_history', 'username', 'the held name, released at released_at'),
      ('users', 'email', 'replaced by the erase'), ('users', 'username', 'replaced by the erase'))
    SELECT (c.relname || '.' || a.attname)::text
      FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
     WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p') AND NOT c.relispartition
       AND a.attnum > 0 AND NOT a.attisdropped
       AND (format_type(a.atttypid, a.atttypmod) LIKE 'uuid%' OR format_type(a.atttypid, a.atttypmod) LIKE 'character varying%'
            OR format_type(a.atttypid, a.atttypmod) IN ('text', 'citext') OR format_type(a.atttypid, a.atttypmod) LIKE 'json%'
            OR format_type(a.atttypid, a.atttypmod) LIKE '%[]')
       AND (a.attname ~ '(user|owner|author|actor|subject|creator|requester|addressee|follower|followee|blocker|blocked|reporter|principal|(^|_)by$|collaborator|member|sender|recipient|assignee|invitee|inviter|decision|decided|target|account|email|participant|holder|grantee|identity|profile)'
            OR EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'f' AND k.conkey = ARRAY[a.attnum]
                          AND k.confrelid IN ('auth.users'::regclass, 'public.users'::regclass)))
       AND NOT EXISTS (SELECT 1 FROM public.osionos_account_data_map m WHERE m.table_name = c.relname AND m.column_name = a.attname)
       AND NOT EXISTS (SELECT 1 FROM allow WHERE allow.t = c.relname AND allow.c = a.attname)
$f$;
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT x AS col FROM pg_temp.p5_unregistered() x
  LOOP
    PERFORM pg_temp.p5_ok('unregistered ' || r.col, false);
  END LOOP;
  FOR r IN
    SELECT m.table_name || '.' || m.column_name AS col FROM public.osionos_account_data_map m
     WHERE NOT EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = to_regclass('public.' || quote_ident(m.table_name))
                         AND a.attname = m.column_name AND NOT a.attisdropped)
  LOOP
    PERFORM pg_temp.p5_ok('stale registry row ' || r.col, false);
  END LOOP;
  PERFORM pg_temp.p5_ok('registry has at least 93 rows', (SELECT count(*) FROM public.osionos_account_data_map) >= 93);
  PERFORM pg_temp.p5_ok('registry covers at least 75 tables', (SELECT count(DISTINCT table_name) FROM public.osionos_account_data_map) >= 75);
  -- floor on the scan itself: a broken pattern that matched nothing would pass the loop above
  PERFORM pg_temp.p5_ok('scan sees at least 85 candidate columns', (
    SELECT count(*) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
     WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p') AND NOT c.relispartition
       AND a.attnum > 0 AND NOT a.attisdropped AND (format_type(a.atttypid, a.atttypmod) LIKE 'uuid%' OR format_type(a.atttypid, a.atttypmod) LIKE 'character varying%'
            OR format_type(a.atttypid, a.atttypmod) IN ('text', 'citext') OR format_type(a.atttypid, a.atttypmod) LIKE 'json%'
            OR format_type(a.atttypid, a.atttypmod) LIKE '%[]')
       AND a.attname ~ '(user|owner|author|actor|subject|creator|requester|addressee|follower|followee|blocker|blocked|reporter|principal)') >= 85);
END
$$;
-- a varchar(36) author column is still a user key: the old exact-IN filter skipped it
ALTER TABLE public.osionos_follows ADD COLUMN author_ref varchar(36);
ALTER TABLE public.osionos_follows ADD COLUMN actor_blob json;
DO $$ BEGIN
  PERFORM pg_temp.p5_ok('scratch varchar(36) author_ref is reported unregistered',
    EXISTS (SELECT 1 FROM pg_temp.p5_unregistered() x WHERE x = 'osionos_follows.author_ref'));
  PERFORM pg_temp.p5_ok('scratch json actor_blob is reported unregistered',
    EXISTS (SELECT 1 FROM pg_temp.p5_unregistered() x WHERE x = 'osionos_follows.actor_blob'));
END $$;
SELECT * FROM pg_temp.p5_row('p5_erasure_complete', 5);
ROLLBACK;

-- p5_erase_canary: the end-to-end completeness gate. Seed a row in every
-- registry table for user A (and a second user B), run the erase, then search
-- EVERY public table for A's uuid in the row's JSON text: the only tables
-- allowed to match are those with a registry `keep` row, and each of those
-- carries a reason. Floors: the seed reached every registry table (counted from
-- the catalog, not from a constant), the registry has at least 93 rows over 75
-- tables, and the named tables are in it.
-- Caveat: the scan finds A's uuid as text. A user id stored encoded (base64,
-- hashed) is invisible to it; and a table nobody put a row in cannot fail.
BEGIN;
DO $$ BEGIN
  PERFORM pg_temp.p5_world();
  PERFORM set_config('osionos.check.p5_r', pg_temp.p5_as_svc(
    $q$SELECT public.osionos_account_erase('a5a5a5a5-0000-4000-8000-00000000000a')::text$q$, 'osionos.check.p5_e'), true);
END $$;
DO $$
DECLARE
  a constant uuid := 'a5a5a5a5-0000-4000-8000-00000000000a';
  v_hits text;
BEGIN
  PERFORM pg_temp.p5_ok('erase returned ok: ' || current_setting('osionos.check.p5_r'), current_setting('osionos.check.p5_r') = 'ok');
  PERFORM pg_temp.p5_ok('seed reached every registry table',
    (SELECT count(DISTINCT table_name) FROM p5_seeded WHERE user_id = a AND ok)
      = (SELECT count(DISTINCT table_name) FROM public.osionos_account_data_map));
  PERFORM pg_temp.p5_ok('no seed failed: ' || coalesce((SELECT string_agg(table_name || ' ' || err, '; ') FROM p5_seeded WHERE NOT ok), ''),
    NOT EXISTS (SELECT 1 FROM p5_seeded WHERE NOT ok));
  PERFORM pg_temp.p5_ok('registry has at least 93 rows', (SELECT count(*) FROM public.osionos_account_data_map) >= 93);
  PERFORM pg_temp.p5_ok('registry covers at least 75 tables', (SELECT count(DISTINCT table_name) FROM public.osionos_account_data_map) >= 75);
  PERFORM pg_temp.p5_ok('named table ' || t, EXISTS (SELECT 1 FROM public.osionos_account_data_map m WHERE m.table_name = t))
    FROM unnest(ARRAY['osionos_pages', 'osionos_workspaces', 'osionos_messages', 'osionos_sessions', 'osionos_notifications',
                      'osionos_profiles', 'osionos_user_settings', 'osionos_workspace_members', 'osionos_page_comments',
                      'osionos_follows', 'osionos_connections', 'ai_memories', 'osionos_personal_access_tokens',
                      'osionos_mfa_totp', 'osionos_account_exports', 'osionos_message_attachments']) t;
  PERFORM pg_temp.p5_ok('keep row with a reason: ' || t, EXISTS (SELECT 1 FROM public.osionos_account_data_map m
      WHERE m.table_name = t AND m.erase = 'keep' AND length(btrim(m.reason)) > 0))
    FROM unnest(ARRAY['osionos_account_deletion_requests', 'osionos_account_erasure_objects',
                      'osionos_bridge_audit_events', 'auth_session_cutoffs']) t;
  v_hits := pg_temp.p5_hits(a);
  PERFORM pg_temp.p5_ok('no table outside the keep set still holds the uuid: ' || v_hits, v_hits = '');
  PERFORM pg_temp.p5_ok('the identity row lost every personal field', NOT EXISTS (
    SELECT 1 FROM public.users u WHERE u.id = a AND (u.name IS NOT NULL OR u.username IS NOT NULL OR u.password_hash IS NOT NULL
      OR u.email LIKE '%alice%' OR u.email NOT LIKE 'erased-%@erased.invalid')));
END
$$;
SELECT * FROM pg_temp.p5_row('p5_erase_canary', 25);
ROLLBACK;
-- Builders for the transfer scenarios: real rows with triggers ON, so the
-- workspace/member triggers that exist in production run here too.
CREATE OR REPLACE FUNCTION pg_temp.p5_lit(p_u uuid) RETURNS text LANGUAGE sql AS $$ SELECT quote_literal(p_u::text) || '::uuid' $$;

CREATE OR REPLACE FUNCTION pg_temp.p5_user(p_u uuid, p_name text, p_due boolean DEFAULT false) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO auth.users (id) VALUES (p_u) ON CONFLICT DO NOTHING;
  INSERT INTO public.users (id, email, name, username) VALUES (p_u, p_u::text || '@p5.test', p_name, 'u' || substr(p_u::text, 1, 8))
    ON CONFLICT DO NOTHING;
  IF p_due THEN
    INSERT INTO public.osionos_account_deletion_requests (user_id, requested_at, scheduled_for)
    VALUES (p_u, now() - interval '30 days', now() - interval '1 day');
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION pg_temp.p5_ws(p_ws uuid, p_owner uuid) RETURNS void
LANGUAGE sql AS $$ SELECT pg_temp.p5_insert('osionos_workspaces', 'id', pg_temp.p5_lit(p_ws), 0, 'owner_id', pg_temp.p5_lit(p_owner)) $$;

CREATE OR REPLACE FUNCTION pg_temp.p5_member(p_ws uuid, p_user uuid, p_role text, p_created timestamptz) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.osionos_workspace_members WHERE workspace_id = p_ws AND user_id = p_user) THEN
    PERFORM pg_temp.p5_insert('osionos_workspace_members', 'workspace_id', pg_temp.p5_lit(p_ws), 0, 'user_id', pg_temp.p5_lit(p_user));
  END IF;
  UPDATE public.osionos_workspace_members SET role = p_role, created_at = p_created
   WHERE workspace_id = p_ws AND user_id = p_user;
END
$$;

CREATE OR REPLACE FUNCTION pg_temp.p5_page(p_ws uuid, p_owner uuid, p_vis text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid := gen_random_uuid();
BEGIN
  PERFORM pg_temp.p5_insert('osionos_pages', 'id', pg_temp.p5_lit(v_id), 0, 'workspace_id', pg_temp.p5_lit(p_ws));
  UPDATE public.osionos_pages SET owner_id = p_owner, visibility = p_vis WHERE id = v_id;
  RETURN v_id;
END
$$;
-- p5_erase_transfer: the four D5 branches against real rows (triggers on).
--   O1 accepted successor S1: W1 (S1 member) -> transferred; W3 (S1 not a member) -> promoted, the
--      successor having left; the oldest admin takes it.
--   O2 successor not accepted: W2 has a viewer and two later admins; the earlier admin is promoted,
--      is told in words naming no user, a private page goes and a shared page passes.
--   O3 no successor: two admins with the same created_at; the smaller user id wins.
--   O4 sole member: W5 empty -> deleted; W6 holds a non-member's message -> kept_orphaned.
-- Caveat: the dispositions are asserted for these shapes only; a workspace with a
-- member whose row the trigger rewrites in a way these inserts do not reach is not covered.
BEGIN;
DO $$
DECLARE
  o1 constant uuid := 'c1000000-0000-4000-8000-000000000001'; s1 constant uuid := 'c1000000-0000-4000-8000-000000000002';
  m1 constant uuid := 'c1000000-0000-4000-8000-000000000003';
  w1 constant uuid := 'c1000000-0000-4000-8000-0000000000a1'; w3 constant uuid := 'c1000000-0000-4000-8000-0000000000a3';
  o2 constant uuid := 'c2000000-0000-4000-8000-000000000001'; s2 constant uuid := 'c2000000-0000-4000-8000-000000000002';
  v2 constant uuid := 'c2000000-0000-4000-8000-000000000003'; x2 constant uuid := 'c2000000-0000-4000-8000-000000000004';
  y2 constant uuid := 'c2000000-0000-4000-8000-000000000005'; w2 constant uuid := 'c2000000-0000-4000-8000-0000000000a2';
  o3 constant uuid := 'c3000000-0000-4000-8000-000000000001'; hi constant uuid := 'c3000000-0000-4000-8000-0000000000bb';
  lo constant uuid := 'c3000000-0000-4000-8000-0000000000aa'; w4 constant uuid := 'c3000000-0000-4000-8000-0000000000a4';
  o4 constant uuid := 'c4000000-0000-4000-8000-000000000001'; st constant uuid := 'c4000000-0000-4000-8000-000000000009';
  w5 constant uuid := 'c4000000-0000-4000-8000-0000000000a5'; w6 constant uuid := 'c4000000-0000-4000-8000-0000000000a6';
  t0 constant timestamptz := now() - interval '100 days';
  v_priv uuid; v_shared uuid; v_ch uuid := gen_random_uuid(); v_res text; v_own text;
BEGIN
  PERFORM pg_temp.p5_user(o1, 'Olga Owner', true); PERFORM pg_temp.p5_user(s1, 'Sam Successor'); PERFORM pg_temp.p5_user(m1, 'Mia M');
  UPDATE public.osionos_account_deletion_requests SET successor_user_id = s1, successor_accepted_at = now() WHERE user_id = o1;
  PERFORM pg_temp.p5_ws(w1, o1); PERFORM pg_temp.p5_member(w1, s1, 'editor', t0 + interval '1 day');
  PERFORM pg_temp.p5_ws(w3, o1); PERFORM pg_temp.p5_member(w3, m1, 'admin', t0 + interval '2 days');

  PERFORM pg_temp.p5_user(o2, 'Ola Second', true); PERFORM pg_temp.p5_user(s2, 'Sid Pending');
  PERFORM pg_temp.p5_user(v2, 'Vic Viewer'); PERFORM pg_temp.p5_user(x2, 'Xia Admin'); PERFORM pg_temp.p5_user(y2, 'Yan Admin');
  UPDATE public.osionos_account_deletion_requests SET successor_user_id = s2 WHERE user_id = o2;
  PERFORM pg_temp.p5_ws(w2, o2);
  PERFORM pg_temp.p5_member(w2, v2, 'viewer', t0);
  PERFORM pg_temp.p5_member(w2, x2, 'admin', t0 + interval '10 days');
  PERFORM pg_temp.p5_member(w2, y2, 'admin', t0 + interval '20 days');
  v_priv := pg_temp.p5_page(w2, o2, 'private'); v_shared := pg_temp.p5_page(w2, o2, 'shared');

  PERFORM pg_temp.p5_user(o3, 'Oto Third', true); PERFORM pg_temp.p5_user(hi, 'Hi'); PERFORM pg_temp.p5_user(lo, 'Lo');
  PERFORM pg_temp.p5_ws(w4, o3);
  PERFORM pg_temp.p5_member(w4, hi, 'admin', t0 + interval '3 days'); PERFORM pg_temp.p5_member(w4, lo, 'admin', t0 + interval '3 days');

  PERFORM pg_temp.p5_user(o4, 'Odd Fourth', true); PERFORM pg_temp.p5_user(st, 'Stranger');
  PERFORM pg_temp.p5_ws(w5, o4); PERFORM pg_temp.p5_ws(w6, o4);
  PERFORM pg_temp.p5_insert('osionos_channels', 'id', pg_temp.p5_lit(v_ch), 0, 'workspace_id', pg_temp.p5_lit(w6));
  PERFORM pg_temp.p5_insert('osionos_messages', 'channel_id', pg_temp.p5_lit(v_ch), 0, 'author_id', pg_temp.p5_lit(st));

  PERFORM pg_temp.p5_ok('erase O1 ' || pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || o1 || ''')::text'), true);
  PERFORM pg_temp.p5_ok('W1 owner is the accepted successor', (SELECT owner_id FROM public.osionos_workspaces WHERE id = w1) = s1);
  PERFORM pg_temp.p5_ok('W1 successor row is owner', (SELECT role FROM public.osionos_workspace_members WHERE workspace_id = w1 AND user_id = s1) = 'owner');
  PERFORM pg_temp.p5_ok('W3 (successor not a member) promotes the admin', (SELECT owner_id FROM public.osionos_workspaces WHERE id = w3) = m1);

  PERFORM pg_temp.p5_ok('erase O2 ' || pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || o2 || ''')::text'), true);
  PERFORM pg_temp.p5_ok('W2 (successor not accepted) goes to the earliest admin', (SELECT owner_id FROM public.osionos_workspaces WHERE id = w2) = x2);
  PERFORM pg_temp.p5_ok('W2 viewer is not promoted over the admin', (SELECT role FROM public.osionos_workspace_members WHERE workspace_id = w2 AND user_id = v2) = 'viewer');
  PERFORM pg_temp.p5_ok('private page deleted', NOT EXISTS (SELECT 1 FROM public.osionos_pages WHERE id = v_priv));
  PERFORM pg_temp.p5_ok('shared page passed to the new owner', (SELECT owner_id FROM public.osionos_pages WHERE id = v_shared) = x2);
  PERFORM pg_temp.p5_ok('one notification to the new owner', (SELECT count(*) FROM public.osionos_notifications WHERE user_id = x2 AND type = 'system') = 1);
  PERFORM pg_temp.p5_ok('the notification names no user: ' || coalesce((SELECT preview FROM public.osionos_notifications WHERE user_id = x2 AND type = 'system'), '-'),
    NOT EXISTS (SELECT 1 FROM public.osionos_notifications n WHERE n.user_id = x2 AND (n.preview LIKE '%' || o2::text || '%' OR n.preview ILIKE '%Ola%' OR n.preview ILIKE '%Second%')));
  PERFORM pg_temp.p5_ok('no notification to the other admin', NOT EXISTS (SELECT 1 FROM public.osionos_notifications WHERE user_id = y2 AND type = 'system'));

  PERFORM pg_temp.p5_ok('erase O3 ' || pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || o3 || ''')::text'), true);
  PERFORM pg_temp.p5_ok('W4 tie on created_at goes to the smaller user id', (SELECT owner_id FROM public.osionos_workspaces WHERE id = w4) = lo);

  PERFORM pg_temp.p5_ok('erase O4 ' || pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || o4 || ''')::text', 'osionos.check.p5_j'), true);
  PERFORM pg_temp.p5_ok('W5 (sole member, empty) is deleted', NOT EXISTS (SELECT 1 FROM public.osionos_workspaces WHERE id = w5));
  PERFORM pg_temp.p5_ok('W6 (holds a stranger''s message) is kept, owned by the tombstone',
    (SELECT owner_id FROM public.osionos_workspaces WHERE id = w6) = public.osionos_account_tombstone());
  PERFORM pg_temp.p5_ok('the stranger''s message is still there', EXISTS (SELECT 1 FROM public.osionos_messages WHERE channel_id = v_ch AND author_id = st));
  PERFORM pg_temp.p5_ok('result says kept_orphaned and deleted', current_setting('osionos.check.p5_j') LIKE '%"kept_orphaned": 1%'
                                                             AND current_setting('osionos.check.p5_j') LIKE '%"deleted": 1%');
END $$;
SELECT * FROM pg_temp.p5_row('p5_erase_transfer', 16);
ROLLBACK;
-- p5_erase_idempotent: a second erase of the same user changes nothing. Every
-- table's rows are fingerprinted after the first run and after the second, and
-- every count the second run reports for erased data is zero. The first run
-- must have done real work (floor on the counts), or two empty runs would match.
-- Caveat: fingerprints are text of the rows; see p5_fp.
BEGIN;
DO $$
DECLARE
  a constant uuid := 'a5a5a5a5-0000-4000-8000-00000000000a';
  v_f1 text; v_f2 text; v_j1 jsonb; v_j2 jsonb; v_nonzero text;
BEGIN
  PERFORM pg_temp.p5_world();
  PERFORM pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || a || ''')::text', 'osionos.check.p5_j1');
  v_j1 := current_setting('osionos.check.p5_j1')::jsonb;
  v_f1 := pg_temp.p5_fp();
  PERFORM pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || a || ''')::text', 'osionos.check.p5_j2');
  v_j2 := current_setting('osionos.check.p5_j2')::jsonb;
  v_f2 := pg_temp.p5_fp();
  PERFORM pg_temp.p5_ok('first run erased something: ' || (SELECT coalesce(sum(value::bigint), 0) FROM jsonb_each_text(v_j1 -> 'counts'))::text,
    (SELECT coalesce(sum(value::bigint), 0) FROM jsonb_each_text(v_j1 -> 'counts')) >= 60);
  SELECT string_agg(key || '=' || value, ', ') INTO v_nonzero FROM jsonb_each_text(v_j2 -> 'counts') WHERE value::bigint <> 0;
  PERFORM pg_temp.p5_ok('second run counts are all zero, got: ' || coalesce(v_nonzero, ''), v_nonzero IS NULL);
  PERFORM pg_temp.p5_ok('second run counts keys are the first run''s', (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(v_j1 -> 'counts') key)
                                                                       = (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(v_j2 -> 'counts') key));
  PERFORM pg_temp.p5_ok('no table changed between run 1 and run 2: ' || v_f1 || ' vs ' || v_f2, v_f1 = v_f2);
  PERFORM pg_temp.p5_ok('erased_at stamped once', (SELECT erased_at IS NOT NULL FROM public.osionos_account_deletion_requests WHERE user_id = a));
END $$;
SELECT * FROM pg_temp.p5_row('p5_erase_idempotent', 5);
ROLLBACK;

-- p5_erase_isolated: erasing A leaves B byte-identical (every row that mentions B,
-- in every table, with a row for B in every registry table), and leaves a
-- non-member author's rows in A's sole workspace alone: the workspace is kept,
-- owned by the tombstone.
-- Caveat: "mentions B" is a text match on the row; a row that names B only in a
-- form the match cannot see (encoded) is not protected by this check.
BEGIN;
DO $$
DECLARE
  a constant uuid := 'a5a5a5a5-0000-4000-8000-00000000000a';
  b constant uuid := 'b5b5b5b5-0000-4000-8000-00000000000b';
  n constant uuid := 'e5e5e5e5-0000-4000-8000-00000000000e';
  w constant uuid := 'e5e5e5e5-0000-4000-8000-0000000000a1';
  ch uuid := gen_random_uuid(); v_before text; v_after text; v_msg text;
BEGIN
  PERFORM pg_temp.p5_world();
  PERFORM pg_temp.p5_user(n, 'Nina NonMember');
  PERFORM pg_temp.p5_ws(w, a);
  PERFORM pg_temp.p5_member(w, a, 'owner', now() - interval '60 days');
  PERFORM pg_temp.p5_insert('osionos_channels', 'id', pg_temp.p5_lit(ch), 0, 'workspace_id', pg_temp.p5_lit(w));
  PERFORM pg_temp.p5_insert('osionos_messages', 'channel_id', pg_temp.p5_lit(ch), 0, 'author_id', pg_temp.p5_lit(n));
  SELECT md5(string_agg(x::text, '|' ORDER BY x::text)) INTO v_msg FROM public.osionos_messages x WHERE x.author_id = n;
  PERFORM pg_temp.p5_ok('B has a row in at least 70 registry tables',
    (SELECT count(DISTINCT table_name) FROM p5_seeded WHERE user_id = b AND ok) >= 70);
  v_before := pg_temp.p5_fp('%' || b::text || '%');
  PERFORM pg_temp.p5_ok('erase A ' || pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || a || ''')::text'), true);
  v_after := pg_temp.p5_fp('%' || b::text || '%');
  PERFORM pg_temp.p5_ok('B''s rows are identical: ' || v_before || ' vs ' || v_after, v_before = v_after);
  PERFORM pg_temp.p5_ok('B''s identity row keeps its email', EXISTS (SELECT 1 FROM public.users WHERE id = b AND email = 'bob-p5@canary.test' AND name = 'Bob P5Canary'));
  PERFORM pg_temp.p5_ok('the workspace with a non-member author survives', EXISTS (SELECT 1 FROM public.osionos_workspaces WHERE id = w));
  PERFORM pg_temp.p5_ok('... owned by the tombstone', (SELECT owner_id FROM public.osionos_workspaces WHERE id = w) = public.osionos_account_tombstone());
  PERFORM pg_temp.p5_ok('the non-member''s messages are byte-identical',
    (SELECT md5(string_agg(x::text, '|' ORDER BY x::text)) FROM public.osionos_messages x WHERE x.author_id = n) = v_msg);
END $$;
SELECT * FROM pg_temp.p5_row('p5_erase_isolated', 6);
ROLLBACK;

-- p5_plan_matches_erase: the plan reports what the erase then does (same jsonb on
-- the same seed), and itself writes nothing (every table fingerprint unchanged).
-- Caveat: equality is checked on one seed; a branch the seed does not reach
-- (the shared body makes a divergence unlikely, not impossible) is not compared.
BEGIN;
DO $$
DECLARE
  a constant uuid := 'a5a5a5a5-0000-4000-8000-00000000000a';
  v_f1 text; v_f2 text; v_plan jsonb; v_real jsonb;
BEGIN
  PERFORM pg_temp.p5_world();
  v_f1 := pg_temp.p5_fp();
  PERFORM pg_temp.p5_as_svc('SELECT public.osionos_account_erase_plan(''' || a || ''')::text', 'osionos.check.p5_plan');
  v_f2 := pg_temp.p5_fp();
  PERFORM pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || a || ''')::text', 'osionos.check.p5_real');
  v_plan := current_setting('osionos.check.p5_plan')::jsonb; v_real := current_setting('osionos.check.p5_real')::jsonb;
  PERFORM pg_temp.p5_ok('the plan wrote nothing: ' || v_f1 || ' vs ' || v_f2, v_f1 = v_f2);
  PERFORM pg_temp.p5_ok('the plan counted real work', (SELECT coalesce(sum(value::bigint), 0) FROM jsonb_each_text(v_plan -> 'counts')) >= 60);
  PERFORM pg_temp.p5_ok('plan equals erase', v_plan = v_real);
END $$;
SELECT * FROM pg_temp.p5_row('p5_plan_matches_erase', 3);
ROLLBACK;

-- p5_erase_refuses_live: no request row -> P0001 no_deletion_request; nothing changes.
-- p5_erase_refuses_early: request scheduled in 14 days -> P0001 grace_not_over and zero
-- rows changed in the whole database; a request already stamped erased_at goes on
-- (a crash after the first pass is finished, not refused) even with a future date.
BEGIN;
DO $$
DECLARE
  b constant uuid := 'b5b5b5b5-0000-4000-8000-00000000000b';
  l constant uuid := 'f5f5f5f5-0000-4000-8000-00000000000f';
  v_f1 text; v_f2 text; v_r text;
BEGIN
  PERFORM pg_temp.p5_world();
  PERFORM pg_temp.p5_user(l, 'Lena Live');
  v_f1 := pg_temp.p5_fp();
  v_r := pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || l || ''')::text');
  PERFORM pg_temp.p5_ok('no request -> P0001:no_deletion_request, got ' || v_r, v_r = 'P0001:no_deletion_request');
  PERFORM pg_temp.p5_ok('plan of a live user refuses too', pg_temp.p5_as_svc('SELECT public.osionos_account_erase_plan(''' || l || ''')::text') = 'P0001:no_deletion_request');
  PERFORM pg_temp.p5_ok('null user refused', pg_temp.p5_as_svc('SELECT public.osionos_account_erase(NULL)::text') = 'P0001:user_required');
  PERFORM pg_temp.p5_ok('nothing changed by the live refusal', pg_temp.p5_fp() = v_f1);
  v_f1 := pg_temp.p5_fp();
  v_r := pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || b || ''')::text');
  PERFORM pg_temp.p5_ok('scheduled in 14 days -> P0001:grace_not_over, got ' || v_r, v_r = 'P0001:grace_not_over');
  PERFORM pg_temp.p5_ok('plan refuses an early request too', pg_temp.p5_as_svc('SELECT public.osionos_account_erase_plan(''' || b || ''')::text') = 'P0001:grace_not_over');
  v_f2 := pg_temp.p5_fp();
  PERFORM pg_temp.p5_ok('zero rows changed by the early refusal: ' || v_f1 || ' vs ' || v_f2, v_f1 = v_f2);
  PERFORM pg_temp.p5_ok('the early user still has every registry row (B''s identity untouched)', EXISTS (SELECT 1 FROM public.users WHERE id = b AND name = 'Bob P5Canary'));
  UPDATE public.osionos_account_deletion_requests SET erased_at = now() WHERE user_id = b;
  PERFORM pg_temp.p5_ok('stamped request proceeds despite a future date', pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || b || ''')::text') = 'ok');
  PERFORM pg_temp.p5_ok('... and erased the identity', EXISTS (SELECT 1 FROM public.users WHERE id = b AND name IS NULL));
END $$;
SELECT 'p5_erase_refuses_live', count(*) FILTER (WHERE NOT ok) + (CASE WHEN count(*) < 4 THEN 1 ELSE 0 END), 'failing: ' || coalesce(string_agg(name, ', ') FILTER (WHERE NOT ok AND (name LIKE 'no request%' OR name LIKE 'plan of a live%' OR name LIKE 'null user%' OR name LIKE 'nothing changed by the live%')), 'none')
  FROM p5_assert WHERE name LIKE 'no request%' OR name LIKE 'plan of a live%' OR name LIKE 'null user%' OR name LIKE 'nothing changed by the live%';
SELECT 'p5_erase_refuses_early', count(*) FILTER (WHERE NOT ok) + (CASE WHEN count(*) < 5 THEN 1 ELSE 0 END),
       'failing: ' || coalesce(string_agg(name, ', ') FILTER (WHERE NOT ok), 'none')
  FROM p5_assert WHERE NOT (name LIKE 'no request%' OR name LIKE 'plan of a live%' OR name LIKE 'null user%' OR name LIKE 'nothing changed by the live%');
ROLLBACK;
-- p5_dry_run_no_stamp: reading the queue and planning an erase leave every request
-- untouched: claimed_at and erased_at stay NULL on all of them, attempts stay 0.
-- Three users are due so the check cannot pass on an empty queue.
BEGIN;
DO $$
DECLARE
  a constant uuid := 'a5a5a5a5-0000-4000-8000-00000000000a';
  c constant uuid := 'c5c5c5c5-0000-4000-8000-00000000000c';
  d constant uuid := 'd5d5d5d5-0000-4000-8000-00000000000d';
  v_due bigint;
BEGIN
  PERFORM pg_temp.p5_world();
  PERFORM pg_temp.p5_user(c, 'Cy Due', true); PERFORM pg_temp.p5_user(d, 'Di Due', true);
  PERFORM pg_temp.p5_as_svc('SELECT count(*)::text FROM public.osionos_account_deletion_due(50)', 'osionos.check.p5_due');
  v_due := current_setting('osionos.check.p5_due')::bigint;
  PERFORM pg_temp.p5_ok('_due returned the three due users, got ' || v_due, v_due = 3);
  PERFORM pg_temp.p5_ok('plan ' || pg_temp.p5_as_svc('SELECT public.osionos_account_erase_plan(''' || a || ''')::text'), true);
  PERFORM pg_temp.p5_ok('no request is claimed or stamped: ' || (SELECT count(*) FROM public.osionos_account_deletion_requests
      WHERE claimed_at IS NOT NULL OR erased_at IS NOT NULL OR attempts <> 0 OR last_error IS NOT NULL)::text,
    NOT EXISTS (SELECT 1 FROM public.osionos_account_deletion_requests WHERE claimed_at IS NOT NULL OR erased_at IS NOT NULL OR attempts <> 0 OR last_error IS NOT NULL));
  PERFORM pg_temp.p5_ok('_due(0) and _due(NULL) return nothing', pg_temp.p5_as_svc('SELECT count(*)::text FROM public.osionos_account_deletion_due(0) UNION ALL SELECT count(*)::text FROM public.osionos_account_deletion_due(NULL) LIMIT 1', 'osionos.check.p5_z') = 'ok'
    AND current_setting('osionos.check.p5_z') = '0');
END $$;
SELECT * FROM pg_temp.p5_row('p5_dry_run_no_stamp', 4);
ROLLBACK;

-- p5_no_fk_to_tombstone: the tombstone uuid is a value, not a row. No identity row
-- carries it, no foreign key can point at it (an anonymised column that has a FK
-- is nullable and goes to NULL), and a column in a UNIQUE or primary key is never
-- anonymised (two erased users would collide on the tombstone). After an erase no
-- column that references the identity tables holds the tombstone.
-- Caveat: a UNIQUE that is a unique index only (no constraint) is read from
-- pg_index; an expression index over the column is not understood and is not
-- counted.
BEGIN;
DO $$
DECLARE
  a constant uuid := 'a5a5a5a5-0000-4000-8000-00000000000a';
  r record; n bigint; v_tomb constant uuid := public.osionos_account_tombstone();
BEGIN
  PERFORM pg_temp.p5_world();
  PERFORM pg_temp.p5_ok('no auth.users row is the tombstone', NOT EXISTS (SELECT 1 FROM auth.users WHERE id = v_tomb));
  PERFORM pg_temp.p5_ok('no public.users row is the tombstone', NOT EXISTS (SELECT 1 FROM public.users WHERE id = v_tomb));
  PERFORM pg_temp.p5_ok('registry has anonymise rows to judge', (SELECT count(*) FROM public.osionos_account_data_map WHERE erase = 'anonymise') >= 5);
  FOR r IN
    SELECT m.table_name, m.column_name FROM public.osionos_account_data_map m
     WHERE m.erase = 'anonymise'
       AND EXISTS (SELECT 1 FROM pg_index i JOIN pg_attribute at ON at.attrelid = i.indrelid AND at.attnum = ANY (i.indkey)
                    WHERE i.indrelid = to_regclass('public.' || quote_ident(m.table_name)) AND i.indisunique
                      AND at.attname = m.column_name AND i.indpred IS NULL)
  LOOP
    PERFORM pg_temp.p5_ok('anonymise column is in a unique index: ' || r.table_name || '.' || r.column_name, false);
  END LOOP;
  FOR r IN
    SELECT m.table_name, m.column_name FROM public.osionos_account_data_map m
      JOIN pg_attribute at ON at.attrelid = to_regclass('public.' || quote_ident(m.table_name)) AND at.attname = m.column_name
     WHERE m.erase = 'anonymise' AND at.attnotnull
       AND EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid = at.attrelid AND c.contype = 'f' AND at.attnum = ANY (c.conkey))
  LOOP
    PERFORM pg_temp.p5_ok('anonymise column is a NOT NULL foreign key: ' || r.table_name || '.' || r.column_name, false);
  END LOOP;
  PERFORM pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || a || ''')::text');
  FOR r IN
    SELECT c.conrelid::regclass::text AS rel, at.attname AS col
      FROM pg_constraint c JOIN pg_attribute at ON at.attrelid = c.conrelid AND at.attnum = c.conkey[1]
     WHERE c.contype = 'f' AND array_length(c.conkey, 1) = 1 AND c.confrelid IN ('auth.users'::regclass, 'public.users'::regclass)
       AND c.connamespace = 'public'::regnamespace
  LOOP
    EXECUTE format('SELECT count(*) FROM %s WHERE %I::text = %L', r.rel, r.col, v_tomb::text) INTO n;
    IF n > 0 THEN PERFORM pg_temp.p5_ok('a foreign-key column holds the tombstone: ' || r.rel || '.' || r.col, false); END IF;
  END LOOP;
  PERFORM pg_temp.p5_ok('at least 15 foreign keys to the identity tables were inspected', (
    SELECT count(*) FROM pg_constraint c WHERE c.contype = 'f' AND array_length(c.conkey, 1) = 1
       AND c.confrelid IN ('auth.users'::regclass, 'public.users'::regclass) AND c.connamespace = 'public'::regnamespace) >= 15);
END $$;
SELECT * FROM pg_temp.p5_row('p5_no_fk_to_tombstone', 4);
ROLLBACK;

-- p5_erase_objects_recorded: every storage key the user's rows name, and the export
-- artifacts, is in the retry list after the erase; B has none; a second erase adds
-- none and the keys survive the erase (the bridge deletes them after the objects).
-- Avatar, banner and collab-upload objects have no key in any column the SQL can
-- read: the bridge's runner (sub-package c) deletes them by owner prefix, and
-- until then they are accepted residual risk (see the migration header).
-- Caveat: a key is recorded from the registry's object columns; an object whose
-- key sits in a column the registry does not name is not recorded.
BEGIN;
DO $$
DECLARE
  a constant uuid := 'a5a5a5a5-0000-4000-8000-00000000000a';
  b constant uuid := 'b5b5b5b5-0000-4000-8000-00000000000b';
  v_n1 bigint; v_n2 bigint; v_expect bigint; v_exp_key text; v_att_key text; v_b0 bigint;
BEGIN
  PERFORM pg_temp.p5_world();
  v_expect := (SELECT count(*) FROM public.osionos_account_data_map WHERE object_bucket IS NOT NULL AND erase <> 'keep');
  PERFORM pg_temp.p5_ok('registry names object columns (' || v_expect || ')', v_expect >= 1);
  SELECT e.id::text || '.' || e.format INTO v_exp_key FROM public.osionos_account_exports e WHERE e.user_id = a;
  UPDATE public.osionos_message_attachments SET object_key = 'p5-attachment-key' WHERE owner_id = a;
  SELECT object_key INTO v_att_key FROM public.osionos_message_attachments WHERE owner_id = a;
  PERFORM pg_temp.p5_ok('A has an export and an attachment to record', v_exp_key IS NOT NULL AND v_att_key IS NOT NULL);
  SELECT count(*) INTO v_b0 FROM public.osionos_account_erasure_objects WHERE user_id = b;
  PERFORM pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || a || ''')::text');
  SELECT count(*) INTO v_n1 FROM public.osionos_account_erasure_objects WHERE user_id = a;
  PERFORM pg_temp.p5_ok('the export artifact key is recorded: ' || coalesce(v_exp_key, '-'), EXISTS (SELECT 1 FROM public.osionos_account_erasure_objects
    WHERE user_id = a AND bucket = 'account-exports' AND key = v_exp_key));
  PERFORM pg_temp.p5_ok('the attachment key is recorded: ' || coalesce(v_att_key, '-'), EXISTS (SELECT 1 FROM public.osionos_account_erasure_objects
    WHERE user_id = a AND bucket = 'chat' AND key = v_att_key));
  PERFORM pg_temp.p5_ok('every bucket the registry names has a recorded key for A',
    NOT EXISTS (SELECT 1 FROM public.osionos_account_data_map m WHERE m.object_bucket IS NOT NULL AND m.erase <> 'keep'
                  AND NOT EXISTS (SELECT 1 FROM public.osionos_account_erasure_objects o WHERE o.user_id = a AND o.bucket = m.object_bucket)));
  PERFORM pg_temp.p5_ok('B''s recorded keys are unchanged by A''s erase', (SELECT count(*) FROM public.osionos_account_erasure_objects WHERE user_id = b) = v_b0);
  PERFORM pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || a || ''')::text');
  SELECT count(*) INTO v_n2 FROM public.osionos_account_erasure_objects WHERE user_id = a;
  PERFORM pg_temp.p5_ok('a second erase adds none: ' || v_n1 || ' then ' || v_n2, v_n1 = v_n2);
END $$;
SELECT * FROM pg_temp.p5_row('p5_erase_objects_recorded', 7);
ROLLBACK;

-- p5_audit_scrubbed: the audit rows stay (actor and subject kept, for
-- accountability) but ip_hash and user_agent go to NULL, for the rows where the
-- user is the actor and the rows where the user is the subject. B's rows keep both.
BEGIN;
DO $$
DECLARE
  a constant uuid := 'a5a5a5a5-0000-4000-8000-00000000000a';
  b constant uuid := 'b5b5b5b5-0000-4000-8000-00000000000b';
BEGIN
  PERFORM pg_temp.p5_world();
  INSERT INTO public.osionos_bridge_audit_events (provider, subject, event_type, actor_id, ip_hash, user_agent)
  VALUES ('p5', a, 'as.subject', NULL, repeat('1', 64), 'UA-a1'), ('p5', b, 'as.actor', a, repeat('2', 64), 'UA-a2'),
         ('p5', b, 'other', b, repeat('b', 64), 'UA-b');
  UPDATE public.osionos_bridge_audit_events SET ip_hash = repeat('5', 64), user_agent = 'UA-seed' WHERE actor_id = a OR subject = a;
  PERFORM pg_temp.p5_ok('three A-rows are in the audit table before the erase', (SELECT count(*) FROM public.osionos_bridge_audit_events WHERE actor_id = a OR subject = a) >= 3);
  PERFORM pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || a || ''')::text');
  PERFORM pg_temp.p5_ok('no A audit row keeps ip_hash or user_agent: ' || (SELECT count(*) FROM public.osionos_bridge_audit_events WHERE (actor_id = a OR subject = a) AND (ip_hash IS NOT NULL OR user_agent IS NOT NULL))::text,
    NOT EXISTS (SELECT 1 FROM public.osionos_bridge_audit_events WHERE (actor_id = a OR subject = a) AND (ip_hash IS NOT NULL OR user_agent IS NOT NULL)));
  PERFORM pg_temp.p5_ok('the A audit rows still exist', (SELECT count(*) FROM public.osionos_bridge_audit_events WHERE actor_id = a OR subject = a) >= 3);
  PERFORM pg_temp.p5_ok('B''s own audit row keeps its fingerprints', EXISTS (SELECT 1 FROM public.osionos_bridge_audit_events WHERE event_type = 'other' AND ip_hash = repeat('b', 64) AND user_agent = 'UA-b'));
END $$;
SELECT * FROM pg_temp.p5_row('p5_audit_scrubbed', 4);
ROLLBACK;

-- p5_erase_sequence: the executor's order against a real database: claim -> erase
-- -> erase again -> delete the erasure-object rows -> delete auth.users, which
-- cascades the request row away. Also pins the queue contract: a claim never
-- exceeds 5, a claimed row is leased for 30 minutes and claimable again after,
-- a request with erased_at set is still claimable, and once erased_at is set the
-- account role cannot cancel (P0001 deletion_in_progress) while the cascade works.
-- Caveat: the lease clock is moved by rewriting claimed_at; the 30 minutes
-- themselves are not waited out.
BEGIN;
DO $$
DECLARE
  a constant uuid := 'a5a5a5a5-0000-4000-8000-00000000000a';
  v_r text; v_claim text; v_rows bigint;
BEGIN
  PERFORM pg_temp.p5_world();
  PERFORM pg_temp.p5_as_svc('SELECT string_agg(user_id::text, '','') FROM public.osionos_account_deletion_claim(5)', 'osionos.check.p5_c1');
  PERFORM pg_temp.p5_ok('claim returns the due user', current_setting('osionos.check.p5_c1') = a::text);
  PERFORM pg_temp.p5_ok('claimed_at is stamped', (SELECT claimed_at IS NOT NULL FROM public.osionos_account_deletion_requests WHERE user_id = a));
  PERFORM pg_temp.p5_as_svc('SELECT count(*)::text FROM public.osionos_account_deletion_claim(5)', 'osionos.check.p5_c2');
  PERFORM pg_temp.p5_ok('a leased row is not claimed again', current_setting('osionos.check.p5_c2') = '0');
  UPDATE public.osionos_account_deletion_requests SET claimed_at = now() - interval '29 minutes' WHERE user_id = a;
  PERFORM pg_temp.p5_as_svc('SELECT count(*)::text FROM public.osionos_account_deletion_claim(5)', 'osionos.check.p5_c3');
  PERFORM pg_temp.p5_ok('29 minutes in, still leased', current_setting('osionos.check.p5_c3') = '0');
  UPDATE public.osionos_account_deletion_requests SET claimed_at = now() - interval '31 minutes' WHERE user_id = a;
  PERFORM pg_temp.p5_as_svc('SELECT count(*)::text FROM public.osionos_account_deletion_claim(5)', 'osionos.check.p5_c4');
  PERFORM pg_temp.p5_ok('31 minutes in, claimable again', current_setting('osionos.check.p5_c4') = '1');
  PERFORM pg_temp.p5_ok('erase ' || pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || a || ''')::text'), true);
  PERFORM pg_temp.p5_ok('erase again ' || pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || a || ''')::text'), true);
  UPDATE public.osionos_account_deletion_requests SET claimed_at = now() - interval '31 minutes' WHERE user_id = a;
  PERFORM pg_temp.p5_as_svc('SELECT count(*)::text FROM public.osionos_account_deletion_claim(5) WHERE erased_at IS NOT NULL', 'osionos.check.p5_c5');
  PERFORM pg_temp.p5_ok('an erased request is still claimable and reports erased_at', current_setting('osionos.check.p5_c5') = '1');
  v_r := pg_temp.p5_as_acct('DELETE FROM public.osionos_account_deletion_requests WHERE user_id = ''' || a || '''', a);
  PERFORM pg_temp.p5_ok('the account role''s cancel after the erase is refused: ' || v_r, v_r = 'P0001:deletion_in_progress');
  PERFORM pg_temp.p5_ok('the request row survived the refused cancel', EXISTS (SELECT 1 FROM public.osionos_account_deletion_requests WHERE user_id = a));
  PERFORM pg_temp.p5_ok('the retry list has keys to delete', EXISTS (SELECT 1 FROM public.osionos_account_erasure_objects WHERE user_id = a));
  PERFORM pg_temp.p5_as_svc('WITH d AS (DELETE FROM public.osionos_account_erasure_objects WHERE user_id = ''' || a || ''' RETURNING 1) SELECT count(*)::text FROM d');
  PERFORM pg_temp.p5_ok('the erasure-object rows are gone', NOT EXISTS (SELECT 1 FROM public.osionos_account_erasure_objects WHERE user_id = a));
  PERFORM pg_temp.p5_ok('the request row is still there before the GoTrue delete', EXISTS (SELECT 1 FROM public.osionos_account_deletion_requests WHERE user_id = a));
  DELETE FROM auth.users WHERE id = a;
  PERFORM pg_temp.p5_ok('deleting auth.users cascaded the request row', NOT EXISTS (SELECT 1 FROM public.osionos_account_deletion_requests WHERE user_id = a));
  PERFORM pg_temp.p5_ok('... and the export jobs', NOT EXISTS (SELECT 1 FROM public.osionos_account_exports WHERE user_id = a));
END $$;
SELECT * FROM pg_temp.p5_row('p5_erase_sequence', 15);
ROLLBACK;
-- p5_export_acl: the account role may read its own export jobs and ask for one
-- (INSERT user_id, format) and nothing else: no status write, no UPDATE, no
-- DELETE, no TRUNCATE; anon and authenticated hold nothing; the registry and the
-- retry list are out of its reach; the five executor columns of the deletion
-- request are unreadable to it; and there is no object_key column to read.
-- Privileges are read from the catalog AND exercised as the role.
BEGIN;
DO $$
DECLARE
  a constant uuid := 'a5a5a5a5-0000-4000-8000-00000000000a';
  b constant uuid := 'b5b5b5b5-0000-4000-8000-00000000000b';
  v_col text; v_r text; v_role text; v_tbl text;
BEGIN
  PERFORM pg_temp.p5_world();
  DELETE FROM public.osionos_account_exports;
  INSERT INTO public.osionos_account_exports (user_id, format, status) VALUES (b, 'json', 'done');
  PERFORM pg_temp.p5_ok('account role can SELECT exports', has_table_privilege('osionos_account_user', 'public.osionos_account_exports', 'SELECT'));
  PERFORM pg_temp.p5_ok('account role can INSERT user_id', has_column_privilege('osionos_account_user', 'public.osionos_account_exports', 'user_id', 'INSERT'));
  PERFORM pg_temp.p5_ok('account role can INSERT format', has_column_privilege('osionos_account_user', 'public.osionos_account_exports', 'format', 'INSERT'));
  FOREACH v_col IN ARRAY ARRAY['id', 'status', 'requested_at', 'started_at', 'finished_at', 'expires_at', 'bytes', 'error_code'] LOOP
    PERFORM pg_temp.p5_ok('account role cannot INSERT ' || v_col, NOT has_column_privilege('osionos_account_user', 'public.osionos_account_exports', v_col, 'INSERT'));
    PERFORM pg_temp.p5_ok('account role cannot UPDATE ' || v_col, NOT has_column_privilege('osionos_account_user', 'public.osionos_account_exports', v_col, 'UPDATE'));
  END LOOP;
  PERFORM pg_temp.p5_ok('account role cannot DELETE or TRUNCATE exports', NOT has_table_privilege('osionos_account_user', 'public.osionos_account_exports', 'DELETE')
    AND NOT has_table_privilege('osionos_account_user', 'public.osionos_account_exports', 'TRUNCATE'));
  FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    FOREACH v_tbl IN ARRAY ARRAY['osionos_account_exports', 'osionos_account_data_map', 'osionos_account_erasure_objects'] LOOP
      PERFORM pg_temp.p5_ok(v_role || ' reaches nothing of ' || v_tbl, NOT has_any_column_privilege(v_role, 'public.' || v_tbl, 'SELECT,INSERT,UPDATE,REFERENCES')
        AND NOT has_table_privilege(v_role, 'public.' || v_tbl, 'DELETE,TRUNCATE,TRIGGER'));
    END LOOP;
  END LOOP;
  FOREACH v_tbl IN ARRAY ARRAY['osionos_account_data_map', 'osionos_account_erasure_objects'] LOOP
    PERFORM pg_temp.p5_ok('account role reaches nothing of ' || v_tbl, NOT has_any_column_privilege('osionos_account_user', 'public.' || v_tbl, 'SELECT,INSERT,UPDATE,REFERENCES')
      AND NOT has_table_privilege('osionos_account_user', 'public.' || v_tbl, 'DELETE,TRUNCATE,TRIGGER'));
  END LOOP;
  FOREACH v_col IN ARRAY ARRAY['claimed_at', 'attempts', 'last_error', 'erased_at', 'successor_accepted_at'] LOOP
    PERFORM pg_temp.p5_ok('account role cannot read request column ' || v_col, NOT has_column_privilege('osionos_account_user', 'public.osionos_account_deletion_requests', v_col, 'SELECT')
      AND NOT has_column_privilege('osionos_account_user', 'public.osionos_account_deletion_requests', v_col, 'INSERT'));
  END LOOP;
  PERFORM pg_temp.p5_ok('exports has no object_key column', NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'osionos_account_exports' AND column_name LIKE '%key%'));
  -- as the role
  v_r := pg_temp.p5_as_acct('INSERT INTO public.osionos_account_exports (user_id, format) VALUES (''' || a || ''', ''json'')', a);
  PERFORM pg_temp.p5_ok('own export request accepted, got ' || v_r, v_r = 'ok');
  v_r := pg_temp.p5_as_acct('INSERT INTO public.osionos_account_exports (user_id, format) VALUES (''' || b || ''', ''csv'')', a);
  PERFORM pg_temp.p5_ok('request for someone else refused (42501), got ' || v_r, v_r LIKE '42501:%');
  v_r := pg_temp.p5_as_acct('INSERT INTO public.osionos_account_exports (user_id, format, status) VALUES (''' || a || ''', ''zip'', ''done'')', a);
  PERFORM pg_temp.p5_ok('a status write refused (42501), got ' || v_r, v_r LIKE '42501:%');
  v_r := pg_temp.p5_as_acct('UPDATE public.osionos_account_exports SET format = ''csv''', a);
  PERFORM pg_temp.p5_ok('UPDATE refused (42501), got ' || v_r, v_r LIKE '42501:%');
  v_r := pg_temp.p5_as_acct('DELETE FROM public.osionos_account_exports', a);
  PERFORM pg_temp.p5_ok('DELETE refused (42501), got ' || v_r, v_r LIKE '42501:%');
  v_r := pg_temp.p5_as_acct('SELECT * FROM public.osionos_account_data_map', a);
  PERFORM pg_temp.p5_ok('registry unreadable (42501), got ' || v_r, v_r LIKE '42501:%');
  v_r := pg_temp.p5_as_acct('SELECT erased_at FROM public.osionos_account_deletion_requests', a);
  PERFORM pg_temp.p5_ok('erased_at unreadable (42501), got ' || v_r, v_r LIKE '42501:%');
  SET LOCAL ROLE osionos_account_user;
  PERFORM set_config('request.jwt.claims', format('{"sub":"%s","aud":"osionos-account","role":"osionos_account_user"}', a), true);
  PERFORM set_config('osionos.check.p5_seen', (SELECT count(*) FROM public.osionos_account_exports)::text, true);
  RESET ROLE;
  PERFORM pg_temp.p5_ok('the account role sees only its own job (1), saw ' || current_setting('osionos.check.p5_seen'), current_setting('osionos.check.p5_seen') = '1');
END $$;
SELECT * FROM pg_temp.p5_row('p5_export_acl', 40);
ROLLBACK;

-- p5_export_single_flight: one queued or running export per user, enforced by the
-- partial unique index, for the service role and for the account role; a finished
-- job does not block the next request; another user is not blocked.
BEGIN;
DO $$
DECLARE
  a constant uuid := 'a5a5a5a5-0000-4000-8000-00000000000a';
  b constant uuid := 'b5b5b5b5-0000-4000-8000-00000000000b';
  v_r text;
BEGIN
  PERFORM pg_temp.p5_world();
  DELETE FROM public.osionos_account_exports;
  v_r := pg_temp.p5_as_svc('INSERT INTO public.osionos_account_exports (user_id, format) VALUES (''' || a || ''', ''json'') RETURNING id::text');
  PERFORM pg_temp.p5_ok('first queued export ok, got ' || v_r, v_r = 'ok');
  v_r := pg_temp.p5_as_svc('INSERT INTO public.osionos_account_exports (user_id, format) VALUES (''' || a || ''', ''csv'') RETURNING id::text');
  PERFORM pg_temp.p5_ok('second queued export -> 23505, got ' || v_r, v_r LIKE '23505:%');
  v_r := pg_temp.p5_as_acct('INSERT INTO public.osionos_account_exports (user_id, format) VALUES (''' || a || ''', ''zip'')', a);
  PERFORM pg_temp.p5_ok('the account role''s second export -> 23505, got ' || v_r, v_r LIKE '23505:%');
  UPDATE public.osionos_account_exports SET status = 'running' WHERE user_id = a;
  v_r := pg_temp.p5_as_acct('INSERT INTO public.osionos_account_exports (user_id, format) VALUES (''' || a || ''', ''zip'')', a);
  PERFORM pg_temp.p5_ok('a running export blocks a new one (23505), got ' || v_r, v_r LIKE '23505:%');
  v_r := pg_temp.p5_as_acct('INSERT INTO public.osionos_account_exports (user_id, format) VALUES (''' || b || ''', ''zip'')', b);
  PERFORM pg_temp.p5_ok('another user is not blocked, got ' || v_r, v_r = 'ok');
  UPDATE public.osionos_account_exports SET status = 'done' WHERE user_id = a;
  v_r := pg_temp.p5_as_acct('INSERT INTO public.osionos_account_exports (user_id, format) VALUES (''' || a || ''', ''zip'')', a);
  PERFORM pg_temp.p5_ok('a finished export does not block the next, got ' || v_r, v_r = 'ok');
END $$;
SELECT * FROM pg_temp.p5_row('p5_export_single_flight', 6);
ROLLBACK;

-- p5_export_no_secrets: no registry export_columns entry names a secret. The
-- failing message lists the offending table.column entries. Floor: at least 25
-- registry rows carry export_columns, so an emptied registry does not pass.
-- The five auth-plane secrets are also listed by table.column, so a rename of the
-- pattern cannot let one through, and a failing row names the offender.
-- Caveat: a name match; a secret in a column called something innocent is not
-- seen, and a harmless column called "keyword" is a false alarm.
BEGIN;
DO $$
DECLARE r record;
BEGIN
  -- by name: the secret columns of the auth planes (sessions P3-2, PATs P3-3, MFA P5-1)
  FOR r IN SELECT m.table_name || '.' || c AS col
             FROM public.osionos_account_data_map m, unnest(m.export_columns) c
            WHERE c ~ '(hash|secret|token|password|recovery|totp|key|salt|ip_prefix|hmac|_enc$)'
               OR (m.table_name, c) IN (('osionos_sessions', 'refresh_hash'), ('osionos_sessions', 'ip_hash'),
                                        ('osionos_personal_access_tokens', 'token_hash'),
                                        ('osionos_mfa_totp', 'secret_enc'), ('osionos_mfa_recovery_codes', 'code_hmac'))
  LOOP
    PERFORM pg_temp.p5_ok('secret-named export column ' || r.col, false);
  END LOOP;
  -- the named list must still point at real columns, or a rename would empty it silently
  PERFORM pg_temp.p5_ok('the five named secret columns still exist (' || (
    SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public'
       AND (table_name, column_name) IN (('osionos_sessions', 'refresh_hash'), ('osionos_sessions', 'ip_hash'),
            ('osionos_personal_access_tokens', 'token_hash'), ('osionos_mfa_totp', 'secret_enc'),
            ('osionos_mfa_recovery_codes', 'code_hmac'))) || ' of 5)',
    (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public'
       AND (table_name, column_name) IN (('osionos_sessions', 'refresh_hash'), ('osionos_sessions', 'ip_hash'),
            ('osionos_personal_access_tokens', 'token_hash'), ('osionos_mfa_totp', 'secret_enc'),
            ('osionos_mfa_recovery_codes', 'code_hmac'))) = 5);
  PERFORM pg_temp.p5_ok('at least 25 registry rows carry export_columns',
    (SELECT count(*) FROM public.osionos_account_data_map WHERE export_columns IS NOT NULL) >= 25);
  PERFORM pg_temp.p5_ok('at least 100 export columns are named',
    (SELECT count(*) FROM public.osionos_account_data_map m, unnest(m.export_columns) c) >= 100);
END $$;
SELECT * FROM pg_temp.p5_row('p5_export_no_secrets', 3);
ROLLBACK;

-- p5_export_reachable: every registry row with export_columns names a table and
-- columns the service role can SELECT (the exporter reads them through PostgREST).
-- Floor: at least 25 such rows.
-- Caveat: LIMIT 0 proves the names and the grants resolve, not that the exporter's
-- row filter (by the registry column) is indexed or fast.
BEGIN;
DO $$
DECLARE r record; v_res text; v_n int := 0;
BEGIN
  FOR r IN SELECT m.table_name, m.column_name, m.export_columns FROM public.osionos_account_data_map m WHERE m.export_columns IS NOT NULL ORDER BY 1, 2 LOOP
    v_n := v_n + 1;
    v_res := pg_temp.p5_as_svc(format('SELECT 1 FROM (SELECT %s FROM public.%I LIMIT 0) s', array_to_string(r.export_columns, ', '), r.table_name)
                              || ' UNION ALL SELECT 1 FROM public.' || quote_ident(r.table_name) || ' WHERE ' || quote_ident(r.column_name) || ' IS NULL LIMIT 0');
    IF v_res <> 'ok' THEN PERFORM pg_temp.p5_ok('unreachable export ' || r.table_name || ' (' || v_res || ')', false); END IF;
  END LOOP;
  PERFORM pg_temp.p5_ok('at least 25 export rows were tried, tried ' || v_n, v_n >= 25);
END $$;
SELECT * FROM pg_temp.p5_row('p5_export_reachable', 1);
ROLLBACK;

-- p5_no_exec_grants: no function of the erasure plane is executable by PUBLIC, anon,
-- authenticated or the account role; the service role can run each (the trigger
-- function excepted: it is only ever fired by the trigger). The two functions
-- the account plane exposes on purpose (the uid helper and the username change)
-- are exempt by name, as in account_secdef_exec. Floor: nine functions.
BEGIN;
DO $$
DECLARE r record; v_role text; v_n int := 0;
BEGIN
  FOR r IN SELECT p.oid, p.oid::regprocedure::text AS sig, p.proname FROM pg_proc p
            WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'osionos\_account\_%'
              AND p.proname NOT IN ('osionos_account_uid', 'osionos_account_change_username')
  LOOP
    v_n := v_n + 1;
    FOREACH v_role IN ARRAY ARRAY['public', 'anon', 'authenticated', 'osionos_account_user'] LOOP
      IF has_function_privilege(v_role, r.oid, 'EXECUTE') THEN PERFORM pg_temp.p5_ok(v_role || ' can execute ' || r.sig, false); END IF;
    END LOOP;
    IF r.proname <> 'osionos_account_deletion_guard' AND NOT has_function_privilege('service_role', r.oid, 'EXECUTE') THEN
      PERFORM pg_temp.p5_ok('service_role cannot execute ' || r.sig, false);
    END IF;
  END LOOP;
  PERFORM pg_temp.p5_ok('at least 9 erasure-plane functions exist, found ' || v_n, v_n >= 9);
END $$;
SELECT * FROM pg_temp.p5_row('p5_no_exec_grants', 1);
ROLLBACK;
-- p5_report_survives_reporter: erasing a reporter must not lift a sanction.
-- A reported C and the report carries a ban; B reported C too. Erasing A
-- anonymises the reporter (NULL) and leaves the row, and the decision, in place.
-- Caveat: asserted for a ban on a user subject; other decision kinds share the
-- columns but are not seeded separately.
BEGIN;
DO $$
DECLARE
  a constant uuid := 'a5a5a5a5-0000-4000-8000-00000000000a';
  b constant uuid := 'b5b5b5b5-0000-4000-8000-00000000000b';
  c constant uuid := 'c5c5c5c5-0000-4000-8000-0000000000cc';
  m constant uuid := 'c5c5c5c5-0000-4000-8000-0000000000dd';
  ra constant uuid := 'c5c5c5c5-0000-4000-8000-0000000000e1';
  rb constant uuid := 'c5c5c5c5-0000-4000-8000-0000000000e2';
  v_before text; v_b_before text; v_b_after text; v_after text;
BEGIN
  PERFORM pg_temp.p5_world();
  PERFORM pg_temp.p5_user(c, 'Carl Accused'); PERFORM pg_temp.p5_user(m, 'Mod Erator');
  INSERT INTO public.osionos_user_reports (id, reporter_id, subject_user_id, subject_kind, category, status, decision, decision_until, decision_by, decision_at, decision_note)
  VALUES (ra, a, c, 'user', 'abuse', 'resolved', 'ban', now() + interval '30 days', m, now(), 'repeat offender'),
         (rb, b, c, 'user', 'abuse', 'open', NULL, NULL, NULL, NULL, NULL);
  SELECT md5(concat_ws('|', decision, decision_until, decision_by, decision_at, decision_note, subject_user_id, status)) INTO v_before
    FROM public.osionos_user_reports WHERE id = ra;
  SELECT md5(r::text) INTO v_b_before FROM public.osionos_user_reports r WHERE id = rb;
  PERFORM pg_temp.p5_ok('erase A ' || pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || a || ''')::text'), true);
  PERFORM pg_temp.p5_ok('the ban report still exists', EXISTS (SELECT 1 FROM public.osionos_user_reports WHERE id = ra));
  PERFORM pg_temp.p5_ok('its reporter is NULL', (SELECT reporter_id IS NULL FROM public.osionos_user_reports WHERE id = ra));
  SELECT md5(concat_ws('|', decision, decision_until, decision_by, decision_at, decision_note, subject_user_id, status)) INTO v_after
    FROM public.osionos_user_reports WHERE id = ra;
  PERFORM pg_temp.p5_ok('the decision, its moderator, expiry and the accused are unchanged', v_before = v_after);
  PERFORM pg_temp.p5_ok('the decision is still a ban', (SELECT decision FROM public.osionos_user_reports WHERE id = ra) = 'ban');
  SELECT md5(r::text) INTO v_b_after FROM public.osionos_user_reports r WHERE id = rb;
  PERFORM pg_temp.p5_ok('B''s report about C is untouched', v_b_before = v_b_after);
  PERFORM pg_temp.p5_ok('no report names A as reporter any more', NOT EXISTS (SELECT 1 FROM public.osionos_user_reports WHERE reporter_id = a));
  PERFORM pg_temp.p5_ok('the registry says nullify for the reporter',
    (SELECT erase FROM public.osionos_account_data_map WHERE table_name = 'osionos_user_reports' AND column_name = 'reporter_id') = 'nullify');
END $$;
SELECT * FROM pg_temp.p5_row('p5_report_survives_reporter', 8);
ROLLBACK;

-- p5_users_scrubbed: after the erase the users row holds nothing of A. Every
-- column but id, email, created_at and updated_at is NULL, the email is the
-- erased placeholder, and the row rendered as JSON (id removed) names none of
-- A's email, name, username or uuid. Non-default values are set first so a
-- column left at its default cannot hide a missed scrub.
-- Caveat: the JSON search is a text match; a value stored encoded would pass.
BEGIN;
DO $$
DECLARE
  a constant uuid := 'a5a5a5a5-0000-4000-8000-00000000000a';
  b constant uuid := 'b5b5b5b5-0000-4000-8000-00000000000b';
  v_left text; v_b_before text; v_json text;
BEGIN
  PERFORM pg_temp.p5_world();
  UPDATE public.users SET theme = 'dark-p5', notifications_enabled = false, is_email_verified = true WHERE id = a;
  SELECT md5(u::text) INTO v_b_before FROM public.users u WHERE id = b;
  PERFORM pg_temp.p5_ok('erase A ' || pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || a || ''')::text'), true);
  SELECT string_agg(k, ',') INTO v_left FROM public.users u, jsonb_each(to_jsonb(u)) e(k, v)
   WHERE u.id = a AND k NOT IN ('id', 'email', 'created_at', 'updated_at') AND v <> 'null'::jsonb;
  PERFORM pg_temp.p5_ok('every other column is NULL, left: ' || coalesce(v_left, '-'), v_left IS NULL);
  PERFORM pg_temp.p5_ok('the email is the erased placeholder', (SELECT email FROM public.users WHERE id = a) ~ '^erased-[0-9a-f]{32}@erased\.invalid$');
  SELECT (to_jsonb(u) - 'id')::text INTO v_json FROM public.users u WHERE id = a;
  PERFORM pg_temp.p5_ok('no email of A in the row', v_json NOT ILIKE '%alice-p5%');
  PERFORM pg_temp.p5_ok('no name of A in the row', v_json NOT ILIKE '%Alice%' AND v_json NOT ILIKE '%P5Canary%');
  PERFORM pg_temp.p5_ok('no username of A in the row', v_json NOT ILIKE '%alicep5%');
  PERFORM pg_temp.p5_ok('no uuid of A outside the id column', v_json NOT LIKE '%' || a::text || '%');
  PERFORM pg_temp.p5_ok('no password hash of A in the row', v_json NOT LIKE '%hash-a%');
  PERFORM pg_temp.p5_ok('B''s users row is untouched', (SELECT md5(u::text) FROM public.users u WHERE id = b) = v_b_before);
END $$;
SELECT * FROM pg_temp.p5_row('p5_users_scrubbed', 9);
ROLLBACK;

-- p5_foreign_content_null: a workspace holding a row nobody owns is not empty.
-- O is the sole member and owner of W; W has a page whose owner_id is NULL (the
-- column is nullable) and a message by a stranger. NOT IN over a NULL is NULL,
-- which counted as "no foreign content" and deleted the workspace; IS DISTINCT
-- FROM keeps it, owned by the tombstone. A message author is NOT NULL in the
-- schema, so only the page can carry the NULL.
-- Caveat: asserted for the page owner_id NULL; any other nullable author-like
-- column in the registry takes the same generic branch but is not seeded here.
BEGIN;
DO $$
DECLARE
  o constant uuid := 'c6000000-0000-4000-8000-000000000001';
  w constant uuid := 'c6000000-0000-4000-8000-0000000000a1';
  w2 constant uuid := 'c6000000-0000-4000-8000-0000000000a2';
  v_pg uuid; v_pg2 uuid;
BEGIN
  PERFORM pg_temp.p5_user(o, 'Orphan Owner', true);
  PERFORM pg_temp.p5_ws(w, o); PERFORM pg_temp.p5_ws(w2, o);
  v_pg := pg_temp.p5_page(w, o, 'private');
  UPDATE public.osionos_pages SET owner_id = NULL WHERE id = v_pg;
  PERFORM pg_temp.p5_ok('seeded page has a NULL owner', (SELECT owner_id IS NULL FROM public.osionos_pages WHERE id = v_pg));
  PERFORM pg_temp.p5_ok('erase O ' || pg_temp.p5_as_svc('SELECT public.osionos_account_erase(''' || o || ''')::text', 'osionos.check.p5_n'), true);
  PERFORM pg_temp.p5_ok('W (NULL-owner page) is kept', EXISTS (SELECT 1 FROM public.osionos_workspaces WHERE id = w));
  PERFORM pg_temp.p5_ok('W is owned by the tombstone', (SELECT owner_id FROM public.osionos_workspaces WHERE id = w) = public.osionos_account_tombstone());
  PERFORM pg_temp.p5_ok('the NULL-owner page is intact', EXISTS (SELECT 1 FROM public.osionos_pages WHERE id = v_pg AND owner_id IS NULL));
  PERFORM pg_temp.p5_ok('the empty W2 is deleted', NOT EXISTS (SELECT 1 FROM public.osionos_workspaces WHERE id = w2));
  PERFORM pg_temp.p5_ok('result says kept_orphaned 1: ' || current_setting('osionos.check.p5_n'),
    current_setting('osionos.check.p5_n') LIKE '%"kept_orphaned": 1%');
END $$;
SELECT * FROM pg_temp.p5_row('p5_foreign_content_null', 7);
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
