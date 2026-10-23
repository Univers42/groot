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

-- p5_pat_column_acl: the account role's exact reach on the personal access token
-- table (P5-1-a). The published columns of the owner's own rows and nothing
-- else: token_hash is the sha256 of the secret and answers 42501, and the role
-- never writes this table — the bridge writes it through the service role
-- (ADR 0003), because the account role must not be able to write a hash.
-- The fixture is two users and one token each, inserted and rolled back here.
-- The catalog half compares the column ACL in both directions, so a privilege
-- that is missing AND one that is extra are both a failure.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
                               ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
DO $$
DECLARE
  v_missing boolean := false;
BEGIN
  BEGIN
    INSERT INTO public.osionos_personal_access_tokens
      (user_id, name, kind, scopes, token_hash, expires_at) VALUES
      ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A token', 'classic', ARRAY['pages:read'],
       repeat('a', 64), now() + interval '1 hour'),
      ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'B token', 'classic', ARRAY['pages:read'],
       repeat('b', 64), now() + interval '1 hour');
  EXCEPTION WHEN others THEN
    -- A missing table is a FAIL, not a broken check: the fixture is reported
    -- and the probes below answer "refused" for the wrong reason.
    v_missing := true;
  END;
  PERFORM set_config('osionos.check.p5_fixture', CASE WHEN v_missing THEN 'no_table' ELSE 'ok' END, true);
END $$;
DO $$
DECLARE
  v_own bigint := -1;
  v_other bigint := -1;
  v_state text := '';
BEGIN
  -- The role reads with A's claims: the uid helper turns them into a row owner.
  SET LOCAL ROLE osionos_account_user;
  PERFORM set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","aud":"osionos-account","role":"osionos_account_user"}', true);
  -- The published columns are readable, and only the owner's row is visible.
  BEGIN
    SELECT count(*) INTO v_own FROM public.osionos_personal_access_tokens WHERE id IS NOT NULL;
    SELECT count(*) INTO v_other FROM public.osionos_personal_access_tokens
     WHERE user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  EXCEPTION WHEN others THEN
    v_own := -1;
    v_other := -1;
  END;
  PERFORM set_config('osionos.check.p5_own', v_own::text, true);
  PERFORM set_config('osionos.check.p5_other', v_other::text, true);
  -- token_hash is not the role's.
  v_state := '';
  SET LOCAL ROLE osionos_account_user;
  BEGIN
    PERFORM (SELECT token_hash FROM public.osionos_personal_access_tokens LIMIT 1);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p5_hash', v_state, true);
  -- The role never writes this table.
  v_state := '';
  SET LOCAL ROLE osionos_account_user;
  BEGIN
    INSERT INTO public.osionos_personal_access_tokens
      (user_id, name, kind, scopes, token_hash, expires_at)
    VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'x', 'classic', ARRAY['pages:read'],
            repeat('c', 64), now() + interval '1 hour');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p5_insert', v_state, true);
  v_state := '';
  SET LOCAL ROLE osionos_account_user;
  BEGIN
    UPDATE public.osionos_personal_access_tokens SET name = 'x';
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p5_update', v_state, true);
  v_state := '';
  SET LOCAL ROLE osionos_account_user;
  BEGIN
    DELETE FROM public.osionos_personal_access_tokens;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p5_delete', v_state, true);
END $$;
RESET ROLE;
WITH granted(col) AS (
  SELECT unnest(ARRAY['id','user_id','name','kind','scopes','grants','created_at','expires_at',
                       'last_used_at','revoked_at','revoked_reason'])
),
t AS (SELECT to_regclass('public.osionos_personal_access_tokens') AS oid),
violations AS (
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
)
SELECT 'p5_pat_column_acl',
       (CASE WHEN current_setting('osionos.check.p5_own', true) = '1' THEN 0 ELSE 1 END)
     + (CASE WHEN current_setting('osionos.check.p5_other', true) = '0' THEN 0 ELSE 1 END)
     + (CASE WHEN current_setting('osionos.check.p5_hash', true) = '42501' THEN 0 ELSE 1 END)
     + (CASE WHEN current_setting('osionos.check.p5_insert', true) = '42501' THEN 0 ELSE 1 END)
     + (CASE WHEN current_setting('osionos.check.p5_update', true) = '42501' THEN 0 ELSE 1 END)
     + (CASE WHEN current_setting('osionos.check.p5_delete', true) = '42501' THEN 0 ELSE 1 END)
     + (SELECT count(*) FROM violations),
       'fixture=' || coalesce(current_setting('osionos.check.p5_fixture', true), 'unset')
     || ' own=' || coalesce(current_setting('osionos.check.p5_own', true), 'unset')
     || ' other=' || coalesce(current_setting('osionos.check.p5_other', true), 'unset')
     || ' hash=' || coalesce(current_setting('osionos.check.p5_hash', true), 'unset')
     || ' insert=' || coalesce(current_setting('osionos.check.p5_insert', true), 'unset')
     || ' update=' || coalesce(current_setting('osionos.check.p5_update', true), 'unset')
     || ' delete=' || coalesce(current_setting('osionos.check.p5_delete', true), 'unset')
     || ' acl=' || coalesce((SELECT string_agg(v, ' ' ORDER BY v) FROM violations), 'exact');
