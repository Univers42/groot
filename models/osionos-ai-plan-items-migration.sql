-- ai_plan_items — the state of each item of a builder plan (P6a, devil C155),
-- and the `partial` status of ai_approvals.
--
-- A plan is ONE ai_approvals row (tool build_plan). Its items live here, one row
-- per page or database, so an execution that ran out of its time budget can be
-- resumed on the pending items only (C157) and undone on the `done` ones (C159),
-- which then read `undone`.
-- `created_id` is the page uuid or the dbKey the bridge confirmed.
--
-- Closed to the public roles (C43): RLS on, one service_role policy, REVOKE from
-- PUBLIC/anon/authenticated. The rows cascade with their approval.
--
-- Lock-safe: one new table; the status swap below runs once, and the whole
-- file runs under a lock_timeout so a long transaction makes it give up rather
-- than queue and stall every approval.
--
-- Idempotent: IF NOT EXISTS, and the status swap runs only while 'partial' is
-- missing; replayed on every boot. Never deletes or rewrites a row.
--
-- NAMED to sort after osionos-ai-migration.sql, which creates ai_approvals: the
-- models runner applies osionos-ai-*.sql in its alphabetical pass
-- (scripts/apply-models-migrations.sh). "builders" would sort first and fail on
-- a fresh database. scripts/verify/ai-builders.sh check f holds the order.

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
	status      text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'done', 'failed', 'skipped', 'undone')),
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
--
--    The live-call unique index gains 'partial': a half-built plan is live and
--    must not be asked a second time.
--
--    Each swap runs only while the live definition lacks 'partial', so the
--    file replays on every boot without rebuilding the index or rescanning
--    the table. The DO block is one transaction: there is no moment without
--    the CHECK or the index. The first apply holds ACCESS EXCLUSIVE on
--    ai_approvals for one scan of the table, under the lock_timeout above.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
	IF NOT EXISTS (
		SELECT 1 FROM pg_constraint
		WHERE conrelid = 'public.ai_approvals'::regclass
		  AND conname = 'ai_approvals_status_check'
		  AND pg_get_constraintdef(oid) LIKE '%''partial''%'
	) THEN
		ALTER TABLE public.ai_approvals DROP CONSTRAINT IF EXISTS ai_approvals_status_check;
		ALTER TABLE public.ai_approvals ADD CONSTRAINT ai_approvals_status_check
			CHECK (status IN ('pending', 'executing', 'executed', 'failed', 'declined', 'expired', 'unknown', 'partial'));
	END IF;

	IF NOT EXISTS (
		SELECT 1 FROM pg_indexes
		WHERE schemaname = 'public'
		  AND indexname = 'ai_approvals_one_live_per_call'
		  AND indexdef LIKE '%''partial''%'
	) THEN
		-- The replacement index must include 'partial'. Avoid silently building
		-- it with a blocking CREATE INDEX on a populated table. The runner applies
		-- each file in its own transaction, so the online index change belongs in
		-- a separate, non-transactional migration step. On a fresh empty install
		-- the regular build is safe.
		IF EXISTS (SELECT 1 FROM public.ai_approvals LIMIT 1) THEN
			RAISE EXCEPTION
				'ai_approvals_one_live_per_call needs an online concurrent index migration before upgrading a populated ai_approvals table';
		END IF;
		DROP INDEX IF EXISTS public.ai_approvals_one_live_per_call;
		CREATE UNIQUE INDEX ai_approvals_one_live_per_call
			ON public.ai_approvals (run_id, tool, args_sha256)
			WHERE status IN ('pending', 'executing', 'executed', 'partial');
	END IF;
END
$$;

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
