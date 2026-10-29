-- osionos AI context items (U3): a user's own hooks, the fourth kind of
-- ai_context_items (osionos-ai-records/verdict-u3-user-hooks-2026-10-29.md,
-- C1120-C1133). Applies AFTER osionos-ai-context-commands-migration.sql.
--
--   A hook is a USER row only (ai_context_items_workspace_kind keeps a workspace
--   row a rule). Its body is the list of tool names the AI may not use for that
--   user: one per line, an exact name or a prefix ending in '*'. The service
--   only ever removes tools with it; nothing in it is run or put in a prompt.
--
--   C1124  ai_context_items_hook_body: 1 to 32 lines of [a-zA-Z][a-zA-Z0-9_-]{0,63}
--          with an optional trailing '*'; no empty line, no trailing newline.
--          The service's HOOK_LINE (src/context/hooks.ts) checks the same.
--   C1130  the kind CHECK is found by its shape, as in U2; a definition that
--          already names 'hook' is left alone and the body CHECK is added once,
--          so the file replays on every boot. Before U2 it stops with a message.
--
-- Lock-safe: ACCESS EXCLUSIVE for two ALTERs on a small table, bounded by the
-- lock_timeout. Never deletes or rewrites a row.

SET lock_timeout = '5s';

DO $$
DECLARE
	kind_check text;
	kind_def   text;
BEGIN
	IF to_regclass('public.ai_context_items') IS NULL THEN
		RAISE EXCEPTION 'public.ai_context_items is missing: apply osionos-ai-context-migration.sql and osionos-ai-context-commands-migration.sql before osionos-ai-context-hooks-migration.sql';
	END IF;
	SELECT c.conname, pg_get_constraintdef(c.oid) INTO kind_check, kind_def
	FROM pg_constraint c
	JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attname = 'kind'
	WHERE c.conrelid = 'public.ai_context_items'::regclass AND c.contype = 'c' AND c.conkey = ARRAY[a.attnum];
	IF kind_check IS NULL THEN
		RAISE EXCEPTION 'public.ai_context_items has no CHECK on kind alone: refusing to guess which constraint to widen';
	END IF;
	IF kind_def NOT LIKE '%''command''%' THEN
		RAISE EXCEPTION 'ai_context_items does not allow commands yet: apply osionos-ai-context-commands-migration.sql before osionos-ai-context-hooks-migration.sql';
	END IF;
	IF kind_def NOT LIKE '%''hook''%' THEN
		EXECUTE format(
			'ALTER TABLE public.ai_context_items DROP CONSTRAINT %I, ADD CONSTRAINT ai_context_items_kind_check CHECK (kind IN (''skill'', ''rule'', ''command'', ''hook''))',
			kind_check);
	END IF;
	IF NOT EXISTS (
		SELECT 1 FROM pg_constraint
		WHERE conrelid = 'public.ai_context_items'::regclass AND conname = 'ai_context_items_hook_body'
	) THEN
		ALTER TABLE public.ai_context_items ADD CONSTRAINT ai_context_items_hook_body CHECK (
			kind <> 'hook'
			OR body ~ '^[a-zA-Z][a-zA-Z0-9_-]{0,63}\*?(\n[a-zA-Z][a-zA-Z0-9_-]{0,63}\*?){0,31}$'
		);
	END IF;
END
$$;

COMMENT ON COLUMN public.ai_context_items.kind IS
	'skill (loaded by load_skill), rule (in every run''s user turn), command (a user''s slash template, expanded by the composer, never read into a prompt by the service) or hook (tool names the AI may not use for that user; it only removes tools, never in a prompt).';
