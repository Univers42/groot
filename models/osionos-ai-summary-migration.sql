-- The rolling summary of a long assistant conversation (osionos
-- OSIONOS_AI_SUMMARY, off by default).
--
-- The service keeps the newest turns of a thread in the prompt and used to drop
-- the rest without a word. When it drops turns, it now writes a summary of them
-- here and quotes it into later runs as data (never the system prompt).
--
--   C376  three columns on ai_conversations: the summary text (at most 4 000
--         chars by CHECK), the created_at of the newest message it covers, and
--         a version the writer compares, so a lost race writes nothing (C382).
--   C383  the service clears the three columns when edit-and-resend deletes a
--         turn the summary covers; the database keeps no history of them.
--   C390  the columns die with the conversation row (the account erase deletes
--         ai_conversations by owner); the export lists them with the
--         conversation (osionos-account-erasure-migration.sql).
--   C43   no grant changes: ai_conversations is already service_role-only.
--
-- The name sorts AFTER osionos-ai-migration.sql, which creates
-- ai_conversations ("summary" > "migration" under LC_ALL=C).
--
-- Lock-safe: two nullable columns and one with a constant default
-- (metadata-only), a CHECK added NOT VALID then validated on its own, and a
-- lock_timeout so an ALTER gives up rather than stall every run.
--
-- Idempotent: IF NOT EXISTS / guarded DO, replayed on every boot. Never
-- deletes or rewrites a row.

SET lock_timeout = '5s';

ALTER TABLE public.ai_conversations ADD COLUMN IF NOT EXISTS summary text;
ALTER TABLE public.ai_conversations ADD COLUMN IF NOT EXISTS summary_through timestamptz;
ALTER TABLE public.ai_conversations ADD COLUMN IF NOT EXISTS summary_version integer NOT NULL DEFAULT 0;

DO $$
BEGIN
	IF NOT EXISTS (SELECT 1 FROM pg_constraint
	                WHERE conrelid = 'public.ai_conversations'::regclass
	                  AND conname = 'ai_conversations_summary_check') THEN
		ALTER TABLE public.ai_conversations ADD CONSTRAINT ai_conversations_summary_check
			CHECK (summary IS NULL OR char_length(summary) <= 4000) NOT VALID;
	END IF;
END $$;

-- Top level on purpose: the runner applies each statement on its own, so the
-- scan of VALIDATE never runs inside the DO that holds the ALTER's lock. Every
-- existing row has a NULL summary, so it passes.
ALTER TABLE public.ai_conversations VALIDATE CONSTRAINT ai_conversations_summary_check;

COMMENT ON COLUMN public.ai_conversations.summary IS
	'Rolling summary of the turns the history window dropped (C376). Model output about the thread: quoted as data in the user turn, never instructions.';
COMMENT ON COLUMN public.ai_conversations.summary_through IS
	'created_at of the newest message the summary covers; NULL with no summary.';
COMMENT ON COLUMN public.ai_conversations.summary_version IS
	'Bumped on every write or clear; the writer updates only the version it read (C382).';

RESET lock_timeout;

NOTIFY pgrst, 'reload schema';
