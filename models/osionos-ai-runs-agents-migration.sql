-- ai_agents — custom agents of the osionos assistant (D3): a named, versioned
-- instruction + tool subset + built-in skills, written by a user (user scope)
-- or published by a workspace admin (workspace scope). Prompt-shaping content,
-- so the file carries the devil's conditions (records: d3-agents-verdict.md).
--
--   C310  ai_runs gets custom_agent_id / custom_agent_version and a CHECK added
--         NOT VALID, then VALIDATE CONSTRAINT as its own top-level statement
--         (never inside a DO), under lock_timeout. Replay is a no-op.
--   C311  the name sorts AFTER osionos-ai-migration.sql, which creates ai_runs
--         ("runs" > "migration" under LC_ALL=C). scripts/verify/ai-agents.sh
--         holds the order; so does the service's migrations list test.
--   C312  all three tables are service_role-only: RLS on, one service_role
--         policy, REVOKE ALL from PUBLIC/anon/authenticated (C43).
--   C337  the second branch of the CHECK says custom_agent_version IS NOT NULL:
--         without it (id set, version NULL) evaluates to NULL and a CHECK
--         accepts NULL. ai_runs_agent_check (built-ins) has the same shape of
--         hole and is NOT edited here (backward compatible).
--   C338  erasure ships with the tables. ai_agents_erase_user(uuid) deletes the
--         user-scope agents and their audit, and TOMBSTONES the user in the
--         workspace-scope agents, the settings and the audit (keys are never
--         deleted, so a pinned version still parses). The audit's append-only
--         trigger is lifted only by osionos.agent_erase, which only that
--         SECURITY DEFINER function sets, for its own call. ai_erase_user()
--         calls it through a guarded to_regprocedure (osionos-user-events-
--         migration.sql); the data-map rows are in osionos-account-erasure-
--         migration.sql. The audit is never `keep`.
--
-- Who may write, and the caps of 20 user / 8 workspace agents, are the
-- SERVICE's rules: the database cannot know the caller or count atomically.
--
-- Caveat: the append-only trigger is bypassed by a superuser who disables it
-- or sets session_replication_role = replica; service_role can do neither.
-- Caveat: the scrub replaces the erased uuid in the TEXT of before/after; a
-- uuid typed by an author inside their own instructions is replaced too.
--
-- Lock-safe: new tables, two nullable columns on ai_runs (metadata-only), and a
-- lock_timeout so an ALTER gives up rather than queue behind a long
-- transaction and stall every run.
--
-- Idempotent: IF NOT EXISTS / DROP ... IF EXISTS / CREATE OR REPLACE, replayed
-- on every boot. Never deletes or rewrites a row.

SET lock_timeout = '5s';

-- -----------------------------------------------------------------------------
-- 1. The agents.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_agents (
	id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
	scope        text        NOT NULL CHECK (scope IN ('user', 'workspace')),
	owner_id     uuid,
	workspace_id uuid,
	name         text        NOT NULL CHECK (char_length(name) BETWEEN 1 AND 48),
	description  text        NOT NULL DEFAULT '' CHECK (char_length(description) <= 200),
	instructions text        NOT NULL CHECK (char_length(instructions) BETWEEN 1 AND 1500),
	tools        text[]      NOT NULL DEFAULT '{}'
		CHECK (cardinality(tools) <= 64 AND array_to_string(tools, ',') !~ '(^|,)mcp_'),
	skills       text[]      NOT NULL DEFAULT '{}' CHECK (cardinality(skills) <= 5),
	version      integer     NOT NULL DEFAULT 1 CHECK (version >= 1),
	created_by   uuid        NOT NULL,
	updated_by   uuid        NOT NULL,
	archived_at  timestamptz,
	created_at   timestamptz NOT NULL DEFAULT now(),
	updated_at   timestamptz NOT NULL DEFAULT now(),
	CONSTRAINT ai_agents_scope_owner_check CHECK (
		(scope = 'user' AND owner_id IS NOT NULL AND workspace_id IS NULL)
		OR (scope = 'workspace' AND workspace_id IS NOT NULL AND owner_id IS NULL))
);

