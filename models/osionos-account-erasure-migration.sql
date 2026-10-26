-- osionos-account-erasure-migration.sql — the data map, the erase function and
-- the export job table (P5-6-a, root SQL).
--
-- WHY THIS FILE EXISTS
--   Closing an account has to remove a person's data from ~80 columns spread
--   over ~65 tables, and a missed column looks exactly like success. So one
--   registry (osionos_account_data_map) says, per user-keyed column, what the
--   erase does with it, and one function loops over that registry. The export
--   (a later package) reads the same registry, so what is exported and what is
--   erased cannot drift apart. The checks in
--   scripts/verify/models-grants/account-checks.sql (p5_*) seed a row in every
--   registry table, run the erase and search every public table for the user's
--   uuid; that canary, not the registry, is the completeness gate.
--
-- WHAT IT CREATES
--   osionos_account_data_map          the registry (service role only)
--   osionos_account_erasure_objects   storage keys the erase recorded, for the
--                                     bridge to delete (service role only, no FK:
--                                     it must outlive the user)
--   osionos_account_exports           the export job table (account role: read
--                                     own rows, INSERT (user_id, format))
--   osionos_account_deletion_requests five executor columns and a guard trigger
--   osionos_account_tombstone()       the uuid that replaces an erased author
--   osionos_account_deletion_due / _claim   the executor's work queue
--   osionos_account_erase / _erase_plan     the erase, and its dry run
--   osionos_account_export_claim()    the export worker's work queue
--
-- WHO REACHES WHAT
--   service_role  every table and function here.
--   anon, authenticated, osionos_account_user
--                 no function. On osionos_account_exports the account role has
--                 SELECT and INSERT (user_id, format) through RLS on its own
--                 rows; nothing else here.
--
-- WHERE IT RUNS
--   scripts/apply-models-migrations.sh lists it in ORDERED_LAST after the MFA
--   file and before the service-role-only pass, which must find the new tables.
--
-- STORAGE OBJECTS (accepted residual risk)
--   The erase records the keys the SQL can know (a message attachment's
--   object_key, the account exports) in osionos_account_erasure_objects. Avatar,
--   banner and collab-upload objects are stored under the owner's prefix with
--   no database row, so no key exists to record. They are deleted by the
--   bridge's runner in sub-package c, by owner prefix. Until that runner ships
--   they are orphaned after an erase: accepted residual risk, recorded here and
--   in the commit body.
--
-- ATTEMPTS
--   osionos_account_deletion_requests.attempts has one writer:
--   osionos_account_deletion_claim, which adds one per claim (a reclaim after the
--   30-minute lease is another attempt). last_error is the executor's to write.
--
-- Idempotent: a second run changes no grant, policy, index or registry row.
--
-- DOWN (manual, IRREVERSIBLE once an erase has run): DROP FUNCTION the eight
-- osionos_account_* functions below; DROP TABLE osionos_account_exports,
-- osionos_account_erasure_objects, osionos_account_data_map; drop the guard
-- trigger and the five added columns on osionos_account_deletion_requests.

BEGIN;

-- Caveat: a busy table makes this file fail (the transaction rolls back) instead
-- of waiting; the next run retries it. 5 s is a budget, not a promise.
SET LOCAL lock_timeout = '5s';

-- Strongest lock first, in the erase executor's order. A replay ends in an
-- AccessExclusiveLock on these tables (ALTER, ENABLE ROW LEVEL SECURITY, the
-- policies) but its earlier lines take weaker ones: the index lines a ShareLock
-- on the exports, the registry sync a RowExclusiveLock on the map. A worker that
-- locked the table in between then waits for the replay while the replay waits
-- for it: 40P01, seen live 2026-10-26 against osionos_account_export_claim() and
-- 20 of 20 rounds in scripts/verify/account-export-lock-race.sh. Taken here, the
-- replay waits once, under the 5 s budget, and holds what it needs. The order is
-- osionos_account_erase_run's (request, objects, exports, map), so the two never
-- hold each other's next table. A table not created yet is created below, inside
-- this transaction, where no one else can lock it.
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['osionos_account_deletion_requests', 'osionos_account_erasure_objects',
                           'osionos_account_exports', 'osionos_account_data_map'] LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format('LOCK TABLE public.%I IN ACCESS EXCLUSIVE MODE', t);
    END IF;
  END LOOP;
END $$;

-- One constant, one home. No table may reference it with a foreign key: it is
-- not a user, and a FK would either reject it or pin it (p5_no_fk_to_tombstone).
CREATE OR REPLACE FUNCTION public.osionos_account_tombstone() RETURNS uuid
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT '00000000-0000-4000-8000-000000000000'::uuid $$;

-- 1. The registry.
CREATE TABLE IF NOT EXISTS public.osionos_account_data_map (
  table_name TEXT NOT NULL,
  column_name TEXT NOT NULL,
  role TEXT NOT NULL,
  erase TEXT NOT NULL,
  export_columns TEXT[],
  object_bucket TEXT,
  object_key_column TEXT,
  workspace_column TEXT,
  reason TEXT,
  PRIMARY KEY (table_name, column_name),
  CONSTRAINT osionos_account_data_map_role_check
    CHECK (role IN ('owner', 'author', 'member', 'peer')),
  CONSTRAINT osionos_account_data_map_erase_check
    CHECK (erase IN ('delete', 'anonymise', 'nullify', 'transfer', 'scrub_jsonb', 'keep')),
  -- A column that survives the erase must say why, in words a reviewer can judge.
  CONSTRAINT osionos_account_data_map_keep_reason_check
    CHECK (erase <> 'keep' OR length(btrim(coalesce(reason, ''))) > 0),
  -- The erase builds SQL from these names with format('%I'); the CHECK is the
  -- second lock on that door, not the first.
  CONSTRAINT osionos_account_data_map_identifiers_check
    CHECK (table_name ~ '^[a-z_][a-z0-9_]*$'
       AND column_name ~ '^[a-z_][a-z0-9_]*$'
       AND (object_key_column IS NULL OR object_key_column ~ '^[a-z_][a-z0-9_]*$')
       AND (workspace_column IS NULL OR workspace_column ~ '^[a-z_][a-z0-9_]*$')
       AND (export_columns IS NULL
            OR array_to_string(export_columns, ',') ~ '^[a-z_][a-z0-9_]*(,[a-z_][a-z0-9_]*)*$')),
  CONSTRAINT osionos_account_data_map_object_pair_check
    CHECK ((object_bucket IS NULL) = (object_key_column IS NULL))
);

-- The retry list. No FK, no user-facing grant: it is written by the erase and
-- read and emptied by the bridge, after the user row is gone.
CREATE TABLE IF NOT EXISTS public.osionos_account_erasure_objects (
  user_id UUID NOT NULL,
  bucket TEXT NOT NULL,
  key TEXT NOT NULL,
  PRIMARY KEY (user_id, bucket, key)
);