ROLLBACK;

-- p5_pat_row_rules: the token table's own row rules. The service role is the
-- only writer, so three rows must never exist and the table has to refuse
-- them itself: a fine-grained token that grants nothing, a classic token that
-- grants nothing, and a row that is revoked without a reason.
-- The count is the number of the three that were NOT refused with 23514. A
-- probe that fails with another SQLSTATE counts as not refused too: a row
-- that lands for the wrong reason is still a row that lands.
BEGIN;
INSERT INTO auth.users (id) VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_state text := '';
BEGIN
  -- A fine-grained token with no grant at all.
  v_state := '';
  BEGIN
    INSERT INTO public.osionos_personal_access_tokens
      (user_id, name, kind, scopes, grants, token_hash, expires_at)
    VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'neither', 'fine_grained', '{}', '[]'::jsonb,
            repeat('a', 64), now() + interval '1 hour');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p5_rule_neither', v_state, true);
  -- A classic token with no scope at all.
  v_state := '';
  BEGIN
    INSERT INTO public.osionos_personal_access_tokens
      (user_id, name, kind, scopes, grants, token_hash, expires_at)
    VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'scope', 'classic', '{}', '[]'::jsonb,
            repeat('b', 64), now() + interval '1 hour');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p5_rule_scope', v_state, true);
  -- A row that is revoked without a reason.
  v_state := '';
  BEGIN
    INSERT INTO public.osionos_personal_access_tokens
      (user_id, name, kind, scopes, grants, token_hash, expires_at, revoked_at)
    VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'revoked', 'classic', ARRAY['pages:read'], '[]'::jsonb,
            repeat('c', 64), now() + interval '1 hour', now());
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  PERFORM set_config('osionos.check.p5_rule_revoked', v_state, true);
END $$;
RESET ROLE;
SELECT 'p5_pat_row_rules',
       (CASE WHEN current_setting('osionos.check.p5_rule_neither', true) = '23514' THEN 0 ELSE 1 END)
     + (CASE WHEN current_setting('osionos.check.p5_rule_scope', true) = '23514' THEN 0 ELSE 1 END)
     + (CASE WHEN current_setting('osionos.check.p5_rule_revoked', true) = '23514' THEN 0 ELSE 1 END),
       'neither=' || coalesce(current_setting('osionos.check.p5_rule_neither', true), 'unset')
     || ' scope=' || coalesce(current_setting('osionos.check.p5_rule_scope', true), 'unset')
     || ' revoked=' || coalesce(current_setting('osionos.check.p5_rule_revoked', true), 'unset');
ROLLBACK;
-- colleague_edges_trigger: the trigger that writes the colleague edges when a
-- member joins a workspace (models/osionos-social-scale-migration.sql). The row
-- names the TABLE and the trigger, not merely "a trigger exists": the
-- migration's own backfill guard tests exactly this pair (tgrelid and tgname),
-- so a trigger under another name would leave the guard blind.
SELECT 'colleague_edges_trigger',
       CASE WHEN to_regclass('public.osionos_workspace_members') IS NULL THEN 1
            WHEN NOT EXISTS (SELECT 1 FROM pg_trigger
                              WHERE tgrelid = 'public.osionos_workspace_members'::regclass
                                AND tgname = 'osionos_workspace_members_colleague_edges_trg'
                                AND NOT tgisinternal) THEN 1
            ELSE 0 END,
       coalesce((SELECT 'pg_trigger ' || tgname FROM pg_trigger
                  WHERE tgrelid = 'public.osionos_workspace_members'::regclass
                    AND tgname = 'osionos_workspace_members_colleague_edges_trg'),
                'the colleague-edges trigger is missing');