CREATE INDEX IF NOT EXISTS ai_agents_owner_idx
	ON public.ai_agents (owner_id) WHERE scope = 'user' AND archived_at IS NULL;
CREATE INDEX IF NOT EXISTS ai_agents_workspace_idx
	ON public.ai_agents (workspace_id) WHERE scope = 'workspace' AND archived_at IS NULL;

COMMENT ON TABLE public.ai_agents IS
	'Custom agents (D3): instructions + tool subset + built-in skills. Prompt-shaping content: every write has a row in ai_agents_audit, version bumps on every write. service_role only.';

-- -----------------------------------------------------------------------------
-- 2. The audit: append-only, except inside the erasure (C338).
--    `after` holds the whole row, which is how a run pinned to version N loads
--    version N after an edit or an archive.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_agents_audit (
	id       bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	agent_id uuid        NOT NULL,
	version  integer     NOT NULL,
	action   text        NOT NULL CHECK (action IN ('create', 'update', 'archive')),
	actor_id uuid        NOT NULL,
	at       timestamptz NOT NULL DEFAULT now(),
	before   jsonb,
	after    jsonb
);

CREATE UNIQUE INDEX IF NOT EXISTS ai_agents_audit_agent_version_idx
	ON public.ai_agents_audit (agent_id, version) WHERE action IN ('create', 'update');
CREATE INDEX IF NOT EXISTS ai_agents_audit_agent_idx
	ON public.ai_agents_audit (agent_id, id);

CREATE OR REPLACE FUNCTION public.ai_agents_audit_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
	IF coalesce(current_setting('osionos.agent_erase', true), '') = 'on' THEN
		IF TG_OP = 'DELETE' THEN
			RETURN OLD;
		END IF;
		IF TG_OP = 'UPDATE' THEN
			RETURN NEW;
		END IF;
		RETURN NULL;
	END IF;
	RAISE EXCEPTION 'ai_agents_audit is append-only: % is refused', TG_OP;
END $$;

DROP TRIGGER IF EXISTS ai_agents_audit_append_only ON public.ai_agents_audit;
CREATE TRIGGER ai_agents_audit_append_only
	BEFORE UPDATE OR DELETE ON public.ai_agents_audit
	FOR EACH ROW EXECUTE FUNCTION public.ai_agents_audit_guard();

DROP TRIGGER IF EXISTS ai_agents_audit_no_truncate ON public.ai_agents_audit;
CREATE TRIGGER ai_agents_audit_no_truncate
	BEFORE TRUNCATE ON public.ai_agents_audit
	FOR EACH STATEMENT EXECUTE FUNCTION public.ai_agents_audit_guard();

COMMENT ON TABLE public.ai_agents_audit IS
	'Append-only audit of ai_agents: one row per write, with the whole row before and after. UPDATE, DELETE and TRUNCATE are refused by a trigger; only ai_agents_erase_user() lifts it.';

