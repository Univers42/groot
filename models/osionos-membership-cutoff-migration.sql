-- public.osionos_workspace_members loses a member: the app session tokens carry the
-- workspace ids from sign-in for 3600 s (scripts/bridge-api.mjs:422-438), and many
-- routes trust that list, so a removed member keeps reading the workspace for up to an
-- hour. This trigger writes the removed user's cut-off into public.auth_session_cutoffs,
-- which every replica already polls every 10 s (scripts/bridge-session-cutoff.mjs): the
-- session of a removed member dies within one poll instead of one hour.
--
-- It is a BACKSTOP, not the fix. The exact fix for the graph and AI reads (C98) is the
-- G1 lane's; this trigger bounds the window for every other surface.
--
-- THE ONE WAY TO BREAK EVERY SIGN-IN. A trigger written `AFTER UPDATE OF role` (or any
-- column list) fires on EVERY sign-in, because sign-in upserts the owner row with
-- role = 'owner' (models/osionos-bridge-migration.sql:313-318). Its stamp then lands
-- after the new token's iat_ms, and every fresh token is refused: the sign-in loops for
-- every user of the public stack (verdict §5, C123). So the trigger below is:
--   - no column list (never `UPDATE OF ...`);
--   - guarded by a VALUE change, not by a role branch: a role or permissions change
--     writes nothing (a demotion is already live -- the permission checks read the
--     members row -- so a cut-off would only cost a sign-out);
--   - DEFERRED, so the stamp is taken at COMMIT and not at the start of the
--     transaction: `now()` is the transaction START, so a handoff that began inside the
--     deleting transaction would still carry the workspace, and the stamp would be older
--     than the token it has to refuse (C125).
--
-- ORDERING. The runner (scripts/apply-models-migrations.sh) applies ORDERED_FIRST, then
-- the files in plain alphabetical order, then ORDERED_LAST. This file is in the
-- alphabetical pass and sorts after both of its dependencies:
--   - osionos-bridge-migration.sql is in ORDERED_FIRST (applied before the alphabetical
--     pass): it creates osionos_workspaces and osionos_workspace_members;
--   - auth-session-cutoffs.sql starts with "auth-", so it is applied in the alphabetical
--     pass long before this file ("osionos-membership-...").
-- scripts/verify/membership-cutoff.sh asserts that order instead of trusting it:
-- its order check reads the runner's own source (scripts/apply-models-migrations.sh)
-- and finds the two files where the runner puts them.
--
-- OWNERSHIP. The function is SECURITY DEFINER and is created by whoever applies this
-- file: apply it with the owner of public.auth_session_cutoffs (the runner applies
-- every models/*.sql as the superuser postgres), so it keeps that owner's rights on
-- the cutoffs table and on auth.users.
--
-- Caveat: the residual race is the gap between the stamp and the moment the commit
-- becomes visible -- the stamp is taken at COMMIT, but the row is only readable by the
-- replicas after the commit lands, so a handoff that starts in that gap still carries
-- the workspace (microseconds, and only for a handoff that begins exactly then; the
-- C98 lane closes it exactly for graph and AI). The stamp is the DATABASE clock while
-- the token's iat_ms is the BRIDGE clock (rule T4 of auth-session-cutoffs.sql), so the
-- two clocks must agree: a database clock running ahead of the bridge's by d refuses
-- the tokens minted in the d that follows a removal (bounded, one sign-in refused), and
-- a bridge clock running ahead accepts a token minted during the removal window.
--
-- Caveat: a workspace delete signs its members out only if the workspace is still
-- there -- the skip below leaves them alone (C126). The catalog query of
-- scripts/verify/membership-cutoff.sh prints every table that carries a
-- workspace_id column, with the foreign key on that column and whether its ROWS
-- die with the workspace. On the schema of this repo (the models the five
-- token-trusting surfaces read, applied in the runner's order) it is:
--   osionos_channels            CASCADE (direct)
--   osionos_join_requests       CASCADE (direct)
--   osionos_object_databases    CASCADE (direct)
--   osionos_page_action_events  CASCADE (direct)
--   osionos_page_configurations  CASCADE (direct)
--   osionos_pages               CASCADE (direct)
--   osionos_share_rules         CASCADE (direct)
--   osionos_workspace_databases CASCADE (direct)
--   osionos_workspace_members   CASCADE (direct)
--   osionos_page_links          no foreign key of its own: its rows cascade from
--                               osionos_pages (source_page_id), and the pages
--                               cascade from the workspace
--   osionos_tasks               no foreign key of its own: its rows cascade from
--                               osionos_pages (page_id), and the pages cascade
--                               from the workspace
-- Nothing of the workspace is readable through them once the workspace is gone:
-- the pages are gone with it, and the AI service checks the LIVE members row
-- (services/osionos-ai/src/workspaceAccess.ts:28-45), which the workspace delete
-- cascades away. The catalog is an ASSERTION, not a print: a table whose rows
-- survive the delete fails the check unless it is in the exception list of the
-- script, with the reason it is safe. The AI's own tables (ai_conversations,
-- ai_chunks, ai_index_queue) carry a workspace_id without a foreign key and are
-- NOT applied by that fixture: the AI is the G1 lane's (C98/C127) and is not one
-- of the five surfaces C126 names.
--
-- T9: DOWN is manual (the block at the end of this file) and the rows this trigger
-- wrote STAY: they end the sessions of the users it named, once. Removing the trigger
-- does not un-revoke them; the users sign in again.

BEGIN;

-- The stamp. It runs at COMMIT (the trigger below is deferred), reads the OLD row only
-- -- a member that lost its membership -- and never touches the NEW row: the user who
-- GAINED a membership needs no cut-off.
CREATE OR REPLACE FUNCTION public.osionos_membership_cutoff_stamp() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  -- C126: the workspace is gone, so its members are gone with it and nothing of it can
  -- be read any more. Signing every member out of the whole account -- the owner who
  -- deleted the workspace included -- would cost far more than it protects. The
  -- deferred trigger runs at COMMIT, so the workspace row of a deleting transaction is
  -- already invisible here.
  IF NOT EXISTS (
    SELECT 1 FROM public.osionos_workspaces w WHERE w.id = OLD.workspace_id
  ) THEN
    RETURN NULL;
  END IF;

  -- C124: an ORPHAN member (a row whose user has no auth.users row) is skipped: the
  -- cutoffs table has a foreign key to auth.users, so the insert would raise 23503 and
  -- abort the membership delete -- and every workspace delete that cascades to it.
  -- There is NO exception handler on purpose: every other failure must abort the
  -- write, or a membership change could be lost silently.
  INSERT INTO public.auth_session_cutoffs (user_id, sessions_valid_after)
  SELECT OLD.user_id, clock_timestamp()
  WHERE EXISTS (SELECT 1 FROM auth.users u WHERE u.id = OLD.user_id)
  ON CONFLICT (user_id) DO UPDATE
    SET sessions_valid_after = EXCLUDED.sessions_valid_after;

  RETURN NULL;
END $$;

-- The monotonic BEFORE UPDATE trigger of the cutoffs table merges the stamp: it keeps
-- the GREATEST of the stored and the new value, so a late writer never un-revokes a
-- session. The upsert above therefore never lowers a cut-off.
DROP TRIGGER IF EXISTS osionos_membership_cutoff ON public.osionos_workspace_members;

-- No column list: a column list would fire on the owner-row upsert of every sign-in
-- (role = 'owner') and refuse every new token (verdict §5).
--
-- TWO constraint triggers, and that is C123's own shape: "AFTER DELETE, plus AFTER
-- UPDATE ... WHEN ((OLD.workspace_id, OLD.user_id) IS DISTINCT FROM (NEW.workspace_id,
-- NEW.user_id))". They cannot be ONE trigger with that WHEN: PostgreSQL refuses a WHEN
-- condition that references NEW on a trigger that also fires on DELETE ("DELETE
-- trigger's WHEN condition cannot reference NEW values"), so the value-change guard
-- lives on the UPDATE trigger alone and the DELETE trigger needs none -- every delete
-- of a members row IS a loss of a membership.
--
-- The WHEN clause is a VALUE change of the two columns that decide WHO lost WHAT: a
-- role or permissions change writes nothing (C123).
DROP TRIGGER IF EXISTS osionos_membership_cutoff_update ON public.osionos_workspace_members;
CREATE CONSTRAINT TRIGGER osionos_membership_cutoff_update
AFTER UPDATE ON public.osionos_workspace_members
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
WHEN ((OLD.workspace_id, OLD.user_id) IS DISTINCT FROM (NEW.workspace_id, NEW.user_id))
EXECUTE FUNCTION public.osionos_membership_cutoff_stamp();

DROP TRIGGER IF EXISTS osionos_membership_cutoff_delete ON public.osionos_workspace_members;
CREATE CONSTRAINT TRIGGER osionos_membership_cutoff_delete
AFTER DELETE ON public.osionos_workspace_members
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION public.osionos_membership_cutoff_stamp();

-- Only the trigger may run this: it is SECURITY DEFINER, and PUBLIC gets no EXECUTE.
REVOKE EXECUTE ON FUNCTION public.osionos_membership_cutoff_stamp() FROM PUBLIC;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- DOWN (manual):
--   DROP TRIGGER osionos_membership_cutoff_update ON public.osionos_workspace_members;
--   DROP TRIGGER osionos_membership_cutoff_delete ON public.osionos_workspace_members;
--   DROP FUNCTION public.osionos_membership_cutoff_stamp();
-- The rows this trigger wrote stay in public.auth_session_cutoffs: they end the
-- sessions of the users it named, once, and only a new sign-in gives them a token.