-- feed_counts_exec_grants: the functions this package creates (feed counts, colleague edges,
-- ownership transfer) are
-- service_role's alone. The bridge calls them with the service key; anon,
-- authenticated and the account role must not execute them. A function that
-- does not exist is a violation too — the row must not pass on a missing
-- object — and so is a function that still carries the PUBLIC default: its
-- ACL is either absent (the default gives PUBLIC EXECUTE) or holds a "=X/"
-- entry. REVOKE … FROM PUBLIC is what removes it.
WITH fns(name, sig) AS (
  VALUES ('osionos_feed_page_counts', 'public.osionos_feed_page_counts(uuid, uuid)'),
         ('osionos_colleague_edges_on_join', 'public.osionos_colleague_edges_on_join()'),
         ('osionos_workspace_transfer_ownership', 'public.osionos_workspace_transfer_ownership(uuid, uuid, uuid)'),
         ('osionos_workspace_mark_delete', 'public.osionos_workspace_mark_delete(uuid, uuid, timestamptz, timestamptz)')
), fn AS (
  SELECT f.name, to_regprocedure(f.sig) AS oid FROM fns f
)
SELECT 'feed_counts_exec_grants', count(*), coalesce(string_agg(who, ' ' ORDER BY who), '')
  FROM (
    SELECT name || '_missing' AS who
      FROM fn WHERE oid IS NULL
    UNION ALL
    SELECT name || '_service_role_may_not_execute'
      FROM fn
     WHERE oid IS NOT NULL AND NOT has_function_privilege('service_role', oid, 'EXECUTE')
    UNION ALL
    SELECT name || '_' || r.rolname || '_may_execute'
      FROM fn CROSS JOIN unnest(ARRAY['anon','authenticated','osionos_account_user']) AS r(rolname)
     WHERE oid IS NOT NULL AND has_function_privilege(r.rolname, oid, 'EXECUTE')
    UNION ALL
    SELECT name || '_public_may_execute'
      FROM fn JOIN pg_proc p ON p.oid = fn.oid
     WHERE p.proacl IS NULL
        OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a
                    WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
  ) AS violations;

