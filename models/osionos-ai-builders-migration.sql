-- ai_plan_items — the state of each item of a builder plan (P6a, devil C155),
-- and the `partial` status of ai_approvals.
--
-- A plan is ONE ai_approvals row (tool build_plan). Its items live here, one row
-- per page or database, so an execution that ran out of its time budget can be
-- resumed on the pending items only (C157) and undone on the `done` ones (C159).
-- `created_id` is the page uuid or the dbKey the bridge confirmed.
--
-- Closed to the public roles (C43): RLS on, one service_role policy, REVOKE from
-- PUBLIC/anon/authenticated. The rows cascade with their approval.
--
-- Lock-safe: one new table; the constraint swap below is NOT VALID then
-- VALIDATE, and the whole file runs under a lock_timeout so a long transaction
-- makes it give up rather than queue and stall every approval.
--
-- Idempotent: IF NOT EXISTS / DROP ... IF EXISTS, replayed on every boot. Never
-- deletes or rewrites a row.

SET lock_timeout = '5s';

-- -----------------------------------------------------------------------------
-- 1. The items.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_plan_items (
	approval_id uuid        NOT NULL REFERENCES public.ai_approvals (id) ON DELETE CASCADE,
	item_key    text        NOT NULL CHECK (char_length(item_key) BETWEEN 1 AND 40),
	kind        text        NOT NULL CHECK (kind IN ('page', 'database')),
	parent_key  text,
	position    integer     NOT NULL,
	status      text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'done', 'failed', 'skipped')),
	created_id  text,
	error       text,
	updated_at  timestamptz NOT NULL DEFAULT now(),
	PRIMARY KEY (approval_id, item_key)
);

COMMENT ON TABLE public.ai_plan_items IS
	'State of each item of a build_plan approval (P6 C155). position is the parents-first order; created_id is what the bridge confirmed. service_role only.';

-- -----------------------------------------------------------------------------
-- 2. The `partial` status, additively. The CHECK was created unnamed in
--    osionos-ai-migration.sql, so postgres named it ai_approvals_status_check.
--    NOT VALID + VALIDATE: ADD ... NOT VALID takes its strong lock without
--    scanning the table, and VALIDATE scans under a weaker lock that lets
--    reads and writes through. One transaction: no moment without the CHECK.
--
--    The live-call unique index gains 'partial': a half-built plan is live and
--    must not be asked a second time. Dropped and recreated in the same
--    transaction, so no duplicate slips in between.
-- -----------------------------------------------------------------------------
BEGIN;

ALTER TABLE public.ai_approvals DROP CONSTRAINT IF EXISTS ai_approvals_status_check;
ALTER TABLE public.ai_approvals ADD CONSTRAINT ai_approvals_status_check
	CHECK (status IN ('pending', 'executing', 'executed', 'failed', 'declined', 'expired', 'unknown', 'partial')) NOT VALID;
ALTER TABLE public.ai_approvals VALIDATE CONSTRAINT ai_approvals_status_check;

DROP INDEX IF EXISTS public.ai_approvals_one_live_per_call;
CREATE UNIQUE INDEX IF NOT EXISTS ai_approvals_one_live_per_call
	ON public.ai_approvals (run_id, tool, args_sha256)
	WHERE status IN ('pending', 'executing', 'executed', 'partial');

COMMIT;

-- -----------------------------------------------------------------------------
-- 3. service_role only (C43).
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_plan_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_plan_items_service_role_all ON public.ai_plan_items;
CREATE POLICY ai_plan_items_service_role_all ON public.ai_plan_items
	FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_plan_items TO service_role;
REVOKE ALL ON public.ai_plan_items FROM PUBLIC, anon, authenticated;

RESET lock_timeout;

NOTIFY pgrst, 'reload schema';
