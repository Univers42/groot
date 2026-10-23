-- ai_memories — user memories of the osionos assistant (P5d-1): a short fact,
-- preference or convention the agent PROPOSES with `remember`, the user
-- APPROVES, and every later run of that user in that workspace sees as quoted
-- data in the user turn.
--
-- A memory is PROMPT-SHAPING CONTENT, so the file carries the devil's
-- conditions (records: p5-verdict-reconstructed.md):
--   C40  every write is audited and versioned: ai_memory_audit holds one row per
--        write (actor, action, at, before, after), and the memories a run used
--        are pinned on ai_runs.memory_pins (id + version), because tool results
--        and prompts are not stored and the pin needs a durable home.
--   C41  a memory belongs to ONE user in ONE workspace and shapes only that
--        user's runs there; "only the owner approves" is the SERVICE's rule
--        (where id = $1 and user_id = $2). The database cannot know the caller.
--   C43  both tables are service_role-only: RLS on, one service_role policy,
--        REVOKE ALL from PUBLIC/anon/authenticated.
--   C47  body is capped by a CHECK at 300 characters. The counts (20 proposed,
--        50 approved per user and workspace) are the service's, in the write
--        transaction.
--
-- ai_memory_audit is APPEND-ONLY: a BEFORE UPDATE OR DELETE row trigger and a
-- BEFORE TRUNCATE statement trigger raise, unless the erasure switch
-- (osionos.memory_erase = 'on') is set. Only ai_memory_erase_user() sets it,
-- for its own call: a person asked to be erased. Same shape as
-- ai_moderation_events (osionos-ugc-moderation-migration.sql).
--
-- Caveat: the trigger is bypassed by a superuser who disables it
-- (ALTER TABLE ... DISABLE TRIGGER) or sets session_replication_role = replica;
-- service_role cannot do either, and it holds only SELECT and INSERT on the audit.
--
-- Lock-safe: two new tables, one nullable column on ai_runs (metadata-only); a
-- lock_timeout makes the ALTER give up rather than queue behind a long
-- transaction and stall every run.
--
-- Idempotent: IF NOT EXISTS / DROP ... IF EXISTS / CREATE OR REPLACE, replayed
-- on every boot. Never deletes or rewrites a row. ai_erase_user() calls
-- ai_memory_erase_user() DYNAMICALLY (osionos-user-events-migration.sql), so
-- the two files work in either order.
--
-- NAMED to sort after osionos-ai-migration.sql, which creates ai_runs (the
-- memory_pins column below): the models runner applies osionos-ai-*.sql in its
-- alphabetical pass (scripts/apply-models-migrations.sh), and "memory" sorts
-- before "migration", so that name failed on a fresh database.
-- scripts/verify/ai-memory.sh check f holds the order.

SET lock_timeout = '5s';

-- -----------------------------------------------------------------------------
-- 1. The memories.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_memories (
	id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
	user_id         uuid        NOT NULL,
	workspace_id    uuid        NOT NULL,
	body            text        NOT NULL CHECK (char_length(body) BETWEEN 1 AND 300),
	status          text        NOT NULL CHECK (status IN ('proposed', 'approved', 'rejected', 'archived')),
	version         integer     NOT NULL DEFAULT 1 CHECK (version >= 1),
	proposed_run_id uuid,
	created_at      timestamptz NOT NULL DEFAULT now(),
	updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ai_memories_user_workspace_status_idx
	ON public.ai_memories (user_id, workspace_id, status);

COMMENT ON TABLE public.ai_memories IS
	'User memories (P5d-1): proposed by the agent, approved by the owner, quoted as data in that user''s prompts. Prompt-shaping content: every write has a row in ai_memory_audit. service_role only.';

-- -----------------------------------------------------------------------------
-- 2. The audit (C40): append-only, except inside the erasure.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_memory_audit (
	id        bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	memory_id uuid        NOT NULL,
	actor_id  uuid        NOT NULL,
	action    text        NOT NULL CHECK (action IN ('propose', 'approve', 'reject', 'edit', 'archive')),
	at        timestamptz NOT NULL DEFAULT now(),
	before    jsonb,
	after     jsonb
);

CREATE INDEX IF NOT EXISTS ai_memory_audit_memory_idx
	ON public.ai_memory_audit (memory_id, id);

CREATE OR REPLACE FUNCTION public.ai_memory_audit_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
	IF coalesce(current_setting('osionos.memory_erase', true), '') = 'on' THEN
		IF TG_OP = 'DELETE' THEN
			RETURN OLD;
		END IF;
		IF TG_OP = 'UPDATE' THEN
			RETURN NEW;
		END IF;
		RETURN NULL;
	END IF;
	RAISE EXCEPTION 'ai_memory_audit is append-only: % is refused', TG_OP;
END $$;

DROP TRIGGER IF EXISTS ai_memory_audit_append_only ON public.ai_memory_audit;
CREATE TRIGGER ai_memory_audit_append_only
	BEFORE UPDATE OR DELETE ON public.ai_memory_audit
	FOR EACH ROW EXECUTE FUNCTION public.ai_memory_audit_guard();

DROP TRIGGER IF EXISTS ai_memory_audit_no_truncate ON public.ai_memory_audit;
CREATE TRIGGER ai_memory_audit_no_truncate
	BEFORE TRUNCATE ON public.ai_memory_audit
	FOR EACH STATEMENT EXECUTE FUNCTION public.ai_memory_audit_guard();

COMMENT ON TABLE public.ai_memory_audit IS
	'Append-only audit of ai_memories (C40): one row per write, with the whole row before and after. UPDATE, DELETE and TRUNCATE are refused by a trigger; only ai_memory_erase_user() lifts it.';

-- -----------------------------------------------------------------------------
-- 3. The pin on the run (C40): [{id, version}], one entry per approved memory
--    the run put in its user turn. NULL = the run used none.
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_runs ADD COLUMN IF NOT EXISTS memory_pins jsonb;

-- -----------------------------------------------------------------------------
-- 4. The erasure: the user's memories and their audit rows.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_memory_erase_user(p_user uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
-- On for THIS CALL only (a function SET clause is restored on return).
SET osionos.memory_erase = 'on'
AS $$
DECLARE
	n integer;
BEGIN
	DELETE FROM public.ai_memory_audit
	 WHERE memory_id IN (SELECT id FROM public.ai_memories WHERE user_id = p_user)
	    OR actor_id = p_user;
	DELETE FROM public.ai_memories WHERE user_id = p_user;
	GET DIAGNOSTICS n = ROW_COUNT;
	RETURN n;
END $$;

COMMENT ON FUNCTION public.ai_memory_erase_user(uuid) IS
	'Deletes every memory of the user and its audit rows; returns the number of memories deleted. Called by ai_erase_user() when this file is applied.';

-- -----------------------------------------------------------------------------
-- 5. service_role only (C43).
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_memories     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_memory_audit ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_memories_service_role_all ON public.ai_memories;
CREATE POLICY ai_memories_service_role_all ON public.ai_memories
	FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

DROP POLICY IF EXISTS ai_memory_audit_service_role_all ON public.ai_memory_audit;
CREATE POLICY ai_memory_audit_service_role_all ON public.ai_memory_audit
	FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

GRANT SELECT, INSERT, UPDATE ON public.ai_memories TO service_role;
GRANT SELECT, INSERT ON public.ai_memory_audit TO service_role;

REVOKE ALL ON public.ai_memories     FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.ai_memory_audit FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_memory_audit_guard() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_memory_erase_user(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ai_memory_erase_user(uuid) TO service_role;

RESET lock_timeout;

NOTIFY pgrst, 'reload schema';