-- -----------------------------------------------------------------------------
-- 3. The server-side switches (design B4). The client store is a cache, never
--    authority. Defaults fail closed for user agents of non-admins.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_workspace_agent_settings (
	workspace_id          uuid        PRIMARY KEY,
	agents_enabled        boolean     NOT NULL DEFAULT true,
	custom_agents_allowed boolean     NOT NULL DEFAULT false,
	updated_by            uuid,
	updated_at            timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.ai_workspace_agent_settings IS
	'Per-workspace switches for custom agents (D3 B4). Read by the service at run time; service_role only.';

-- -----------------------------------------------------------------------------
-- 4. The pin on the run, and its CHECK (C310, C337).
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_runs ADD COLUMN IF NOT EXISTS custom_agent_id uuid;
ALTER TABLE public.ai_runs ADD COLUMN IF NOT EXISTS custom_agent_version integer;

DO $$
BEGIN
	IF NOT EXISTS (SELECT 1 FROM pg_constraint
	                WHERE conrelid = 'public.ai_runs'::regclass
	                  AND conname = 'ai_runs_custom_agent_check') THEN
		ALTER TABLE public.ai_runs ADD CONSTRAINT ai_runs_custom_agent_check CHECK (
			(custom_agent_id IS NULL AND custom_agent_version IS NULL)
			OR (custom_agent_id IS NOT NULL
				AND custom_agent_version IS NOT NULL
				AND custom_agent_version >= 1
				AND agent_id IS NULL
				AND agent_version IS NULL)
		) NOT VALID;
	END IF;
END $$;

-- Top level on purpose: the runner applies each statement on its own, so the
-- scan does not hold the ADD CONSTRAINT lock.
ALTER TABLE public.ai_runs VALIDATE CONSTRAINT ai_runs_custom_agent_check;

-- -----------------------------------------------------------------------------
-- 5. The erasure (C338).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_agents_erase_user(p_user uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
-- On for THIS CALL only (a function SET clause is restored on return).
SET osionos.agent_erase = 'on'
AS $$
DECLARE
	-- osionos_account_tombstone(): copied, not called, so this file does not
	-- depend on the order of osionos-account-erasure-migration.sql.
	tomb CONSTANT uuid := '00000000-0000-4000-8000-000000000000';
	n integer;
BEGIN
	-- User scope: the agent and its history go with the person.
	DELETE FROM public.ai_agents_audit
	 WHERE agent_id IN (SELECT id FROM public.ai_agents WHERE scope = 'user' AND owner_id = p_user);
	DELETE FROM public.ai_agents WHERE scope = 'user' AND owner_id = p_user;
	GET DIAGNOSTICS n = ROW_COUNT;

	-- Workspace scope outlives its author: the author becomes the tombstone.
	UPDATE public.ai_agents SET created_by = tomb WHERE created_by = p_user;
	UPDATE public.ai_agents SET updated_by = tomb WHERE updated_by = p_user;
	UPDATE public.ai_workspace_agent_settings SET updated_by = tomb WHERE updated_by = p_user;
	-- The audit is scrubbed, never deleted: the uuid becomes the tombstone in
	-- the actor and inside the saved rows, every key stays.
	UPDATE public.ai_agents_audit
	   SET actor_id = CASE WHEN actor_id = p_user THEN tomb ELSE actor_id END,
	       before = replace(before::text, p_user::text, tomb::text)::jsonb,
	       after = replace(after::text, p_user::text, tomb::text)::jsonb
	 WHERE actor_id = p_user
	    OR before::text LIKE '%' || p_user::text || '%'
	    OR after::text LIKE '%' || p_user::text || '%';
	RETURN n;
END $$;

COMMENT ON FUNCTION public.ai_agents_erase_user(uuid) IS
	'Deletes the user-scope agents of the user and their audit, tombstones the user in everything workspace-scoped; returns the number of agents deleted. Called by ai_erase_user() when this file is applied.';

-- -----------------------------------------------------------------------------
-- 6. service_role only (C312, C43).
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_agents                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_agents_audit             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_workspace_agent_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_agents_service_role_all ON public.ai_agents;
CREATE POLICY ai_agents_service_role_all ON public.ai_agents
	FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

DROP POLICY IF EXISTS ai_agents_audit_service_role_all ON public.ai_agents_audit;
CREATE POLICY ai_agents_audit_service_role_all ON public.ai_agents_audit
	FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

DROP POLICY IF EXISTS ai_workspace_agent_settings_service_role_all ON public.ai_workspace_agent_settings;
CREATE POLICY ai_workspace_agent_settings_service_role_all ON public.ai_workspace_agent_settings
	FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

-- The audit gets SELECT and INSERT only; the trigger is what makes it append-only.
GRANT SELECT, INSERT, UPDATE ON public.ai_agents TO service_role;
GRANT SELECT, INSERT ON public.ai_agents_audit TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.ai_workspace_agent_settings TO service_role;

REVOKE ALL ON public.ai_agents                   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.ai_agents_audit             FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.ai_workspace_agent_settings FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_agents_audit_guard()      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_agents_erase_user(uuid)   FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ai_agents_erase_user(uuid) TO service_role;

RESET lock_timeout;

NOTIFY pgrst, 'reload schema';
