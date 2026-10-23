-- osionos-session-refresh-migration.sql — the rotating refresh token's grant and
-- indexes (P3-3-a).
--
-- WHY THIS FILE EXISTS
--   The bridge now mints a refresh token per sign-in and rotates it. A rotation
--   writes a child row (family_id = the sign-in's row, parent_id = the row it
--   replaces); the owner's Sessions list collapses rows per family, so the account
--   role has to read family_id. No table or column is added: family_id, parent_id,
--   refresh_hash and the 'refresh_reuse' reason exist since the foundation file.
--
-- WHO REACHES WHAT
--   osionos_account_user  ten session columns (the nine of the foundation file plus
--                         family_id). refresh_hash, ip_hash, parent_id and user_id
--                         stay out of the grant.
--
-- INDEXES
--   osionos_sessions_family_live_idx   the family revoke and the list collapse
--   osionos_sessions_refresh_hash_idx  the refresh lookup (a token is found by its hash)
--   osionos_sessions_parent_uniq       one child per row: two concurrent rotations of
--                                      the same token cannot both succeed, the second
--                                      INSERT fails and the bridge answers it as reuse
--
-- WHERE IT RUNS
--   scripts/apply-models-migrations.sh lists it in ORDERED_LAST right after the
--   foundation file (the alphabetical pass runs before that file creates
--   public.osionos_sessions and osionos_account_user).
--
-- REPLAY
--   Idempotent: the REVOKE then GRANT leaves the same ACL, the indexes are
--   IF NOT EXISTS.
--
-- ROLLBACK
--   DROP INDEX IF EXISTS public.osionos_sessions_parent_uniq;
--   DROP INDEX IF EXISTS public.osionos_sessions_refresh_hash_idx;
--   DROP INDEX IF EXISTS public.osionos_sessions_family_live_idx;
--   REVOKE ALL ON public.osionos_sessions FROM osionos_account_user;
--   GRANT SELECT (id, created_at, expires_at, last_seen_at, auth_method, ip_prefix, user_agent, revoked_at, revoked_reason)
--     ON public.osionos_sessions TO osionos_account_user;

BEGIN;

CREATE INDEX IF NOT EXISTS osionos_sessions_family_live_idx ON public.osionos_sessions (family_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS osionos_sessions_refresh_hash_idx ON public.osionos_sessions (refresh_hash) WHERE refresh_hash IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS osionos_sessions_parent_uniq ON public.osionos_sessions (parent_id) WHERE parent_id IS NOT NULL;

-- The REVOKE first, as in the foundation file: a leftover table-level grant survives
-- a replay, and only this line takes it back.
REVOKE ALL ON public.osionos_sessions FROM osionos_account_user;
GRANT SELECT (id, created_at, expires_at, last_seen_at, auth_method, ip_prefix, user_agent, revoked_at, revoked_reason, family_id)
  ON public.osionos_sessions TO osionos_account_user;

COMMIT;
