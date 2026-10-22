-- ai_skills — workspace skills of the osionos assistant (P5b-2): a named
-- procedure, written in markdown by a workspace owner/admin, that every run in
-- that workspace sees as one index line and loads with `load_skill`.
--
-- A skill is PROMPT-SHAPING CONTENT written by a user, so the file carries the
-- devil's conditions (records: p5-verdict-reconstructed.md):
--   C40  every write is audited, versioned and pinned: ai_skill_audit holds one
--        row per write (actor, action, at, before, after, the new version), and
--        the version a run loaded is pinned on ai_runs.skill_pins. Tool results
--        are not stored in ai_messages (they live in the run's Redis stream,
--        which expires), so the pin needs a durable home: the run row.
--   C41  who may write (workspace owner/admin, checked live) is the SERVICE's
--        rule: it reads osionos_workspace_members. The database cannot know the
--        caller, so no policy here pretends to.
--   C43  both tables are service_role-only: RLS on, one service_role policy, and
--        REVOKE ALL from PUBLIC/anon/authenticated. The ai_* tables are outside
--        the osionos_% catalog pass of osionos-service-role-only-migration.sql,
--        so each closes itself.
--   C47  the caps are CHECKs (slug 32, name 80, description 160, body 6000), the
--        same numbers as the service's zod schema and the built-in skills. The
--        limit of 8 ACTIVE skills per workspace is the service's, in the write
--        transaction; a trigger-less unique index cannot count.
--
-- A slug must not collide with a built-in skill id. The built-ins live in the
-- service's code, which the database does not know: the service refuses it.
--
-- ai_skill_audit is APPEND-ONLY, like ai_moderation_events: a BEFORE UPDATE OR
-- DELETE row trigger and a BEFORE TRUNCATE statement trigger raise. Unlike the
-- moderation audit it has NO erasure switch: a skill's history is the evidence
-- of what the model was told. `after` holds the whole row (body included), which
-- is also how a run that listed version N loads version N after an edit.
--
-- Caveat: the trigger is bypassed by a superuser who disables it
-- (ALTER TABLE ... DISABLE TRIGGER) or sets session_replication_role = replica;
-- service_role cannot do either, and it holds only SELECT and INSERT here.
--
-- Lock-safe: two new tables, one nullable column on ai_runs (metadata-only); a
-- lock_timeout makes the ALTER give up rather than queue behind a long
-- transaction and stall every run.
--
-- Idempotent: IF NOT EXISTS / DROP ... IF EXISTS / CREATE OR REPLACE, replayed
-- on every boot. Never deletes or rewrites a row.

SET lock_timeout = '5s';

-- -----------------------------------------------------------------------------
-- 1. The skills.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_skills (
	id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
	workspace_id uuid        NOT NULL,
	slug         text        NOT NULL CHECK (slug ~ '^[a-z][a-z0-9-]{1,31}$'),
	name         text        NOT NULL CHECK (length(name) BETWEEN 1 AND 80),
	description  text        NOT NULL CHECK (length(description) BETWEEN 1 AND 160),
	body         text        NOT NULL CHECK (length(body) BETWEEN 1 AND 6000),
	version      integer     NOT NULL DEFAULT 1 CHECK (version >= 1),
	created_by   uuid        NOT NULL,
	updated_by   uuid        NOT NULL,
	created_at   timestamptz NOT NULL DEFAULT now(),
	updated_at   timestamptz NOT NULL DEFAULT now(),
	archived_at  timestamptz
);

-- One ACTIVE skill per slug and workspace: an archived slug can be used again.
CREATE UNIQUE INDEX IF NOT EXISTS ai_skills_workspace_slug_active_idx
	ON public.ai_skills (workspace_id, slug) WHERE archived_at IS NULL;

COMMENT ON TABLE public.ai_skills IS
	'Workspace skills (P5b-2): markdown procedures written by a workspace owner/admin. Prompt-shaping content: every write has a row in ai_skill_audit, version bumps on every write. service_role only.';

-- -----------------------------------------------------------------------------
-- 2. The audit (C40): append-only.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_skill_audit (
	id           bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	skill_id     uuid        NOT NULL,
	workspace_id uuid        NOT NULL,
	version      integer     NOT NULL,
	action       text        NOT NULL CHECK (action IN ('create', 'update', 'archive', 'restore')),
	actor_id     uuid        NOT NULL,
	at           timestamptz NOT NULL DEFAULT now(),
	before       jsonb,
	after        jsonb
);

CREATE INDEX IF NOT EXISTS ai_skill_audit_skill_version_idx
	ON public.ai_skill_audit (skill_id, version);

CREATE OR REPLACE FUNCTION public.ai_skill_audit_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
	RAISE EXCEPTION 'ai_skill_audit is append-only: % is refused', TG_OP;
END $$;

DROP TRIGGER IF EXISTS ai_skill_audit_append_only ON public.ai_skill_audit;
CREATE TRIGGER ai_skill_audit_append_only
	BEFORE UPDATE OR DELETE ON public.ai_skill_audit
	FOR EACH ROW EXECUTE FUNCTION public.ai_skill_audit_guard();

DROP TRIGGER IF EXISTS ai_skill_audit_no_truncate ON public.ai_skill_audit;
CREATE TRIGGER ai_skill_audit_no_truncate
	BEFORE TRUNCATE ON public.ai_skill_audit
	FOR EACH STATEMENT EXECUTE FUNCTION public.ai_skill_audit_guard();

COMMENT ON TABLE public.ai_skill_audit IS
	'Append-only audit of ai_skills (C40): one row per write, with the whole row before and after. UPDATE, DELETE and TRUNCATE are refused by a trigger.';

-- -----------------------------------------------------------------------------
-- 3. The pin on the run (C40): [{id, version, source: builtin|workspace}], one
--    entry per skill the run loaded. NULL = the run loaded none.
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_runs ADD COLUMN IF NOT EXISTS skill_pins jsonb;

-- -----------------------------------------------------------------------------
-- 4. service_role only (C43).
-- -----------------------------------------------------------------------------
ALTER TABLE public.ai_skills      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_skill_audit ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_skills_service_role_all ON public.ai_skills;
CREATE POLICY ai_skills_service_role_all ON public.ai_skills
	FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

DROP POLICY IF EXISTS ai_skill_audit_service_role_all ON public.ai_skill_audit;
CREATE POLICY ai_skill_audit_service_role_all ON public.ai_skill_audit
	FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

-- The audit gets SELECT and INSERT only; the trigger is what makes it append-only.
GRANT SELECT, INSERT, UPDATE ON public.ai_skills TO service_role;
GRANT SELECT, INSERT ON public.ai_skill_audit TO service_role;

REVOKE ALL ON public.ai_skills      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.ai_skill_audit FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ai_skill_audit_guard() FROM PUBLIC, anon, authenticated;

RESET lock_timeout;

NOTIFY pgrst, 'reload schema';
