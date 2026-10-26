-- The web tools of the osionos assistant (web_search, web_fetch): the two
-- pieces of state they need in the database. Everything else (the per-run
-- caps, the provenance of the URLs, the rate buckets) lives in the service and
-- in Redis.
--
--   C358  the web TAINT of a conversation: ai_conversations gets web_tainted_at
--         and web_domains. The service writes them BEFORE a web result reaches
--         the model, so a crash cannot lose the mark, and a continuation run
--         (a new run in the same conversation) reads it back. The columns die
--         with the conversation row.
--   C359  web_domains holds at most 5 domains: the approval card names at
--         most 5 ("influenced by"), so the database keeps no more than that.
--   C370  the per-workspace switch "Allow web access": ai_workspace_web_settings,
--         OFF by default (no row = off), and one ai_web_switch_audit row per
--         flip. Who may flip it (owner/admin, fresh session) is the SERVICE's
--         rule: the database cannot know the caller.
--   C374  erasure ships with the tables. ai_web_erase_user(uuid) tombstones the
--         user in the switch and its audit (the workspace keeps its setting);
--         ai_erase_user() calls it through a guarded to_regprocedure
--         (osionos-user-events-migration.sql), and the data-map rows are in
--         osionos-account-erasure-migration.sql. The taint goes with the
--         conversation rows the erase deletes.
--   C43   both tables are service_role-only: RLS on, one service_role policy,
--         REVOKE ALL from PUBLIC/anon/authenticated.
--
-- The name sorts AFTER osionos-ai-migration.sql, which creates
-- ai_conversations ("web" > "migration" under LC_ALL=C).
--
-- Lock-safe: two new tables, two columns on ai_conversations whose defaults are
-- constants (metadata-only), and a lock_timeout so an ALTER gives up rather
-- than queue behind a long transaction and stall every run.
--
-- Idempotent: IF NOT EXISTS / DROP ... IF EXISTS / CREATE OR REPLACE, replayed
-- on every boot. Never deletes or rewrites a row.

SET lock_timeout = '5s';

-- -----------------------------------------------------------------------------
-- 1. The taint of a conversation (C358, C359).
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_conversations ADD COLUMN IF NOT EXISTS web_tainted_at timestamptz;
ALTER TABLE public.ai_conversations ADD COLUMN IF NOT EXISTS web_domains text[] NOT NULL DEFAULT '{}';

DO $$
BEGIN
	IF NOT EXISTS (SELECT 1 FROM pg_constraint
	                WHERE conrelid = 'public.ai_conversations'::regclass
	                  AND conname = 'ai_conversations_web_domains_check') THEN
		ALTER TABLE public.ai_conversations ADD CONSTRAINT ai_conversations_web_domains_check
			CHECK (cardinality(web_domains) <= 5) NOT VALID;
	END IF;
END $$;

-- Top level on purpose: the runner applies each statement on its own, so the
-- scan of VALIDATE never runs inside the DO that holds the ALTER's lock. Every
-- existing row has the empty default, so it passes.
ALTER TABLE public.ai_conversations VALIDATE CONSTRAINT ai_conversations_web_domains_check;

-- -----------------------------------------------------------------------------
-- 2. The switch of a workspace and its audit (C370).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_workspace_web_settings (
	workspace_id uuid        PRIMARY KEY,
	web_enabled  boolean     NOT NULL DEFAULT false,
	updated_by   uuid,
	updated_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.ai_workspace_web_settings IS
	'Per-workspace switch "Allow web access" for the assistant web tools (C370). No row = off. Read by the service at run time; service_role only.';

CREATE TABLE IF NOT EXISTS public.ai_web_switch_audit (
	id           bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	workspace_id uuid        NOT NULL,
	actor_id     uuid        NOT NULL,
	web_enabled  boolean     NOT NULL,
	created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ai_web_switch_audit_workspace_idx
	ON public.ai_web_switch_audit (workspace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ai_web_switch_audit_actor_idx
	ON public.ai_web_switch_audit (actor_id);

COMMENT ON TABLE public.ai_web_switch_audit IS
	'One row per flip of the workspace web switch (C370): who, when, to what. service_role only.';

-- -----------------------------------------------------------------------------
-- 3. The erasure (C374).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_web_erase_user(p_user uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
	-- osionos_account_tombstone(): copied, not called, so this file does not
	-- depend on the order of osionos-account-erasure-migration.sql.
	tomb CONSTANT uuid := '00000000-0000-4000-8000-000000000000';
	n integer;
BEGIN
	-- The switch is the workspace's: it stays, its author becomes the tombstone.
	UPDATE public.ai_workspace_web_settings SET updated_by = tomb WHERE updated_by = p_user;
	UPDATE public.ai_web_switch_audit SET actor_id = tomb WHERE actor_id = p_user;
	GET DIAGNOSTICS n = ROW_COUNT;
	RETURN n;
END $$;

COMMENT ON FUNCTION public.ai_web_erase_user(uuid) IS
	'Tombstones the user in the workspace web switch and its audit; returns the number of audit rows rewritten. Called by ai_erase_user() when this file is applied.';

-- -----------------------------------------------------------------------------
-- 4. service_role only (C43).
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_workspace_web_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_web_switch_audit       ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_workspace_web_settings_service_role_all ON public.ai_workspace_web_settings;
CREATE POLICY ai_workspace_web_settings_service_role_all ON public.ai_workspace_web_settings
	FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

DROP POLICY IF EXISTS ai_web_switch_audit_service_role_all ON public.ai_web_switch_audit;
CREATE POLICY ai_web_switch_audit_service_role_all ON public.ai_web_switch_audit
	FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

-- The audit gets SELECT and INSERT only: the service never rewrites a flip.
-- The erase rewrites it as the owner of the SECURITY DEFINER functions.
GRANT SELECT, INSERT, UPDATE ON public.ai_workspace_web_settings TO service_role;
GRANT SELECT, INSERT ON public.ai_web_switch_audit TO service_role;

REVOKE ALL ON public.ai_workspace_web_settings FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.ai_web_switch_audit       FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_web_erase_user(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ai_web_erase_user(uuid) TO service_role;

RESET lock_timeout;

NOTIFY pgrst, 'reload schema';
