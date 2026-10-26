-- osionos-ai-thread-answers-migration.sql — "@AI" answers in a text channel
-- (channels v1). The AI drafts privately for the member who asked; only their
-- click posts the run's stored answer, as a message of the AI bot. This file is
-- the schema the AI service and the bridge share; both features sit behind
-- flags that default off, and nothing here writes a row.
--
-- WHAT IT ADDS
--   osionos_ai_bot_author()                 the bot's fixed author id
--   ai_runs.surface, surface_ref            the channel and message a run answers,
--                                           written only by the thread-run path
--   ai_runs.answer_message_id               the run's one assistant message
--   osionos_messages.ai_requested_by,       who asked, and the run posted; a run
--                    ai_run_id              is posted once (unique index)
--   osionos_ai_channel_context(c, u, m)     what a thread run may read, with the
--                                           channel access rule inside SQL
--   osionos_ai_thread_answers_erase_user(u) the erasure step for the asker
--
-- ORDER
--   osionos-chat-migration.sql is in ORDERED_FIRST (scripts/apply-models-migrations.sh)
--   and osionos-ai-migration.sql sorts before this file under LC_ALL=C
--   ("osionos-ai-m" < "osionos-ai-t"), so osionos_messages and ai_runs exist
--   here. The erasure registry row and the call to the erase step live in
--   osionos-account-erasure-migration.sql; the reserved names ai, ai-bot and
--   assistant in osionos-account-profiles-migration.sql (both ORDERED_LAST).
--
-- WHO REACHES WHAT
--   service_role  EXECUTE on the two functions it calls (the bridge and the AI
--                 service run as it); the erase step runs inside the erase
--   anyone else   nothing
--
-- DOWN (by hand; nothing reads these while both flags are off)
--   DROP FUNCTION IF EXISTS public.osionos_ai_thread_answers_erase_user(uuid);
--   DROP FUNCTION IF EXISTS public.osionos_ai_channel_context(uuid, uuid, uuid);
--   DROP INDEX IF EXISTS public.osionos_messages_ai_run_id_key;
--   ALTER TABLE public.osionos_messages DROP CONSTRAINT IF EXISTS osionos_messages_ai_answer_check,
--     DROP COLUMN IF EXISTS ai_run_id, DROP COLUMN IF EXISTS ai_requested_by;
--   ALTER TABLE public.ai_runs DROP CONSTRAINT IF EXISTS ai_runs_surface_check,
--     DROP COLUMN IF EXISTS answer_message_id, DROP COLUMN IF EXISTS surface_ref, DROP COLUMN IF EXISTS surface;
--   DROP FUNCTION IF EXISTS public.osionos_ai_bot_author();

-- 1. The bot. A fixed id no account holds and no identity row carries; the
-- bridge renders a message as the AI from ai_run_id, never from a name.
-- The bridge holds the same literal (apps/osionos scripts/bridge-chat-ai.mjs).
CREATE OR REPLACE FUNCTION public.osionos_ai_bot_author() RETURNS uuid
  LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT 'a1000000-0000-4000-8000-0000000000a1'::uuid $$;
-- A CHECK calls it as the writing role, so the writer needs EXECUTE.
REVOKE ALL ON FUNCTION public.osionos_ai_bot_author() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.osionos_ai_bot_author() TO service_role;

-- 2. A run bound to the message it answers (C430, C432). The bridge posts a run
-- only when surface = 'channel' names the channel it posts to, and copies the
-- one assistant message answer_message_id names, never text from the client.
ALTER TABLE public.ai_runs ADD COLUMN IF NOT EXISTS surface text;
ALTER TABLE public.ai_runs ADD COLUMN IF NOT EXISTS surface_ref jsonb;
ALTER TABLE public.ai_runs ADD COLUMN IF NOT EXISTS answer_message_id uuid;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'ai_runs_surface_check' AND conrelid = 'public.ai_runs'::regclass) THEN
    -- CASE and coalesce, not OR: a CHECK that evaluates to NULL passes, so a
    -- missing key must read false.
    ALTER TABLE public.ai_runs ADD CONSTRAINT ai_runs_surface_check CHECK (
      CASE WHEN surface IS NULL THEN surface_ref IS NULL AND answer_message_id IS NULL
           ELSE surface = 'channel' AND kind = 'text'
                AND coalesce(jsonb_typeof(surface_ref) = 'object'
                  AND (surface_ref ->> 'channelId') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                  AND (surface_ref ->> 'messageId') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', false)
      END) NOT VALID;
  END IF;
END $$;
ALTER TABLE public.ai_runs VALIDATE CONSTRAINT ai_runs_surface_check;

-- 3. The posted answer (C445). No foreign key on either column: the asker may be
-- erased (the registry tombstones ai_requested_by) and a run may be pruned while
-- its message stays. A bot row always names its run and its asker, a person's
-- row never does.
ALTER TABLE public.osionos_messages ADD COLUMN IF NOT EXISTS ai_requested_by uuid;
ALTER TABLE public.osionos_messages ADD COLUMN IF NOT EXISTS ai_run_id uuid;
CREATE UNIQUE INDEX IF NOT EXISTS osionos_messages_ai_run_id_key
  ON public.osionos_messages (ai_run_id) WHERE ai_run_id IS NOT NULL;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'osionos_messages_ai_answer_check'
                    AND conrelid = 'public.osionos_messages'::regclass) THEN
    -- NOT VALID, then VALIDATE: the scan of the existing rows runs without
    -- blocking the chat's writes.
    ALTER TABLE public.osionos_messages ADD CONSTRAINT osionos_messages_ai_answer_check CHECK (
      (ai_run_id IS NULL) = (ai_requested_by IS NULL)
      AND (author_id = public.osionos_ai_bot_author()) = (ai_run_id IS NOT NULL)) NOT VALID;
  END IF;
