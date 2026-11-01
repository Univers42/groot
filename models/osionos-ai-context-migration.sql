-- osionos AI context items (U1): the skills a user writes for themself, and the
-- rules a user or a workspace admin writes for every run, stored where the AI
-- service reads them (osionos-ai-records/plan-ai-context-library-2026-10-29.md,
-- verdict B′, C1000-C1015).
--
--   C1002  only two new tables: ai_skills and its audit are not touched, so no
--          run waits on a lock of this file.
--   C1004  a row is EITHER a user's (owner_id, no workspace) OR a workspace's
--          (workspace_id, no owner); a rule body is at most 1200 characters;
--          workspace skills stay in ai_skills (a workspace row is a rule).
--   C1008  the audit of a user row keeps no text (lengths and a body digest, as
--          the service writes them) and no owner_id: the row is the user's own
--          and goes on erasure; the audit is append-only and cannot.
--   C1007  ai_context_erase_user() deletes the user's rows and tombstones the
--          user as an author of workspace rules; ai_erase_user() calls it, and
--          the erasure registry carries the same columns for the account erase.
--
-- Who may write (owner for user rows, workspace owner/admin for workspace rows)
-- is the SERVICE's check, read live; no policy here pretends to. service_role
-- only, like ai_skills (C43).
--
-- Caveat: the append-only trigger is bypassed by a superuser who disables it or
-- by session_replication_role = replica; it guards against the service, not the
-- database owner.
--
-- Lock-safe and idempotent: new objects only, IF NOT EXISTS / CREATE OR REPLACE,
-- replayed on every boot. Never deletes or rewrites a row.

SET lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS public.ai_context_items (
	id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
	kind         text        NOT NULL CHECK (kind IN ('skill', 'rule')),
	scope        text        NOT NULL CHECK (scope IN ('user', 'workspace')),
	owner_id     uuid,
	workspace_id uuid,
	slug         text        NOT NULL CHECK (slug ~ '^[a-z][a-z0-9-]{1,31}$'),
	name         text        NOT NULL CHECK (length(name) BETWEEN 1 AND 80),
	description  text        NOT NULL CHECK (length(description) BETWEEN 1 AND 160),
	body         text        NOT NULL CHECK (length(body) BETWEEN 1 AND 6000),
	version      integer     NOT NULL DEFAULT 1 CHECK (version >= 1),
	created_by   uuid        NOT NULL,
	updated_by   uuid        NOT NULL,
	created_at   timestamptz NOT NULL DEFAULT now(),
	updated_at   timestamptz NOT NULL DEFAULT now(),
	archived_at  timestamptz,
	CONSTRAINT ai_context_items_scope_owner CHECK (
		(scope = 'user' AND owner_id IS NOT NULL AND workspace_id IS NULL)
		OR (scope = 'workspace' AND workspace_id IS NOT NULL AND owner_id IS NULL)),
	CONSTRAINT ai_context_items_workspace_kind CHECK (scope = 'user' OR kind = 'rule'),
	CONSTRAINT ai_context_items_rule_body CHECK (kind <> 'rule' OR length(body) <= 1200)
);

-- One ACTIVE item per slug and kind in its scope: an archived slug is free again.
CREATE UNIQUE INDEX IF NOT EXISTS ai_context_items_user_slug_active_idx
	ON public.ai_context_items (owner_id, kind, slug) WHERE scope = 'user' AND archived_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ai_context_items_workspace_slug_active_idx
	ON public.ai_context_items (workspace_id, kind, slug) WHERE scope = 'workspace' AND archived_at IS NULL;

COMMENT ON TABLE public.ai_context_items IS
	'AI context items (U1): a user''s own skills and rules, and a workspace''s rules. Prompt-shaping content: every write has a row in ai_context_item_audit and bumps version. service_role only.';

