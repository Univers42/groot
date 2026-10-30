-- osionos AI context items (U2): a user's own slash commands, the third kind of
-- ai_context_items (osionos-ai-records/verdict-u2-user-commands-2026-10-29.md,
-- C1100-C1110). Applies AFTER osionos-ai-context-migration.sql.
--
--   A command is a USER row only: ai_context_items_workspace_kind already keeps
--   a workspace row a rule, so an admin's template can never run as a member's
--   own message. The body is the template (6000 characters, the table's cap).
--
--   C1106  the CHECK on kind is found by its shape (a CHECK on the kind column
--          alone), not by the name Postgres gave it; a definition that already
--          names 'command' is left alone, so the file replays on every boot.
--          Without the U1 table it stops with a message, never a silent skip.
--
-- Lock-safe: ACCESS EXCLUSIVE for one ALTER on a small table, bounded by the
-- lock_timeout. Never deletes or rewrites a row.

SET lock_timeout = '5s';

DO $$
DECLARE
	kind_check text;
	kind_def   text;
BEGIN
	IF to_regclass('public.ai_context_items') IS NULL THEN
		RAISE EXCEPTION 'public.ai_context_items is missing: apply osionos-ai-context-migration.sql before osionos-ai-context-commands-migration.sql';
	END IF;
	SELECT c.conname, pg_get_constraintdef(c.oid) INTO kind_check, kind_def
	FROM pg_constraint c
	JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attname = 'kind'
	WHERE c.conrelid = 'public.ai_context_items'::regclass AND c.contype = 'c' AND c.conkey = ARRAY[a.attnum];
	IF kind_check IS NULL THEN
		RAISE EXCEPTION 'public.ai_context_items has no CHECK on kind alone: refusing to guess which constraint to widen';
	END IF;
	IF kind_def LIKE '%''command''%' THEN
		RETURN;
	END IF;
	EXECUTE format(
		'ALTER TABLE public.ai_context_items DROP CONSTRAINT %I, ADD CONSTRAINT ai_context_items_kind_check CHECK (kind IN (''skill'', ''rule'', ''command''))',
		kind_check);
END
$$;

COMMENT ON COLUMN public.ai_context_items.kind IS
	'skill (loaded by load_skill), rule (in every run''s user turn) or command (a user''s slash template, expanded by the composer, never read into a prompt by the service).';
