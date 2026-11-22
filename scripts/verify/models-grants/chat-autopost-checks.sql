-- ap1 the channel auto-post opt-in (models/osionos-chat-ai-autopost-migration.sql):
-- osionos_channels.ai_autopost is a boolean, NOT NULL, DEFAULT false (OB2: a channel
-- auto-posts only after an admin turned it on); a new channel reads false; a NULL is
-- refused (23502); service_role, which the bridge runs as, may turn it on; anon and
-- authenticated may not touch it (42501).
-- Piped between checks.sql and account-checks.sql (run_checks), so account-checks'
-- isolation rows stay last.
-- Caveat: the fixtures are hand-built rows that roll back, not a channel the bridge made.
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.ap_try(p_sql text, p_role text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v_state text;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_role);
  BEGIN
    EXECUTE p_sql;
    v_state := 'ok';
  EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  RESET ROLE;
  RETURN v_state;
END
$$;
INSERT INTO public.osionos_workspaces (id, owner_id, name, slug)
  VALUES ('e5e5e5e5-0000-4000-8000-000000000001', 'e5e5e5e5-0000-4000-8000-0000000000a1', 'ap', 'ap-1');
INSERT INTO public.osionos_channels (id, workspace_id, kind, name)
  VALUES ('e5e5e5e5-0000-4000-8000-0000000000c1', 'e5e5e5e5-0000-4000-8000-000000000001', 'text', 'ap');
DO $$
DECLARE
  upd text := 'UPDATE public.osionos_channels SET ai_autopost = %s WHERE id = ''e5e5e5e5-0000-4000-8000-0000000000c1''';
  r text[] := ARRAY[]::text[];
  shape text;
BEGIN
  SELECT data_type || '/' || is_nullable || '/' || coalesce(column_default, 'none') INTO shape
    FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'osionos_channels' AND column_name = 'ai_autopost';
  r := r || ('shape=' || coalesce(shape, 'missing'));
  IF shape IS NOT NULL THEN
    EXECUTE 'SELECT ''new_row='' || ai_autopost::text FROM public.osionos_channels WHERE id = ''e5e5e5e5-0000-4000-8000-0000000000c1''' INTO shape;
    r := r || shape;
  END IF;
  r := r || ('null=' || pg_temp.ap_try(format(upd, 'NULL'), 'service_role'));
  r := r || ('service_on=' || pg_temp.ap_try(format(upd, 'true'), 'service_role'));
  r := r || ('anon=' || pg_temp.ap_try(format(upd, 'true'), 'anon'));
  r := r || ('authenticated=' || pg_temp.ap_try(format(upd, 'true'), 'authenticated'));
  PERFORM set_config('osionos.check.ap', array_to_string(r, ' '), true);
END $$;
SELECT 'chat_ai_autopost',
       (SELECT count(*) FROM unnest(string_to_array(current_setting('osionos.check.ap', true), ' ')) AS x(v)
         WHERE v NOT IN ('shape=boolean/NO/false', 'new_row=false', 'null=23502', 'service_on=ok',
                         'anon=42501', 'authenticated=42501'))
     + (CASE WHEN array_length(string_to_array(current_setting('osionos.check.ap', true), ' '), 1) = 6 THEN 0 ELSE 1 END),
       coalesce(current_setting('osionos.check.ap', true), 'unset');
ROLLBACK;