-- 2. The export job table. No object key column: the artifact lives at
-- <owner prefix>/<id>.<format> and the bridge computes it, so a row cannot
-- point at somebody else's object.
CREATE TABLE IF NOT EXISTS public.osionos_account_exports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  format TEXT NOT NULL CHECK (format IN ('json', 'csv', 'zip')),
  status TEXT NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued', 'running', 'done', 'failed', 'expired')),
  requested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  started_at TIMESTAMPTZ,
  finished_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,
  bytes BIGINT,
  error_code TEXT
);
-- Single flight: one active export per user, enforced by the database.
CREATE UNIQUE INDEX IF NOT EXISTS osionos_account_exports_one_active_uidx
  ON public.osionos_account_exports (user_id) WHERE status IN ('queued', 'running');
CREATE INDEX IF NOT EXISTS osionos_account_exports_queue_idx
  ON public.osionos_account_exports (requested_at, id) WHERE status = 'queued';
CREATE INDEX IF NOT EXISTS osionos_account_exports_user_idx
  ON public.osionos_account_exports (user_id, requested_at DESC);

-- 3. The executor's columns on the deletion request.
ALTER TABLE public.osionos_account_deletion_requests
  ADD COLUMN IF NOT EXISTS claimed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS attempts INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_error TEXT,
  ADD COLUMN IF NOT EXISTS erased_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS successor_accepted_at TIMESTAMPTZ;