CREATE TABLE IF NOT EXISTS public.ai_context_item_audit (
	id           bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	item_id      uuid        NOT NULL,
	scope        text        NOT NULL CHECK (scope IN ('user', 'workspace')),
	workspace_id uuid,
	version      integer     NOT NULL,
	action       text        NOT NULL CHECK (action IN ('create', 'update', 'archive')),
	actor_id     uuid        NOT NULL,
	at           timestamptz NOT NULL DEFAULT now(),
	before       jsonb,
	after        jsonb,
	CONSTRAINT ai_context_item_audit_scope CHECK ((scope = 'user') = (workspace_id IS NULL))
);

CREATE INDEX IF NOT EXISTS ai_context_item_audit_item_version_idx
	ON public.ai_context_item_audit (item_id, version);

CREATE OR REPLACE FUNCTION public.ai_context_item_audit_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
	RAISE EXCEPTION 'ai_context_item_audit is append-only: % is refused', TG_OP;
END $$;

DROP TRIGGER IF EXISTS ai_context_item_audit_append_only ON public.ai_context_item_audit;
CREATE TRIGGER ai_context_item_audit_append_only
	BEFORE UPDATE OR DELETE ON public.ai_context_item_audit
	FOR EACH ROW EXECUTE FUNCTION public.ai_context_item_audit_guard();

DROP TRIGGER IF EXISTS ai_context_item_audit_no_truncate ON public.ai_context_item_audit;
CREATE TRIGGER ai_context_item_audit_no_truncate
	BEFORE TRUNCATE ON public.ai_context_item_audit
	FOR EACH STATEMENT EXECUTE FUNCTION public.ai_context_item_audit_guard();

COMMENT ON TABLE public.ai_context_item_audit IS
	'Append-only audit of ai_context_items: one row per write. A workspace row keeps the whole item before and after; a user row keeps only lengths and a body digest (C1008). UPDATE, DELETE and TRUNCATE are refused by a trigger.';

-- C1007. The user's own items go; as the author of a workspace rule the user
-- becomes the tombstone (osionos_account_tombstone(), copied, not called, so this
-- file does not depend on the erasure file). The audit is append-only and keeps
-- the actor uuid as pseudonymous accountability, like ai_skill_audit; a user
-- row's audit holds no text to erase.
CREATE OR REPLACE FUNCTION public.ai_context_erase_user(p_user uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
	tomb CONSTANT uuid := '00000000-0000-4000-8000-000000000000';
	n bigint;
BEGIN
	DELETE FROM public.ai_context_items WHERE scope = 'user' AND owner_id = p_user;
	GET DIAGNOSTICS n = ROW_COUNT;
	UPDATE public.ai_context_items SET created_by = tomb WHERE created_by = p_user;
	UPDATE public.ai_context_items SET updated_by = tomb WHERE updated_by = p_user;
	RETURN n;
END $$;

COMMENT ON FUNCTION public.ai_context_erase_user(uuid) IS
	'Deletes the user-scope AI context items of the user and tombstones the user as the author of workspace rules; returns the number of items deleted. Called by ai_erase_user() when this file is applied.';

ALTER TABLE public.ai_context_items      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_context_item_audit ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_context_items_service_role_all ON public.ai_context_items;
CREATE POLICY ai_context_items_service_role_all ON public.ai_context_items
	FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

DROP POLICY IF EXISTS ai_context_item_audit_service_role_all ON public.ai_context_item_audit;
CREATE POLICY ai_context_item_audit_service_role_all ON public.ai_context_item_audit
	FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

-- The audit gets SELECT and INSERT only; the trigger is what makes it append-only.
GRANT SELECT, INSERT, UPDATE ON public.ai_context_items TO service_role;
GRANT SELECT, INSERT ON public.ai_context_item_audit TO service_role;

REVOKE ALL ON public.ai_context_items      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.ai_context_item_audit FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_context_item_audit_guard() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_context_erase_user(uuid)   FROM PUBLIC, anon, authenticated;

RESET lock_timeout;

NOTIFY pgrst, 'reload schema';
