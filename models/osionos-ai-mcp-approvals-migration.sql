-- ai_approvals with an MCP origin — an outside agent's write is an approval the
-- user decides in osionos, and it never runs on the token (G4b-2, devil C117,
-- with C114 and C115; records: g-graph-diagrams-mcp-verdict.md).
--
-- What this file adds, and what it does not:
--   - `origin` says where the question comes from: a run of the assistant
--     ('run') or the remote MCP endpoint ('mcp');
--   - an MCP approval names the personal access token that asked (`token_id`),
--     and carries NO run: `run_id` and `conversation_id` are NULL for it. A run
--     approval still names its run and its conversation, and carries no token;
--     the shape CHECK below makes the two halves exclusive, so a row can never
--     be a mix of both;
--   - the token is a SCOPE and an ORIGIN, never a credential in the row: the
--     write happens at decision time, with the app-session token of the request
--     that decided (C114). This table still stores no bearer token;
--   - `token_id` cascades on delete: erasing a token erases the writes it left
--     waiting, and nothing of it survives the erase.
--
-- The dedupe: an MCP call is one question per (token, tool, arguments). The
-- existing ai_approvals_one_live_per_call keys on run_id, and a NULL run_id
-- never collides, so the MCP calls get their own partial unique index over the
-- same live statuses. A declined or expired approval frees the call again.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS, CREATE INDEX IF NOT EXISTS, and every
-- constraint is guarded by pg_constraint; replayed on every boot. A column that
-- is already nullable is left alone by DROP NOT NULL.
--
-- Ordering: this file sorts before osionos-ai-migration.sql in the alphabetical
-- pass of scripts/apply-models-migrations.sh. That runner defers a file that
-- references a table a later file creates and retries it in the next round, so
-- a fresh database ends converged; the gate applies it after the base and the
-- access-tokens migrations explicitly.

SET lock_timeout = '5s';

-- -----------------------------------------------------------------------------
-- 1. The origin, and its two values.
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_approvals
	ADD COLUMN IF NOT EXISTS origin text NOT NULL DEFAULT 'run';

DO $$
BEGIN
	IF NOT EXISTS (
		SELECT 1 FROM pg_constraint
		WHERE conrelid = 'public.ai_approvals'::regclass
		  AND conname = 'ai_approvals_origin_check'
	) THEN
		ALTER TABLE public.ai_approvals
			ADD CONSTRAINT ai_approvals_origin_check CHECK (origin IN ('run', 'mcp'));
	END IF;
END
$$;

COMMENT ON COLUMN public.ai_approvals.origin IS
	'Where the question comes from: a run of the assistant (''run'') or the remote MCP endpoint (''mcp''). An mcp row carries token_id and no run.';

-- -----------------------------------------------------------------------------
-- 2. The token of an MCP approval. It is a scope, not a credential: no bearer
--    token is stored, and the erase of the token takes its waiting writes.
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_approvals
	ADD COLUMN IF NOT EXISTS token_id uuid;

DO $$
BEGIN
	IF NOT EXISTS (
		SELECT 1 FROM pg_constraint
		WHERE conrelid = 'public.ai_approvals'::regclass
		  AND conname = 'ai_approvals_token_id_fkey'
	) THEN
		ALTER TABLE public.ai_approvals
			ADD CONSTRAINT ai_approvals_token_id_fkey
			FOREIGN KEY (token_id) REFERENCES public.ai_access_tokens (id) ON DELETE CASCADE;
	END IF;
END
$$;

COMMENT ON COLUMN public.ai_approvals.token_id IS
	'The personal access token that asked (origin mcp). No run, no conversation; the write decision re-checks the token. Cascades with the token.';

-- -----------------------------------------------------------------------------
-- 3. A run approval must still name its run, but an MCP one has none: both
--    columns become nullable, and the shape CHECK is what keeps them honest.
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_approvals ALTER COLUMN run_id DROP NOT NULL;
ALTER TABLE public.ai_approvals ALTER COLUMN conversation_id DROP NOT NULL;

DO $$
BEGIN
	IF NOT EXISTS (
		SELECT 1 FROM pg_constraint
		WHERE conrelid = 'public.ai_approvals'::regclass
		  AND conname = 'ai_approvals_origin_shape'
	) THEN
		ALTER TABLE public.ai_approvals ADD CONSTRAINT ai_approvals_origin_shape CHECK (
			(origin = 'run' AND run_id IS NOT NULL AND conversation_id IS NOT NULL AND token_id IS NULL)
			OR (origin = 'mcp' AND token_id IS NOT NULL AND run_id IS NULL AND conversation_id IS NULL)
		);
	END IF;
END
$$;

-- -----------------------------------------------------------------------------
-- 4. The duplicate key of an MCP call: one live question per token, tool and
--    canonical-arguments hash. The live statuses are the ones of
--    ai_approvals_one_live_per_call (the plan-items migration added 'partial'
--    there); a NULL run_id never collides with the run index.
-- -----------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS ai_approvals_one_live_per_token_call
	ON public.ai_approvals (token_id, tool, args_sha256)
	WHERE origin = 'mcp' AND status IN ('pending', 'executing', 'executed', 'partial');

-- The pending count of one token: the cap checked before an MCP write asks.
CREATE INDEX IF NOT EXISTS ai_approvals_token_status_idx
	ON public.ai_approvals (token_id, status);

RESET lock_timeout;

NOTIFY pgrst, 'reload schema';