-- self_data_indexes_missing: the indexes the sys: self-data sources read through. The bridge
-- reads the caller's own rows scoped by owner_id and ordered by updated_at DESC, so the index
-- has to be (owner_id, updated_at DESC) — an index on owner_id alone, or one that sorts
-- updated_at ascending, is a different index here.
-- The comparison is on the whole shape, like account_indexes_missing: the key columns WITH their
-- sort order (the catalog's indoption bits), the access method, the uniqueness and the partial
-- predicate. The index name is part of the shape: the migration names it, so a renamed index
-- reads as missing.
-- Caveat: the columns are compared as the catalog renders them, so an index on an EXPRESSION
-- instead of a column is reported as missing (never as present).
WITH expected(tbl, idx, cols) AS (
  VALUES ('osionos_pages', 'osionos_pages_owner_updated_idx', 'owner_id,updated_at DESC'),
         ('osionos_tasks', 'osionos_tasks_owner_updated_idx', 'owner_id,updated_at DESC')
),
found AS (
  SELECT c.relname AS idx,
         t.relname AS tbl,
         (SELECT string_agg(a.attname || CASE WHEN (i.indoption[k.ord - 1] & 1) = 1 THEN ' DESC' ELSE '' END,
                            ',' ORDER BY k.ord)
            FROM generate_series(1, i.indnkeyatts) AS k(ord)
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[k.ord - 1]) AS cols,
         (SELECT am.amname FROM pg_opclass o JOIN pg_am am ON am.oid = o.opcmethod WHERE o.oid = i.indclass[1]) AS opclass,
         i.indisunique AS uniq,
         i.indpred IS NULL AS plain,
         i.indnatts = i.indnkeyatts AS key_only
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid
    JOIN pg_class t ON t.oid = i.indrelid
    JOIN pg_namespace ns ON ns.oid = t.relnamespace AND ns.nspname = 'public'
)
SELECT 'self_data_indexes_missing', count(*), coalesce(string_agg(e.tbl || '.' || e.idx, ' ' ORDER BY e.tbl), '')
  FROM expected e
 WHERE NOT EXISTS (SELECT 1 FROM found f
                    WHERE f.idx = e.idx AND f.tbl = e.tbl
                      AND f.cols = e.cols AND f.opclass = 'btree'
                      AND f.uniq = false AND f.plain AND f.key_only);

-- moderation_columns: the five decision columns exist on osionos_user_reports, the decision
-- CHECK admits exactly warn/suspend/ban/dismiss (no more, no fewer), the state-lookup index
-- exists, and anon/authenticated reach neither the table nor any of its columns.
SELECT 'moderation_columns',
       (SELECT count(*) FROM unnest(ARRAY['decision','decision_until','decision_by','decision_at','decision_note']) AS col
         WHERE NOT EXISTS (SELECT 1 FROM pg_attribute a
                            WHERE a.attrelid = to_regclass('public.osionos_user_reports')
                              AND a.attname = col AND a.attnum > 0 AND NOT a.attisdropped))
     + (SELECT count(*) FROM unnest(ARRAY['warn','suspend','ban','dismiss']) AS v
         WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c
                            WHERE c.conname = 'osionos_user_reports_decision_check'
                              AND pg_get_constraintdef(c.oid) LIKE '%''' || v || '''%'))
     + (SELECT count(*) FROM pg_constraint c
         WHERE c.conname = 'osionos_user_reports_decision_check'
           AND (SELECT count(*) FROM regexp_matches(pg_get_constraintdef(c.oid), '''[a-z]+''', 'g')) <> 4)
     + (to_regclass('public.osionos_user_reports_subject_decision_idx') IS NULL)::int
     + (SELECT count(*) FROM (VALUES ('anon'),('authenticated')) AS x(rolname)
         CROSS JOIN (VALUES ('SELECT',true),('INSERT',true),('UPDATE',true),('REFERENCES',true),
                            ('DELETE',false),('TRUNCATE',false),('TRIGGER',false)) AS p(priv, col_level)
        WHERE has_table_privilege(x.rolname, 'public.osionos_user_reports', p.priv)
           OR (p.col_level AND has_any_column_privilege(x.rolname, 'public.osionos_user_reports', p.priv))),
       '';

-- audit_viewer_index: the audit viewer's keyset page (provider, created_at DESC, id DESC) has
-- its index. Counts 1 when it is missing.
SELECT 'audit_viewer_index',
       (to_regclass('public.osionos_bridge_audit_events_provider_created_idx') IS NULL)::int,
       '';

-- lifecycle_fn_settings: the two workspace-lifecycle functions run as the caller (not
-- SECURITY DEFINER) and pin search_path and lock_timeout. Counts every function that is missing,
-- is prosecdef, or lacks either setting.
SELECT 'lifecycle_fn_settings', count(*), coalesce(string_agg(name, ' ' ORDER BY name), '')
  FROM (
    SELECT f.name
      FROM (VALUES ('osionos_workspace_transfer_ownership', 'public.osionos_workspace_transfer_ownership(uuid, uuid, uuid)'),
                   ('osionos_workspace_mark_delete', 'public.osionos_workspace_mark_delete(uuid, uuid, timestamptz, timestamptz)'))
           AS f(name, sig)
      LEFT JOIN pg_proc p ON p.oid = to_regprocedure(f.sig)
     WHERE p.oid IS NULL
        OR p.prosecdef
        OR NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) c WHERE c LIKE 'search_path=%')
        OR NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) c WHERE c LIKE 'lock_timeout=%')
  ) AS violations;

-- lifecycle_*: the behaviour of osionos_workspace_mark_delete and _transfer_ownership, which the
-- bridge tests only stub. One row per check, 0 = holds; the detail names what came back. Fixture
-- inside BEGIN..ROLLBACK. Two live workspaces for the owner (W1, W2), one foreign (W3).
BEGIN;
INSERT INTO public.osionos_workspaces (id, owner_id, name, slug) VALUES
  ('e1e1e1e1-0000-4000-8000-000000000001', 'e1e1e1e1-0000-4000-8000-0000000000a1', 'lc1', 'lc-1'),
  ('e1e1e1e1-0000-4000-8000-000000000002', 'e1e1e1e1-0000-4000-8000-0000000000a1', 'lc2', 'lc-2'),
  ('e1e1e1e1-0000-4000-8000-000000000003', 'e1e1e1e1-0000-4000-8000-0000000000b2', 'lc3', 'lc-3');
INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role) VALUES
  ('e1e1e1e1-0000-4000-8000-000000000001', 'e1e1e1e1-0000-4000-8000-0000000000a1', 'owner'),
  ('e1e1e1e1-0000-4000-8000-000000000001', 'e1e1e1e1-0000-4000-8000-0000000000c3', 'editor'),
  ('e1e1e1e1-0000-4000-8000-000000000002', 'e1e1e1e1-0000-4000-8000-0000000000a1', 'owner');

SELECT 'lifecycle_mark_first', (r IS DISTINCT FROM 'marked')::int, 'first mark returned ' || coalesce(r, 'NULL')
  FROM (SELECT public.osionos_workspace_mark_delete('e1e1e1e1-0000-4000-8000-000000000001',
          'e1e1e1e1-0000-4000-8000-0000000000a1', '2030-01-01', '2030-01-15') AS r) s;
SELECT 'lifecycle_mark_last_workspace', (r IS DISTINCT FROM 'last_workspace')::int,
       'marking the only live workspace returned ' || coalesce(r, 'NULL')
  FROM (SELECT public.osionos_workspace_mark_delete('e1e1e1e1-0000-4000-8000-000000000002',
          'e1e1e1e1-0000-4000-8000-0000000000a1', '2030-01-02', '2030-01-16') AS r) s;
SELECT 'lifecycle_mark_not_owner', (r IS DISTINCT FROM 'not_owner')::int,
       'a non-owner mark returned ' || coalesce(r, 'NULL')
  FROM (SELECT public.osionos_workspace_mark_delete('e1e1e1e1-0000-4000-8000-000000000002',
          'e1e1e1e1-0000-4000-8000-0000000000b2', '2030-01-02', '2030-01-16') AS r) s;
SELECT 'lifecycle_mark_already_pending', (r IS DISTINCT FROM 'already_pending')::int,
       'a second mark inside the grace returned ' || coalesce(r, 'NULL')
  FROM (SELECT public.osionos_workspace_mark_delete('e1e1e1e1-0000-4000-8000-000000000001',
          'e1e1e1e1-0000-4000-8000-0000000000a1', '2030-01-05', '2030-01-19') AS r) s;
-- C10: once delete_after has passed with no sweep, the mark is taken again with fresh stamps.
-- A fourth workspace for the owner keeps the "not the last live one" premise true.
INSERT INTO public.osionos_workspaces (id, owner_id, name, slug)
  VALUES ('e1e1e1e1-0000-4000-8000-000000000004', 'e1e1e1e1-0000-4000-8000-0000000000a1', 'lc4', 'lc-4');
SELECT 'lifecycle_mark_restamp', (r IS DISTINCT FROM 'marked'
         OR (SELECT pending_delete_at <> '2030-02-01' OR delete_after <> '2030-02-15'
               FROM public.osionos_workspaces WHERE id = 'e1e1e1e1-0000-4000-8000-000000000001'))::int,
       'a mark after delete_after returned ' || coalesce(r, 'NULL') || ' (stamps must be the new ones)'
  FROM (SELECT public.osionos_workspace_mark_delete('e1e1e1e1-0000-4000-8000-000000000001',
          'e1e1e1e1-0000-4000-8000-0000000000a1', '2030-02-01', '2030-02-15') AS r) s;
-- C14: W1 is pending, so ownership cannot move; W2 is live and can.
SELECT 'lifecycle_transfer_refused_pending', (r IS DISTINCT FROM false)::int,
       'transfer on a pending-delete workspace returned ' || coalesce(r::text, 'NULL')
  FROM (SELECT public.osionos_workspace_transfer_ownership('e1e1e1e1-0000-4000-8000-000000000001',
          'e1e1e1e1-0000-4000-8000-0000000000a1', 'e1e1e1e1-0000-4000-8000-0000000000c3') AS r) s;
INSERT INTO public.osionos_workspace_members (workspace_id, user_id, role)
  VALUES ('e1e1e1e1-0000-4000-8000-000000000002', 'e1e1e1e1-0000-4000-8000-0000000000c3', 'editor');
SELECT 'lifecycle_transfer_ok', (r IS DISTINCT FROM true)::int,
       'transfer to a member returned ' || coalesce(r::text, 'NULL')
  FROM (SELECT public.osionos_workspace_transfer_ownership('e1e1e1e1-0000-4000-8000-000000000002',
          'e1e1e1e1-0000-4000-8000-0000000000a1', 'e1e1e1e1-0000-4000-8000-0000000000c3') AS r) s;
SELECT 'lifecycle_transfer_one_owner',
       ((SELECT count(*) FROM public.osionos_workspace_members
          WHERE workspace_id = 'e1e1e1e1-0000-4000-8000-000000000002' AND role = 'owner') <> 1
        OR (SELECT owner_id FROM public.osionos_workspaces WHERE id = 'e1e1e1e1-0000-4000-8000-000000000002')
             IS DISTINCT FROM 'e1e1e1e1-0000-4000-8000-0000000000c3'
        OR (SELECT role FROM public.osionos_workspace_members
             WHERE workspace_id = 'e1e1e1e1-0000-4000-8000-000000000002'
               AND user_id = 'e1e1e1e1-0000-4000-8000-0000000000a1') IS DISTINCT FROM 'admin')::int,
       'after a transfer: exactly one owner row, owner_id = the new owner, the old owner is admin';
ROLLBACK;
