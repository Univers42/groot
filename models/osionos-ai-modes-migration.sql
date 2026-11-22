-- osionos AI assistant modes (AM7 mode storage, AM10/AM11 provenance taint,
-- AM3 decided_by and turn id). Applies AFTER osionos-ai-context-hooks-migration.sql.
--
--   ai_conversations  assist_mode (manual | plan | accept_edits | auto; NO
--                     'bypass', by design: the devil ruling AM1-AM20), the page
--                     the mode is anchored to, when it was set, and the
--                     provenance taint (when and why the conversation read
--                     content it does not trust).
--   ai_approvals      decided_by: who decided the write, the user or an auto mode.
--   ai_runs           turn_id: the user turn a run belongs to (null = its own id,
--                     set by the service).
--
-- Caveat: every conversation that exists when this runs is stamped tainted with
-- reason 'legacy' (the constant default below, then dropped), so an old
-- conversation can never auto-write. That over-taints by design: its earlier
-- reads were never tracked. The escape is a new conversation.
--
-- Idempotent and lock-safe: ADD COLUMN IF NOT EXISTS, constraints added once
-- (NOT VALID, then VALIDATE), bounded by the lock_timeout. Never rewrites an
-- existing approval or run. The tables are service_role only already
-- (osionos-ai-migration.sql); new columns inherit that.

SET lock_timeout = '5s';

DO $$
BEGIN
	IF to_regclass('public.ai_conversations') IS NULL
	   OR to_regclass('public.ai_approvals') IS NULL
	   OR to_regclass('public.ai_runs') IS NULL THEN
		RAISE EXCEPTION 'the AI tables are missing: apply osionos-ai-migration.sql and the later AI migrations before osionos-ai-modes-migration.sql';
	END IF;
END
$$;

-- The legacy default stamps the rows that exist; the second ALTER makes new
-- conversations start clean. On a replay the columns exist, only defaults reset.
ALTER TABLE public.ai_conversations
	ADD COLUMN IF NOT EXISTS assist_mode           text NOT NULL DEFAULT 'manual',
	ADD COLUMN IF NOT EXISTS assist_anchor_page_id uuid,
	ADD COLUMN IF NOT EXISTS assist_mode_set_at    timestamptz,
	ADD COLUMN IF NOT EXISTS provenance_tainted_at timestamptz DEFAULT '2026-11-22T00:00:00Z',
	ADD COLUMN IF NOT EXISTS provenance_reason     text DEFAULT 'legacy';
ALTER TABLE public.ai_conversations
	ALTER COLUMN provenance_tainted_at SET DEFAULT NULL,
	ALTER COLUMN provenance_reason SET DEFAULT NULL;

ALTER TABLE public.ai_approvals ADD COLUMN IF NOT EXISTS decided_by text;
ALTER TABLE public.ai_runs ADD COLUMN IF NOT EXISTS turn_id uuid;

DO $$
BEGIN
	IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.ai_conversations'::regclass AND conname = 'ai_conversations_assist_mode_check') THEN
		ALTER TABLE public.ai_conversations ADD CONSTRAINT ai_conversations_assist_mode_check
			CHECK (assist_mode IN ('manual', 'plan', 'accept_edits', 'auto')) NOT VALID;
	END IF;
	IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.ai_conversations'::regclass AND conname = 'ai_conversations_provenance_reason_check') THEN
		ALTER TABLE public.ai_conversations ADD CONSTRAINT ai_conversations_provenance_reason_check
			CHECK (provenance_reason IS NULL OR provenance_reason IN (
				'shared_page', 'shared_title', 'attachment', 'image', 'thread',
				'foreign_skill', 'foreign_agent', 'untrusted_tool', 'unknown_view', 'legacy')) NOT VALID;
	END IF;
	IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.ai_approvals'::regclass AND conname = 'ai_approvals_decided_by_check') THEN
		ALTER TABLE public.ai_approvals ADD CONSTRAINT ai_approvals_decided_by_check
			CHECK (decided_by IS NULL OR decided_by IN ('user', 'auto:accept_edits', 'auto:auto')) NOT VALID;
	END IF;
END
$$;

ALTER TABLE public.ai_conversations VALIDATE CONSTRAINT ai_conversations_assist_mode_check;
ALTER TABLE public.ai_conversations VALIDATE CONSTRAINT ai_conversations_provenance_reason_check;
ALTER TABLE public.ai_approvals VALIDATE CONSTRAINT ai_approvals_decided_by_check;

-- The auto-decided writes of a run: the count the auto modes cap per turn.
CREATE INDEX IF NOT EXISTS ai_approvals_auto_turn
	ON public.ai_approvals (run_id) WHERE decided_by LIKE 'auto:%';