-- Once the erase has stamped erased_at the request is a fact, not a wish: the
-- account role can no longer cancel it. The test is the CALLER (current_user),
-- so the service role (the executor, GoTrue's cascade) is never blocked. The
-- trigger is plain, not SECURITY DEFINER, and the role's column grants are not
-- widened: the WHEN clause reads erased_at without the role needing SELECT on it.
CREATE OR REPLACE FUNCTION public.osionos_account_deletion_guard() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'deletion_in_progress' USING ERRCODE = 'P0001';
END
$$;
DROP TRIGGER IF EXISTS osionos_account_deletion_requests_guard ON public.osionos_account_deletion_requests;
CREATE TRIGGER osionos_account_deletion_requests_guard
  BEFORE DELETE ON public.osionos_account_deletion_requests
  FOR EACH ROW
  WHEN (current_user = 'osionos_account_user' AND OLD.erased_at IS NOT NULL)
  EXECUTE FUNCTION public.osionos_account_deletion_guard();

-- 4. The registry rows. One row per user-keyed column; `keep` rows carry the
-- reason the canary exempts the TABLE (the canary searches every other table
-- for the user's uuid and must find none).
--   role   owner  = the row is the user's own        author = the user wrote shared content
--          member = the user's membership of a thing  peer   = the user is the other side of a relation
--   erase  delete        the row goes
--          anonymise     the column becomes the tombstone (NULL where a FK forbids it)
--          transfer      handled by the workspace/page rules in osionos_account_erase_run
--          scrub_jsonb   the user's entries leave a jsonb array or object, or a uuid[]
--          keep          nothing happens to the column (reason required)
-- Rows whose UNIQUE key includes the user are `delete`, never `anonymise`
-- (p5_no_fk_to_tombstone reads the catalog for it).
-- Caveat: the column list was found by a name pattern plus the unmatched-table
-- scan on the throwaway DB; a uuid inside a column nobody named is found only by
-- the canary, and only if the canary seeds it.
-- A reporter's erase must not lift a sanction: the report row carries the
-- moderation decision on somebody else, so it stays and its reporter_id is nulled.
ALTER TABLE IF EXISTS public.osionos_user_reports ALTER COLUMN reporter_id DROP NOT NULL;
-- The registry table may predate 'nullify': widen its CHECK once.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.osionos_account_data_map'::regclass
                    AND conname = 'osionos_account_data_map_erase_check'
                    AND pg_get_constraintdef(oid) LIKE '%nullify%') THEN
    ALTER TABLE public.osionos_account_data_map DROP CONSTRAINT IF EXISTS osionos_account_data_map_erase_check;
    ALTER TABLE public.osionos_account_data_map ADD CONSTRAINT osionos_account_data_map_erase_check
      CHECK (erase IN ('delete', 'anonymise', 'nullify', 'transfer', 'scrub_jsonb', 'keep'));
  END IF;
END $$;

CREATE TEMP TABLE osionos_account_data_map_seed (
  t TEXT, c TEXT, r TEXT, e TEXT, x TEXT, b TEXT, k TEXT, w TEXT, why TEXT
) ON COMMIT DROP;

INSERT INTO osionos_account_data_map_seed VALUES
-- AI plane
('ai_access_tokens', 'user_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('ai_agents', 'owner_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('ai_agents', 'created_by', 'author', 'anonymise', NULL, NULL, NULL, NULL, NULL),
('ai_agents', 'updated_by', 'author', 'anonymise', NULL, NULL, NULL, NULL, NULL),
-- The erase runs ai_agents_erase_user first (step 4b'), which scrubs the
-- append-only audit; this row then matches nothing. Never `keep` (C338).
('ai_agents_audit', 'actor_id', 'author', 'anonymise', NULL, NULL, NULL, NULL, NULL),
('ai_workspace_agent_settings', 'updated_by', 'author', 'anonymise', NULL, NULL, NULL, NULL, NULL),
('ai_approvals', 'owner_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('ai_chunks', 'owner_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('ai_chunks', 'collaborator_ids', 'peer', 'scrub_jsonb', NULL, NULL, NULL, NULL, NULL),
('ai_connections', 'owner_user_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('ai_conversations', 'owner_id', 'owner', 'delete', '{id,workspace_id,title,created_at}', NULL, NULL, NULL, NULL),
('ai_events', 'user_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_activity_events', 'user_id', 'owner', 'delete', '{ts,event,surface,workspace_id}', NULL, NULL, NULL, NULL),
('ai_jobs', 'subject_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('ai_mcp_servers', 'owner_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('ai_memories', 'user_id', 'owner', 'delete', '{id,workspace_id,body,status,created_at}', NULL, NULL, NULL, NULL),
('ai_memory_audit', 'actor_id', 'author', 'delete', NULL, NULL, NULL, NULL, NULL),
('ai_moderation_events', 'actor_id', 'author', 'delete', NULL, NULL, NULL, NULL, NULL),
('ai_moderation_events', 'author_id', 'author', 'delete', NULL, NULL, NULL, NULL, NULL),
('ai_moderation_events', 'subject_id', 'peer', 'delete', NULL, NULL, NULL, NULL, NULL),
('ai_personalization_settings', 'user_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('ai_rec_user_factors', 'user_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('ai_runs', 'owner_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('ai_sentiment', 'subject_id', 'peer', 'delete', NULL, NULL, NULL, NULL, NULL),
('ai_sentiment_settings', 'updated_by', 'author', 'anonymise', NULL, NULL, NULL, NULL, NULL),
('ai_skill_audit', 'actor_id', 'author', 'keep', NULL, NULL, NULL, NULL,
  'append-only audit log: a trigger refuses every UPDATE and DELETE with no bypass, so the actor uuid stays as pseudonymous accountability'),
('ai_skills', 'created_by', 'author', 'anonymise', NULL, NULL, NULL, NULL, NULL),
('ai_skills', 'updated_by', 'author', 'anonymise', NULL, NULL, NULL, NULL, NULL),
('ai_usage_daily', 'subject', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
-- identity and security
('auth_audit_events', 'user_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('auth_session_cutoffs', 'user_id', 'owner', 'keep', NULL, NULL, NULL, NULL,
  'must outlive the erase so a token issued before it stays refused; it cascades away when GoTrue deletes the user'),
('mail_messages', 'subject', 'peer', 'keep', NULL, NULL, NULL, NULL,
  'the column is an email subject line (free text), matched by name only; it holds no account id'),
('osionos_account_deletion_requests', 'user_id', 'owner', 'keep', NULL, NULL, NULL, NULL,
  'the executor''s own state (erased_at, attempts); it cascades away when GoTrue deletes the user'),
('osionos_account_deletion_requests', 'successor_user_id', 'peer', 'anonymise', NULL, NULL, NULL, NULL, NULL),
('osionos_account_erasure_objects', 'user_id', 'owner', 'keep', NULL, NULL, NULL, NULL,
  'the retry list of storage keys; the bridge deletes the objects and then these rows'),
('osionos_account_exports', 'user_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_bridge_audit_events', 'actor_id', 'author', 'keep', NULL, NULL, NULL, NULL,
  'pseudonymous accountability: ip_hash and user_agent are nulled, the uuids stay once the identity row is gone'),
('osionos_bridge_audit_events', 'subject', 'owner', 'keep', NULL, NULL, NULL, NULL,
  'pseudonymous accountability: ip_hash and user_agent are nulled, the uuids stay once the identity row is gone'),
('osionos_bridge_identities', 'subject', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_bridge_identities', 'user_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('users', 'id', 'owner', 'keep', '{id,email,name,username,created_at}', NULL, NULL, NULL,
  'the identity anchor: email is replaced by a hash-derived value and every other nullable column but id, created_at and updated_at is nulled by osionos_account_erase_run; the row goes with the GoTrue delete'),
('user_profiles', 'user_id', 'owner', 'delete', '{user_id,display_name,bio,avatar_url,created_at}', NULL, NULL, NULL, NULL),
('posts', 'user_id', 'author', 'delete', '{id,title,content,created_at}', NULL, NULL, NULL, NULL),
-- channels and messages
('osionos_channel_members', 'user_id', 'member', 'delete', '{channel_id,user_id,role,joined_at}', NULL, NULL, NULL, NULL),
('osionos_channel_reads', 'user_id', 'member', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_channels', 'created_by', 'author', 'anonymise', NULL, NULL, NULL, 'workspace_id', NULL),
('osionos_message_attachments', 'owner_id', 'owner', 'delete', NULL, 'chat', 'object_key', NULL, NULL),
('osionos_message_mentions', 'user_id', 'peer', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_message_reactions', 'user_id', 'author', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_message_receipts', 'user_id', 'member', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_messages', 'author_id', 'author', 'anonymise', '{id,channel_id,content,created_at,edited_at}', NULL, NULL, NULL, NULL),
('osionos_notifications', 'user_id', 'owner', 'delete', '{id,type,preview,read_at,created_at}', NULL, NULL, NULL, NULL),
('osionos_notifications', 'actor_id', 'peer', 'delete', NULL, NULL, NULL, NULL, NULL),
-- communities, feed, social graph
('osionos_communities', 'creator_id', 'owner', 'anonymise', '{id,name,description,created_at}', NULL, NULL, NULL, NULL),
('osionos_community_members', 'user_id', 'member', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_connections', 'requester_id', 'peer', 'delete', '{id,requester_id,addressee_id,status,created_at}', NULL, NULL, NULL, NULL),
('osionos_connections', 'addressee_id', 'peer', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_feed_comments', 'author_id', 'author', 'anonymise', '{id,page_id,content,created_at}', NULL, NULL, NULL, NULL),
('osionos_feed_likes', 'user_id', 'author', 'delete', '{page_id,created_at}', NULL, NULL, NULL, NULL),
('osionos_feed_reactions', 'user_id', 'author', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_feed_shares', 'user_id', 'author', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_follows', 'follower_id', 'peer', 'delete', '{follower_id,followee_id,created_at}', NULL, NULL, NULL, NULL),
('osionos_follows', 'followee_id', 'peer', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_join_requests', 'requester_id', 'member', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_join_requests', 'decided_by', 'author', 'anonymise', NULL, NULL, NULL, NULL, NULL),
('osionos_user_blocks', 'blocker_id', 'peer', 'delete', '{blocker_id,blocked_id,created_at}', NULL, NULL, NULL, NULL),
('osionos_user_blocks', 'blocked_id', 'peer', 'delete', NULL, NULL, NULL, NULL, NULL),
-- the report row carries the moderation decision on somebody else: it outlives its
-- reporter, whose id is nulled (NULLs are distinct in the unique index, a tombstone is not)
('osionos_user_reports', 'reporter_id', 'author', 'nullify', NULL, NULL, NULL, NULL, NULL),
('osionos_user_reports', 'subject_user_id', 'peer', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_user_reports', 'subject_id', 'peer', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_user_reports', 'decision_by', 'author', 'anonymise', NULL, NULL, NULL, NULL, NULL),
('osionos_issue_reports', 'reporter_id', 'owner', 'delete', '{id,title,body,route_kind,status,github_url,created_at}', NULL, NULL, NULL, NULL),
-- workspaces, pages, databases
('osionos_workspaces', 'owner_id', 'owner', 'transfer', '{id,name,slug,created_at}', NULL, NULL, NULL, NULL),
('osionos_workspace_members', 'user_id', 'member', 'delete', '{workspace_id,user_id,role,created_at}', NULL, NULL, NULL, NULL),
-- a pending invite is addressed to the invitee (the row goes with them); the people who sent or
-- accepted it are tombstoned. `email` is a display copy of the invitee's, removed with the row.
('osionos_workspace_invites', 'invited_user_id', 'member', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_workspace_invites', 'invited_by', 'author', 'anonymise', NULL, NULL, NULL, NULL, NULL),
('osionos_workspace_invites', 'accepted_by', 'author', 'anonymise', NULL, NULL, NULL, NULL, NULL),
-- a team outlives the person who created it (created_by is tombstoned); a team membership goes
-- with the person (the workspace-member foreign key already cascades it, the row is registered
-- so the erase names it); added_by is tombstoned.
('osionos_teams', 'created_by', 'author', 'anonymise', NULL, NULL, NULL, NULL, NULL),
('osionos_team_members', 'user_id', 'member', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_team_members', 'added_by', 'author', 'anonymise', NULL, NULL, NULL, NULL, NULL),
('osionos_pages', 'owner_id', 'owner', 'transfer', '{id,workspace_id,title,visibility,content,properties,created_at,updated_at}', NULL, NULL, 'workspace_id', NULL),
('osionos_pages', 'collaborators', 'peer', 'scrub_jsonb', NULL, NULL, NULL, 'workspace_id', NULL),
('osionos_page_comments', 'author_id', 'author', 'anonymise', '{id,page_id,content,created_at}', NULL, NULL, NULL, NULL),
('osionos_page_favorites', 'user_id', 'owner', 'delete', '{page_id,created_at}', NULL, NULL, NULL, NULL),
('osionos_page_links', 'owner_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_page_action_events', 'user_id', 'author', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_page_configurations', 'user_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_page_owner_backfill', 'new_owner', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_published_pages', 'owner_id', 'owner', 'delete', '{page_id,title,published_at}', NULL, NULL, NULL, NULL),
('osionos_tasks', 'owner_id', 'owner', 'delete', '{page_id,block_id,content,checked,due_at,updated_at}', NULL, NULL, 'workspace_id', NULL),
('osionos_share_rules', 'target', 'peer', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_object_databases', 'owner_id', 'owner', 'delete', '{id,workspace_id,title,created_at}', NULL, NULL, 'workspace_id', NULL),
('osionos_object_database_rows', 'owner_id', 'owner', 'delete', NULL, NULL, NULL, 'workspace_id', NULL),
('osionos_object_database_rows', 'collaborators', 'peer', 'scrub_jsonb', NULL, NULL, NULL, 'workspace_id', NULL),
('osionos_profile_template_section_grants', 'created_by', 'author', 'anonymise', NULL, NULL, NULL, NULL, NULL),
('osionos_profile_template_section_grants', 'principal_id', 'peer', 'delete', NULL, NULL, NULL, NULL, NULL),
-- the user's own account rows
('osionos_app_connections', 'owner_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_ide_access', 'user_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_mfa_recovery_codes', 'user_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_mfa_totp', 'user_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_user_emails','user_id','owner','delete',NULL,NULL,NULL,NULL,'addresses are ciphertext; an export would need the key'),
('osionos_personal_access_tokens', 'user_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_user_keys', 'user_id', 'owner', 'delete', '{id,kind,title,fingerprint,created_at}', NULL, NULL, NULL, 'public_key and key_type are not exported: the export guard refuses any column named like a key; the fingerprint identifies each key'),
('osionos_presence', 'user_id', 'owner', 'delete', '{state,custom_text,updated_at}', NULL, NULL, NULL, NULL),
('osionos_profiles', 'user_id', 'owner', 'delete',
  '{user_id,display_name,username,pronouns,headline,bio,location,company,website,links,timezone,orcid,patreon,avatar_url,banner_url,profession,status_emoji,status_text,status_expires_at,status_busy,created_at,updated_at}',
  NULL, NULL, NULL, NULL),
('osionos_push_subscriptions', 'user_id', 'owner', 'delete', NULL, NULL, NULL, NULL, NULL),
('osionos_sessions', 'user_id', 'owner', 'delete', '{id,created_at,last_seen_at,auth_method,user_agent}', NULL, NULL, NULL, NULL),
('osionos_user_settings', 'user_id', 'owner', 'delete', '{user_id,section,value,updated_at}', NULL, NULL, NULL, NULL),
-- the held name outlives the user for its 90 days, with no owner (FK is SET NULL)
('osionos_username_history', 'user_id', 'owner', 'anonymise', '{username,changed_at,released_at}', NULL, NULL, NULL, NULL);

INSERT INTO public.osionos_account_data_map
  (table_name, column_name, role, erase, export_columns, object_bucket, object_key_column, workspace_column, reason)
SELECT s.t, s.c, s.r, s.e, s.x::text[], s.b, s.k, s.w, s.why FROM osionos_account_data_map_seed s
ON CONFLICT (table_name, column_name) DO UPDATE
   SET role = EXCLUDED.role, erase = EXCLUDED.erase, export_columns = EXCLUDED.export_columns,
       object_bucket = EXCLUDED.object_bucket, object_key_column = EXCLUDED.object_key_column,
       workspace_column = EXCLUDED.workspace_column, reason = EXCLUDED.reason
 WHERE (osionos_account_data_map.role, osionos_account_data_map.erase, osionos_account_data_map.export_columns,
        osionos_account_data_map.object_bucket, osionos_account_data_map.object_key_column,
        osionos_account_data_map.workspace_column, osionos_account_data_map.reason)
       IS DISTINCT FROM (EXCLUDED.role, EXCLUDED.erase, EXCLUDED.export_columns, EXCLUDED.object_bucket,
                         EXCLUDED.object_key_column, EXCLUDED.workspace_column, EXCLUDED.reason);
-- The registry is exactly this file's list: a row dropped here is dropped there.
DELETE FROM public.osionos_account_data_map d
 WHERE NOT EXISTS (SELECT 1 FROM osionos_account_data_map_seed s WHERE s.t = d.table_name AND s.c = d.column_name);

-- 5. Access: service role only, except the export jobs (account plane).
-- grobase's CREATE TABLE hook (012) broadcasts every row of every new public
-- table and the realtime socket has no grant check; dropped here, not only by
-- realtime-cdc-off, because this file may run without that pass.
DROP TRIGGER IF EXISTS osionos_account_data_map_realtime_trigger ON public.osionos_account_data_map;
DROP TRIGGER IF EXISTS osionos_account_erasure_objects_realtime_trigger ON public.osionos_account_erasure_objects;
DROP TRIGGER IF EXISTS osionos_account_exports_realtime_trigger ON public.osionos_account_exports;

ALTER TABLE public.osionos_account_data_map ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_account_erasure_objects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_account_exports ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.osionos_account_data_map FROM PUBLIC, anon, authenticated, osionos_account_user;
REVOKE ALL ON public.osionos_account_erasure_objects FROM PUBLIC, anon, authenticated, osionos_account_user;
REVOKE ALL ON public.osionos_account_exports FROM PUBLIC, anon, authenticated, osionos_account_user;
GRANT ALL ON public.osionos_account_data_map TO service_role;
GRANT ALL ON public.osionos_account_erasure_objects TO service_role;
GRANT ALL ON public.osionos_account_exports TO service_role;

-- The account role reads its own jobs and can queue one. It can never write a
-- status, a byte count or a time: the worker owns the lifecycle.
GRANT SELECT ON public.osionos_account_exports TO osionos_account_user;
GRANT INSERT (user_id, format) ON public.osionos_account_exports TO osionos_account_user;

DROP POLICY IF EXISTS osionos_account_data_map_service_role_all ON public.osionos_account_data_map;
CREATE POLICY osionos_account_data_map_service_role_all ON public.osionos_account_data_map
  FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS osionos_account_erasure_objects_service_role_all ON public.osionos_account_erasure_objects;
CREATE POLICY osionos_account_erasure_objects_service_role_all ON public.osionos_account_erasure_objects
  FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS osionos_account_exports_service_role_all ON public.osionos_account_exports;
CREATE POLICY osionos_account_exports_service_role_all ON public.osionos_account_exports
  FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS osionos_account_exports_owner_all ON public.osionos_account_exports;
CREATE POLICY osionos_account_exports_owner_all ON public.osionos_account_exports
  FOR ALL TO osionos_account_user
  USING (user_id = (SELECT public.osionos_account_uid()))
  WITH CHECK (user_id = (SELECT public.osionos_account_uid()));
COMMENT ON TABLE public.osionos_account_exports IS 'osionos:account-plane';

-- 6. The executor's work queue.
-- The lease is 30 minutes: a runner that died after claiming leaves its rows
-- claimable again. Rows with erased_at set stay claimable on purpose: the erase
-- is idempotent and a crash after it must be finished, not skipped.
-- Caveat: the lease is a clock, not liveness. A runner still working after 30
-- minutes can be joined by a second one on the same user; the erase is
-- idempotent and takes the row lock, so the second waits, but the objects and
-- the GoTrue delete are the runner's to make safe.
CREATE OR REPLACE FUNCTION public.osionos_account_deletion_due(p_limit integer)
RETURNS TABLE (user_id uuid, scheduled_for timestamptz, attempts integer, erased_at timestamptz, successor_user_id uuid)
LANGUAGE sql STABLE
AS $$
  SELECT r.user_id, r.scheduled_for, r.attempts, r.erased_at, r.successor_user_id
    FROM public.osionos_account_deletion_requests r
   WHERE r.scheduled_for <= now() AND r.attempts < 5
   ORDER BY r.scheduled_for, r.user_id
   LIMIT greatest(coalesce(p_limit, 0), 0)
$$;

-- A batch never exceeds 5: the executor waits 70 s per batch, so the batch size
-- is also the worst-case time a user waits after their grace ends.
CREATE OR REPLACE FUNCTION public.osionos_account_deletion_claim(p_limit integer)
RETURNS TABLE (user_id uuid, scheduled_for timestamptz, attempts integer, erased_at timestamptz, successor_user_id uuid)
LANGUAGE sql VOLATILE
AS $$
  WITH picked AS (
    SELECT q.user_id
      FROM public.osionos_account_deletion_requests q
     WHERE q.scheduled_for <= now() AND q.attempts < 5
       AND (q.claimed_at IS NULL OR q.claimed_at < now() - interval '30 minutes')
     ORDER BY q.scheduled_for, q.user_id
     LIMIT least(greatest(coalesce(p_limit, 0), 0), 5)
       FOR UPDATE SKIP LOCKED
  )
  UPDATE public.osionos_account_deletion_requests r
     SET claimed_at = now(), attempts = r.attempts + 1
    FROM picked
   WHERE r.user_id = picked.user_id
  RETURNING r.user_id, r.scheduled_for, r.attempts, r.erased_at, r.successor_user_id
$$;

CREATE OR REPLACE FUNCTION public.osionos_account_export_claim()
RETURNS TABLE (id uuid, user_id uuid, format text, requested_at timestamptz)
LANGUAGE sql VOLATILE
AS $$
  WITH picked AS (
    SELECT q.id
      FROM public.osionos_account_exports q
     WHERE q.status = 'queued'
        OR (q.status = 'running' AND q.started_at < now() - interval '30 minutes')
     ORDER BY q.requested_at, q.id
     LIMIT 1
       FOR UPDATE SKIP LOCKED
  )
  UPDATE public.osionos_account_exports e
     SET status = 'running', started_at = now()
    FROM picked
   WHERE e.id = picked.id
  RETURNING e.id, e.user_id, e.format, e.requested_at
$$;

-- 7. The erase.
-- Does workspace `p_ws` hold content a non-member wrote or owns? Looked at only
-- when the user is the workspace's last member: deleting such a workspace would
-- delete somebody else's work. Messages and page comments carry no workspace
-- column, so they are reached through their channel and page.
-- Caveat: "member" here means "not the user and not the tombstone": the workspace
-- has no other member when this runs. A table the registry gives no
-- workspace_column, and that is not messages or page comments, is not looked at.
CREATE OR REPLACE FUNCTION public.osionos_account_workspace_has_foreign_content(p_ws uuid, p_user uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tomb constant uuid := public.osionos_account_tombstone();
  m record;
  v_typ text;
  v_found boolean;
BEGIN
  IF EXISTS (SELECT 1 FROM public.osionos_messages x JOIN public.osionos_channels ch ON ch.id = x.channel_id
              WHERE ch.workspace_id = p_ws AND x.author_id IS DISTINCT FROM p_user AND x.author_id IS DISTINCT FROM v_tomb) THEN
    RETURN true;
  END IF;
  IF EXISTS (SELECT 1 FROM public.osionos_page_comments x JOIN public.osionos_pages pg ON pg.id = x.page_id
              WHERE pg.workspace_id = p_ws AND x.author_id IS DISTINCT FROM p_user AND x.author_id IS DISTINCT FROM v_tomb) THEN
    RETURN true;
  END IF;
  FOR m IN SELECT d.table_name, d.column_name, d.workspace_column
             FROM public.osionos_account_data_map d
            WHERE d.workspace_column IS NOT NULL AND d.erase <> 'keep'
            ORDER BY d.table_name, d.column_name
  LOOP
    SELECT format_type(a.atttypid, a.atttypmod) INTO v_typ
      FROM pg_attribute a
     WHERE a.attrelid = to_regclass(format('public.%I', m.table_name))
       AND a.attname = m.column_name AND NOT a.attisdropped;
    IF NOT FOUND THEN
      CONTINUE;
    END IF;
    IF v_typ = 'jsonb' THEN
      EXECUTE format(
        'SELECT EXISTS (SELECT 1 FROM public.%I t, jsonb_array_elements(CASE WHEN jsonb_typeof(t.%I) = ''array'' THEN t.%I ELSE ''[]''::jsonb END) e WHERE t.%I = $1 AND e::text NOT LIKE ''%%'' || $2::text || ''%%'')',
        m.table_name, m.column_name, m.column_name, m.workspace_column) INTO v_found USING p_ws, p_user;
    ELSE
      EXECUTE format(
        'SELECT EXISTS (SELECT 1 FROM public.%I t WHERE t.%I = $1 AND t.%I::text IS DISTINCT FROM $2::text AND t.%I::text IS DISTINCT FROM $3::text)',
        m.table_name, m.workspace_column, m.column_name, m.column_name) INTO v_found USING p_ws, p_user, v_tomb;
    END IF;
    IF v_found THEN
      RETURN true;
    END IF;
  END LOOP;
  RETURN false;
END
$$;

-- The run body. The plan and the real erase both call it, so the plan cannot
-- drift from what the erase does. Order: lock the request, check the grace,
-- stamp erased_at, record the storage keys, then workspaces and pages, then the
-- registry, then the identity row and the audit scrub.
-- The two osionos.*_erase settings are the bypass the append-only AI audit
-- tables define for exactly this job; as function SET clauses they end with
-- the call.
-- Caveat: a null or unknown registry table is skipped and listed under
-- "skipped" in the result, not failed; the canary is what fails a missed table.
-- Caveat: two erases of users who share a workspace can deadlock (each locks the
-- workspaces it owns); Postgres aborts one and the executor's retry finishes it.
CREATE OR REPLACE FUNCTION public.osionos_account_erase_run(p_user uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
SET lock_timeout = '5s'
SET osionos.memory_erase = 'on'
SET osionos.moderation_erase = 'on'
AS $$
DECLARE
  v_tomb constant uuid := public.osionos_account_tombstone();
  v_req public.osionos_account_deletion_requests%ROWTYPE;
  v_counts jsonb := '{}'::jsonb;
  v_ws jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_n bigint;
  v_pages_deleted bigint;
  v_pages_passed bigint;
  v_n_transferred integer := 0;
  v_n_promoted integer := 0;
  v_n_deleted integer := 0;
  v_n_orphaned integer := 0;
  v_successor text := 'none';
  v_state text;
  v_owner uuid;
  v_disp text;
  w record;
  d record;
  v_reg regclass;
  v_typ text;
  v_notnull boolean;
  v_attnum smallint;
  v_has_fk boolean;
  v_pred text;
  v_new text;
  v_set text;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'user_required' USING ERRCODE = 'P0001';
  END IF;

  -- 1. The request, locked: a cancel waits for this transaction, and once it
  -- has stamped erased_at the cancel is refused by the guard trigger.
  SELECT * INTO v_req FROM public.osionos_account_deletion_requests
   WHERE user_id = p_user FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no_deletion_request' USING ERRCODE = 'P0001';
  END IF;
  -- The grace is the server's: the executor's clock is not trusted to have
  -- asked at the right time. A request already stamped keeps going (a crash
  -- after the first pass is finished, not refused).
  IF v_req.scheduled_for > now() AND v_req.erased_at IS NULL THEN
    RAISE EXCEPTION 'grace_not_over' USING ERRCODE = 'P0001';
  END IF;

  -- 2. Stamp once; a re-run keeps the first value.
  UPDATE public.osionos_account_deletion_requests SET erased_at = now()
   WHERE user_id = p_user AND erased_at IS NULL;

  -- 3. Record every storage key before any row that names it goes.
  -- The key is the CALLER-RELATIVE one, `<id>.<format>`, exactly what the bridge stored
  -- (EXPORT_KEY_FOR, osionos app scripts/bridge-account-export-runner.mjs:34). The storage router
  -- prefixes `<user_id>/` itself on put AND delete (grobase storage.service.ts ownedKey), so a key
  -- recorded with the prefix would be deleted as `<user_id>/<user_id>/...`, a no-op that S3 answers
  -- 204, and the archive would outlive the erase.
  INSERT INTO public.osionos_account_erasure_objects (user_id, bucket, key)
  SELECT e.user_id, 'account-exports', e.id::text || '.' || e.format
    FROM public.osionos_account_exports e WHERE e.user_id = p_user
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('erasure_objects', v_n);
  FOR d IN SELECT m.table_name, m.column_name, m.object_bucket, m.object_key_column
             FROM public.osionos_account_data_map m
            WHERE m.object_bucket IS NOT NULL AND m.erase <> 'keep'
            ORDER BY m.table_name, m.column_name
  LOOP
    v_reg := to_regclass(format('public.%I', d.table_name));
    IF v_reg IS NULL THEN
      v_skipped := v_skipped || to_jsonb(d.table_name || '.' || d.column_name);
      CONTINUE;
    END IF;
    SELECT format_type(a.atttypid, a.atttypmod) INTO v_typ FROM pg_attribute a
     WHERE a.attrelid = v_reg AND a.attname = d.column_name AND NOT a.attisdropped;
    v_pred := CASE v_typ
      WHEN 'uuid' THEN format('%I = $1', d.column_name)
      ELSE format('%I::text = $1::text', d.column_name) END;
    EXECUTE format(
      'INSERT INTO public.osionos_account_erasure_objects (user_id, bucket, key) SELECT $1, %L, t.%I FROM public.%I t WHERE t.%s AND t.%I IS NOT NULL ON CONFLICT DO NOTHING',
      d.object_bucket, d.object_key_column, d.table_name, v_pred, d.object_key_column) USING p_user;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_counts := jsonb_set(v_counts, '{erasure_objects}', to_jsonb((v_counts ->> 'erasure_objects')::bigint + v_n));
  END LOOP;

  -- 4a. Workspaces the user owns (D5). The successor is judged NOW, not at
  -- request time: an accepted successor who has since left is no successor.
  FOR w IN SELECT id FROM public.osionos_workspaces WHERE owner_id = p_user ORDER BY id FOR UPDATE
  LOOP
    v_owner := NULL;
    v_state := CASE
      WHEN v_req.successor_user_id IS NULL THEN 'none'
      WHEN v_req.successor_accepted_at IS NULL THEN 'not_accepted'
      WHEN NOT EXISTS (SELECT 1 FROM public.osionos_workspace_members mm
                        WHERE mm.workspace_id = w.id AND mm.user_id = v_req.successor_user_id) THEN 'left'
      ELSE 'accepted' END;
    IF v_state = 'accepted' THEN
      v_owner := v_req.successor_user_id;
      v_disp := 'transferred';
    ELSE
      -- Oldest admin (or co-owner), else oldest member; created_at ties broken by user_id.
      SELECT mm.user_id INTO v_owner
        FROM public.osionos_workspace_members mm
       WHERE mm.workspace_id = w.id AND mm.user_id NOT IN (p_user, v_tomb)
       ORDER BY (mm.role IN ('owner', 'admin')) DESC, mm.created_at, mm.user_id
       LIMIT 1;
      IF FOUND THEN
        v_disp := 'promoted';
      ELSIF public.osionos_account_workspace_has_foreign_content(w.id, p_user) THEN
        v_disp := 'kept_orphaned';
      ELSE
        v_disp := 'deleted';
      END IF;
    END IF;

    IF v_disp IN ('transferred', 'promoted') THEN
      UPDATE public.osionos_workspaces SET owner_id = v_owner WHERE id = w.id;
      UPDATE public.osionos_workspace_members
         SET role = 'owner', permissions = ARRAY['create','read','update','delete','admin'], updated_at = now()
       WHERE workspace_id = w.id AND user_id = v_owner;
      IF v_disp = 'promoted' THEN
        -- The text names a workspace id and nobody else: no user id, no user name.
        INSERT INTO public.osionos_notifications (user_id, type, preview)
        VALUES (v_owner, 'system', 'You are now an owner of workspace ' || w.id::text
                                   || ': its previous owner closed their account.');
      END IF;
    ELSIF v_disp = 'kept_orphaned' THEN
      -- Caveat: an orphaned workspace has no administrator until a human assigns one.
      UPDATE public.osionos_workspaces SET owner_id = v_tomb WHERE id = w.id;
    ELSE
      DELETE FROM public.osionos_workspaces WHERE id = w.id;
    END IF;

    v_n_transferred := v_n_transferred + (v_disp = 'transferred')::integer;
    v_n_promoted := v_n_promoted + (v_disp = 'promoted')::integer;
    v_n_deleted := v_n_deleted + (v_disp = 'deleted')::integer;
    v_n_orphaned := v_n_orphaned + (v_disp = 'kept_orphaned')::integer;
    v_ws := v_ws || jsonb_build_array(jsonb_build_object('id', w.id, 'disposition', v_disp, 'successor', v_state));
    -- One word for the request: accepted beats left beats not_accepted beats none.
    v_successor := CASE
      WHEN v_successor = 'accepted' OR v_state = 'accepted' THEN 'accepted'
      WHEN v_successor = 'left' OR v_state = 'left' THEN 'left'
      WHEN v_successor = 'not_accepted' OR v_state = 'not_accepted' THEN 'not_accepted'
      ELSE 'none' END;
  END LOOP;
  v_counts := v_counts || jsonb_build_object('notifications_sent', v_n_promoted);

  -- 4b. Pages the user owns in workspaces they leave: private ones go, shared
  -- and public ones pass to the workspace's (new) owner.
  DELETE FROM public.osionos_pages WHERE owner_id = p_user AND visibility = 'private';
  GET DIAGNOSTICS v_pages_deleted = ROW_COUNT;
  UPDATE public.osionos_pages p SET owner_id = ws.owner_id
    FROM public.osionos_workspaces ws
   WHERE p.owner_id = p_user AND p.workspace_id = ws.id AND p.visibility IN ('shared', 'public');
  GET DIAGNOSTICS v_pages_passed = ROW_COUNT;

  -- 4b'. Custom agents (osionos-ai-runs-agents-migration.sql). Their audit is
  -- append-only, so the registry's plain UPDATE below would be refused and the
  -- whole erase rolled back. ai_agents_erase_user lifts the trigger for its own
  -- call and tombstones or deletes every agent row of the user; the registry
  -- rows of those tables then match nothing. Guarded: that file may be absent.
  IF to_regprocedure('public.ai_agents_erase_user(uuid)') IS NOT NULL THEN
    EXECUTE 'SELECT public.ai_agents_erase_user($1)' USING p_user;
  END IF;

  -- 4c. The registry. `transfer` rows were handled above; `keep` rows are left.
  FOR d IN SELECT m.table_name, m.column_name, m.erase
             FROM public.osionos_account_data_map m
            WHERE m.erase IN ('delete', 'anonymise', 'nullify', 'scrub_jsonb')
            ORDER BY m.table_name, m.column_name
  LOOP
    v_reg := to_regclass(format('public.%I', d.table_name));
    v_typ := NULL;
    IF v_reg IS NOT NULL THEN
      SELECT format_type(a.atttypid, a.atttypmod), a.attnotnull, a.attnum
        INTO v_typ, v_notnull, v_attnum
        FROM pg_attribute a
       WHERE a.attrelid = v_reg AND a.attname = d.column_name AND NOT a.attisdropped;
    END IF;
    IF v_typ IS NULL THEN
      v_skipped := v_skipped || to_jsonb(d.table_name || '.' || d.column_name);
      CONTINUE;
    END IF;
    v_pred := CASE
      WHEN v_typ = 'uuid' THEN format('%I = $1', d.column_name)
      WHEN v_typ = 'jsonb' THEN format('%I::text LIKE ''%%'' || $1::text || ''%%''', d.column_name)
      WHEN v_typ = 'uuid[]' THEN format('$1 = ANY (%I)', d.column_name)
      ELSE format('%I::text = $1::text', d.column_name) END;

    IF d.erase = 'delete' THEN
      EXECUTE format('DELETE FROM public.%I WHERE %s', d.table_name, v_pred) USING p_user;
    ELSIF d.erase = 'nullify' THEN
      IF v_notnull THEN
        RAISE EXCEPTION 'registry_error: %.% is NOT NULL, it cannot be nullified',
          d.table_name, d.column_name USING ERRCODE = 'P0001';
      END IF;
      EXECUTE format('UPDATE public.%I SET %I = NULL WHERE %s', d.table_name, d.column_name, v_pred) USING p_user;
    ELSIF d.erase = 'anonymise' THEN
      -- The tombstone where the column may hold it; NULL where a foreign key
      -- would refuse it and the column allows NULL; anything else is a registry
      -- error and aborts the whole erase rather than half-do it.
      SELECT EXISTS (SELECT 1 FROM pg_constraint c
                      WHERE c.conrelid = v_reg AND c.contype = 'f' AND v_attnum = ANY (c.conkey))
        INTO v_has_fk;
      IF v_has_fk THEN
        IF v_notnull THEN
          RAISE EXCEPTION 'registry_error: %.% is a NOT NULL foreign key, it cannot be anonymised',
            d.table_name, d.column_name USING ERRCODE = 'P0001';
        END IF;
        v_new := 'NULL';
      ELSIF v_typ = 'uuid' THEN
        v_new := '$2';
      ELSIF v_typ IN ('text', 'character varying') THEN
        v_new := '$2::text';
      ELSE
        RAISE EXCEPTION 'registry_error: %.% has type %, it cannot be anonymised',
          d.table_name, d.column_name, v_typ USING ERRCODE = 'P0001';
      END IF;
      EXECUTE format('UPDATE public.%I SET %I = %s WHERE %s', d.table_name, d.column_name, v_new, v_pred)
        USING p_user, v_tomb;
    ELSIF v_typ = 'uuid[]' THEN
      EXECUTE format('UPDATE public.%I SET %I = array_remove(%I, $1) WHERE %s', d.table_name, d.column_name, d.column_name, v_pred)
        USING p_user;
    ELSE
      -- scrub_jsonb: the user's entries leave an array (or an object's keys).
      -- Caveat: an entry is dropped when its text mentions the uuid anywhere, so
      -- a page whose title happens to hold the uuid loses nothing but a nested
      -- entry that mentions the user would be dropped whole.
      EXECUTE format(
        'UPDATE public.%I SET %I = CASE jsonb_typeof(%I) '
        || 'WHEN ''array'' THEN (SELECT coalesce(jsonb_agg(e), ''[]''::jsonb) FROM jsonb_array_elements(%I) e WHERE e::text NOT LIKE ''%%'' || $1::text || ''%%'') '
        || 'WHEN ''object'' THEN (SELECT coalesce(jsonb_object_agg(kv.k, kv.v), ''{}''::jsonb) FROM jsonb_each(%I) kv(k, v) WHERE kv.k NOT LIKE ''%%'' || $1::text || ''%%'' AND kv.v::text NOT LIKE ''%%'' || $1::text || ''%%'') '
        || 'ELSE %I END WHERE %s',
        d.table_name, d.column_name, d.column_name, d.column_name, d.column_name, d.column_name, v_pred)
        USING p_user;
    END IF;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object(d.table_name || '.' || d.column_name, v_n);
  END LOOP;

  -- 4d. The identity row keeps its id (it is the anchor other tables point at)
  -- and loses everything that names the person. email is unique, so it is
  -- replaced by a value derived from the id's hash, not from the id.
  IF to_regclass('public.users') IS NOT NULL THEN
    -- Every nullable column but the id and the two timestamps is nulled, so a
    -- personal column a later migration adds to users is scrubbed without an edit
    -- here. A NOT NULL column other than id and email survives (listed in no
    -- result): p5_users_scrubbed fails on it.
    SELECT string_agg(format('%I = NULL', c.column_name), ', ') INTO v_set
      FROM information_schema.columns c
     WHERE c.table_schema = 'public' AND c.table_name = 'users' AND c.is_nullable = 'YES'
       AND c.column_name NOT IN ('id', 'email', 'created_at', 'updated_at');
    EXECUTE format(
      'UPDATE public.users SET email = $2%s WHERE id = $1 AND email IS DISTINCT FROM $2',
      CASE WHEN v_set IS NULL THEN '' ELSE ', ' || v_set END)
      USING p_user, 'erased-' || md5(p_user::text) || '@erased.invalid';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_counts := v_counts || jsonb_build_object('users.identity', v_n);
  END IF;

  -- 5. The audit rows stay (accountability), the fingerprints do not.
  UPDATE public.osionos_bridge_audit_events SET ip_hash = NULL, user_agent = NULL
   WHERE (actor_id = p_user OR subject = p_user) AND (ip_hash IS NOT NULL OR user_agent IS NOT NULL);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_counts := v_counts || jsonb_build_object('osionos_bridge_audit_events.scrubbed', v_n);

  RETURN jsonb_build_object(
    'user', p_user,
    'counts', v_counts,
    'workspaces', v_ws,
    'dispositions', jsonb_build_object('transferred', v_n_transferred, 'promoted', v_n_promoted,
                                       'deleted', v_n_deleted, 'kept_orphaned', v_n_orphaned),
    'successor', v_successor,
    'pages', jsonb_build_object('deleted', v_pages_deleted, 'passed', v_pages_passed),
    'skipped', v_skipped);
END
$$;

CREATE OR REPLACE FUNCTION public.osionos_account_erase(p_user uuid) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
SET lock_timeout = '5s'
AS $$ SELECT public.osionos_account_erase_run(p_user) $$;

-- The plan runs the real body and throws its answer away with its writes: a
-- subtransaction that ends in a private error code is rolled back whole, so the
-- plan stamps nothing, notifies nobody and matches the erase by construction.
-- Caveat: the plan takes the same row locks as the erase while it runs, and
-- sequences it advances are not rolled back; it is a read for people, not a
-- cheap probe to call in a loop.
CREATE OR REPLACE FUNCTION public.osionos_account_erase_plan(p_user uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
SET lock_timeout = '5s'
AS $$
DECLARE
  v_plan text;
BEGIN
  BEGIN
    RAISE EXCEPTION USING ERRCODE = 'P5PLN', MESSAGE = public.osionos_account_erase_run(p_user)::text;
  EXCEPTION WHEN SQLSTATE 'P5PLN' THEN
    GET STACKED DIAGNOSTICS v_plan = MESSAGE_TEXT;
  END;
  RETURN v_plan::jsonb;
END
$$;

-- 8. Execute: the service role and nobody else. PUBLIC is named because a new
-- function is executable by PUBLIC until it is revoked.
REVOKE ALL ON FUNCTION public.osionos_account_tombstone() FROM PUBLIC, anon, authenticated, osionos_account_user;
REVOKE ALL ON FUNCTION public.osionos_account_deletion_guard() FROM PUBLIC, anon, authenticated, osionos_account_user;
REVOKE ALL ON FUNCTION public.osionos_account_deletion_due(integer) FROM PUBLIC, anon, authenticated, osionos_account_user;
REVOKE ALL ON FUNCTION public.osionos_account_deletion_claim(integer) FROM PUBLIC, anon, authenticated, osionos_account_user;
REVOKE ALL ON FUNCTION public.osionos_account_export_claim() FROM PUBLIC, anon, authenticated, osionos_account_user;
REVOKE ALL ON FUNCTION public.osionos_account_workspace_has_foreign_content(uuid, uuid) FROM PUBLIC, anon, authenticated, osionos_account_user;
REVOKE ALL ON FUNCTION public.osionos_account_erase_run(uuid) FROM PUBLIC, anon, authenticated, osionos_account_user;
REVOKE ALL ON FUNCTION public.osionos_account_erase(uuid) FROM PUBLIC, anon, authenticated, osionos_account_user;
REVOKE ALL ON FUNCTION public.osionos_account_erase_plan(uuid) FROM PUBLIC, anon, authenticated, osionos_account_user;
GRANT EXECUTE ON FUNCTION public.osionos_account_tombstone() TO service_role;
GRANT EXECUTE ON FUNCTION public.osionos_account_deletion_due(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.osionos_account_deletion_claim(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.osionos_account_export_claim() TO service_role;
GRANT EXECUTE ON FUNCTION public.osionos_account_workspace_has_foreign_content(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.osionos_account_erase_run(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.osionos_account_erase(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.osionos_account_erase_plan(uuid) TO service_role;

COMMIT;