END $$;
ALTER TABLE public.osionos_messages VALIDATE CONSTRAINT osionos_messages_ai_answer_check;

-- 4. What a thread run may read (C441, C448, C452): the rule of the bridge's
-- requireChannelAccess (a channel member; else, in a public channel, a member of
-- its workspace), restricted to text channels, for a trigger message that is the
-- caller's own live message there. Any "no" is zero rows, so an unknown channel
-- and a forbidden one look the same. The window is the trigger's thread (root and
-- replies) or, for a top-level trigger, the channel's top-level messages: the last
-- 30 live ones up to the trigger, oldest first, so the trigger is the last row.
-- Authors become labels — You, AI, Member k by first appearance — and no id or
-- display name leaves the function.
CREATE OR REPLACE FUNCTION public.osionos_ai_channel_context(p_channel uuid, p_user uuid, p_message uuid)
RETURNS TABLE (n integer, label text, content text, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  WITH ch AS (
    SELECT c.id FROM public.osionos_channels c
     WHERE c.id = p_channel AND c.kind = 'text'
       AND (EXISTS (SELECT 1 FROM public.osionos_channel_members m
                     WHERE m.channel_id = c.id AND m.user_id = p_user)
            OR (NOT c.is_private
                AND EXISTS (SELECT 1 FROM public.osionos_workspace_members w
                             WHERE w.workspace_id = c.workspace_id AND w.user_id = p_user)))
  ), trig AS (
    SELECT x.id, x.created_at, x.thread_root_id
      FROM public.osionos_messages x JOIN ch ON ch.id = x.channel_id
     WHERE x.id = p_message AND x.author_id = p_user AND x.deleted_at IS NULL
  ), win AS (
    SELECT x.id, x.author_id, x.content, x.created_at
      FROM public.osionos_messages x CROSS JOIN trig t
     WHERE x.channel_id = p_channel AND x.deleted_at IS NULL
       AND (x.created_at, x.id) <= (t.created_at, t.id)
       AND CASE WHEN t.thread_root_id IS NULL THEN x.thread_root_id IS NULL
                ELSE x.id = t.thread_root_id OR x.thread_root_id = t.thread_root_id END
     ORDER BY x.created_at DESC, x.id DESC
     LIMIT 30
  ), others AS (
    SELECT w.author_id, row_number() OVER (ORDER BY min(w.created_at), w.author_id) AS k
      FROM win w
     WHERE w.author_id <> p_user AND w.author_id <> public.osionos_ai_bot_author()
     GROUP BY w.author_id
  )
  SELECT (row_number() OVER (ORDER BY w.created_at, w.id))::integer,
         CASE WHEN w.author_id = p_user THEN 'You'
              WHEN w.author_id = public.osionos_ai_bot_author() THEN 'AI'
              ELSE 'Member ' || o.k END,
         w.content, w.created_at
    FROM win w LEFT JOIN others o ON o.author_id = w.author_id
   ORDER BY w.created_at, w.id
$$;
REVOKE ALL ON FUNCTION public.osionos_ai_channel_context(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.osionos_ai_channel_context(uuid, uuid, uuid) TO service_role;

-- 5. Erasure of the asker (C446). An answer holds their question and often their
-- name, so it goes with them: blanked and soft-deleted. osionos_account_erase_run
-- calls this before its registry pass, which then tombstones ai_requested_by.
CREATE OR REPLACE FUNCTION public.osionos_ai_thread_answers_erase_user(p_user uuid) RETURNS bigint
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
  v_n bigint;
BEGIN
  UPDATE public.osionos_messages
     SET content = '', deleted_at = coalesce(deleted_at, now())
   WHERE ai_requested_by = p_user AND (content <> '' OR deleted_at IS NULL);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END
$$;
REVOKE ALL ON FUNCTION public.osionos_ai_thread_answers_erase_user(uuid) FROM PUBLIC;

NOTIFY pgrst, 'reload schema';
