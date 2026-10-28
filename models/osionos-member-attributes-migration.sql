-- osionos member attributes: a workspace admin's tags on one member
-- (department=legal, clearance=2), so a share rule can later target them through
-- target_key `attribute:<name>:<value>` (models/osionos-share-rules-migration.sql,
-- <= 200 chars). Served ONLY through the bridge; nothing reads this table yet —
-- the bridge writer and the AI evaluators are later units.
--
-- Only admins write: service_role is the only grant, so a member can never tag
-- themselves (C643); the bridge checks the caller's live workspace role before
-- it writes. A row dies with its membership: the composite foreign key below is
-- the invariant, so removing someone from the workspace removes every attribute
-- of theirs with it, and the database (not only the bridge) refuses an attribute
-- row for a user who is not a workspace member.
--
-- value forbids ':' so `attribute:<name>:<value>` stays unambiguous: the name is at
-- most 32 characters and the value at most 64, so 10 + 32 + 64 is well under the
-- share rule's 200-char target_key (share-rules-migration.sql:26).
--
-- WHERE IT RUNS
--   scripts/apply-models-migrations.sh applies it in the plain alphabetical
--   pass, which runs after ORDERED_FIRST — confirmed in that runner, where
--   osionos-bridge-migration.sql is listed in ORDERED_FIRST and creates
--   osionos_workspace_members, this file's foreign-key target. The file is in
--   neither list, so it takes the alphabetical pass and inherits that order.
--
-- One transaction: this database's default privileges give anon/authenticated
-- SELECT/INSERT/UPDATE/DELETE on every new public table, so a half-applied file would leave
-- the table writable with the public anon key through Kong /rest/v1. Apply with
--   psql -v ON_ERROR_STOP=1 -f models/osionos-member-attributes-migration.sql
-- or `make apply-models`. Idempotent.
--
-- Guests carry no attributes (C645). A guest IS a members row (role 'viewer',
-- osionos-bridge-migration.sql:42), so the foreign key alone admits them: a
-- BEFORE trigger refuses an attribute row for a viewer (23514), and demoting a
-- member to viewer deletes their attributes in the same statement.

BEGIN;

CREATE TABLE IF NOT EXISTS public.osionos_member_attributes (
  workspace_id UUID        NOT NULL,
  user_id      UUID        NOT NULL,
  name         TEXT        NOT NULL CHECK (name ~ '^[a-z][a-z0-9_]{0,31}$'),
  value        TEXT        NOT NULL
               CHECK (char_length(value) BETWEEN 1 AND 64 AND value !~ ':'
                      AND value !~ '^\s|\s$' AND value !~ '[[:cntrl:]]'),
  set_by       UUID        NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- one value per name per member
  PRIMARY KEY (workspace_id, user_id, name),
  -- the target of the composite foreign key: an attribute row lives and dies with
  -- the membership it describes
  CONSTRAINT osionos_member_attributes_member_fk FOREIGN KEY (workspace_id, user_id)
    REFERENCES public.osionos_workspace_members (workspace_id, user_id) ON DELETE CASCADE
);

-- The evaluator's read is "this caller's attributes in this workspace", which is
-- the PK prefix (workspace_id, user_id): it needs no index of its own. What has
-- no prefix here is the admin's list — "who carries this attribute" — and that is
-- what the index below serves.
CREATE INDEX IF NOT EXISTS osionos_member_attributes_attribute_idx
  ON public.osionos_member_attributes (workspace_id, name, value);

REVOKE ALL ON public.osionos_member_attributes FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.osionos_member_attributes TO service_role;

ALTER TABLE public.osionos_member_attributes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_member_attributes FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS osionos_member_attributes_service_role_all ON public.osionos_member_attributes;
CREATE POLICY osionos_member_attributes_service_role_all ON public.osionos_member_attributes
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- The realtime event trigger attaches a row-broadcasting trigger to every new public table.
-- Nothing consumes attribute changes, and a broadcast is one more path out of the table.
DROP TRIGGER IF EXISTS osionos_member_attributes_realtime_trigger ON public.osionos_member_attributes;

-- SECURITY DEFINER: FOR SHARE needs UPDATE-level privilege on the members table, which the
-- writer may not hold.
CREATE OR REPLACE FUNCTION public.osionos_member_attributes_refuse_guest() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE r text;
BEGIN
  -- FOR SHARE: a concurrent demotion to viewer waits for this insert to commit, so its
  -- drop_on_guest sees the row; without the lock both commit and the guest keeps the tag.
  SELECT m.role INTO r FROM public.osionos_workspace_members m
   WHERE m.workspace_id = NEW.workspace_id AND m.user_id = NEW.user_id
     FOR SHARE;
  -- NOT FOUND is left to the foreign key, which raises 23503 for a non-member.
  IF FOUND AND r = 'viewer' THEN
    RAISE EXCEPTION 'a guest carries no member attributes' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS osionos_member_attributes_refuse_guest ON public.osionos_member_attributes;
CREATE TRIGGER osionos_member_attributes_refuse_guest
BEFORE INSERT OR UPDATE OF workspace_id, user_id ON public.osionos_member_attributes
FOR EACH ROW EXECUTE FUNCTION public.osionos_member_attributes_refuse_guest();

-- SECURITY DEFINER: whoever demotes the member may hold no grant on this table,
-- and the demotion must not fail (or leave the rows) because of it.
CREATE OR REPLACE FUNCTION public.osionos_member_attributes_drop_on_guest() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  DELETE FROM public.osionos_member_attributes a
   WHERE a.workspace_id = NEW.workspace_id AND a.user_id = NEW.user_id;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS osionos_member_attributes_drop_on_guest ON public.osionos_workspace_members;
CREATE TRIGGER osionos_member_attributes_drop_on_guest
AFTER UPDATE ON public.osionos_workspace_members
FOR EACH ROW
WHEN (NEW.role = 'viewer' AND OLD.role IS DISTINCT FROM 'viewer')
EXECUTE FUNCTION public.osionos_member_attributes_drop_on_guest();

-- Trigger functions are not callable APIs.
REVOKE ALL ON FUNCTION public.osionos_member_attributes_refuse_guest() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.osionos_member_attributes_drop_on_guest() FROM PUBLIC;

COMMIT;

NOTIFY pgrst, 'reload schema';
