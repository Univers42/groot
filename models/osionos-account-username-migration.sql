-- osionos-account-username-migration.sql — one atomic username change, the
-- only path that writes a username.
--
-- WHY THIS FILE EXISTS
--   After P1-1 a username lives in two tables: the typed
--   osionos_profiles.username (held for 90 days by osionos_username_history)
--   and the legacy osionos_bridge_identities.username, which the chat mentions
--   (apps/osionos/app/scripts/bridge-chat.mjs:294) and the IDE sandbox user
--   (apps/osionos/app/scripts/ide-username.mjs:64) still read. The bridge
--   cannot write both atomically: PostgREST gives one statement per request,
--   and P1-1's legacy sync trigger copies identities -> profiles on any
--   UPDATE OF profile, username, directory_opt_out and never raises. A
--   half-done change (profile written, identity not) is undone by the next
--   legacy profile write.
--   This file adds the one function that writes both in a single transaction,
--   and takes the role's direct UPDATE on the column back, so that function
--   is the only path.
--
-- WHAT IT CREATES
--   public.osionos_account_change_username(text)  the atomic change; the one
--                                                   SECURITY DEFINER osionos_%
--                                                   function the account role
--                                                   may execute
--
-- WHO REACHES WHAT
--   osionos_account_user  EXECUTE on the function, and nothing else
--   service_role          everything (it owns the tables anyway)
--   anon, authenticated   nothing
--
-- WHY THE CALLER IS READ FROM THE CLAIMS AND NOT FROM osionos_account_uid()
--   The helper (models/osionos-account-foundation-migration.sql:145-154)
--   requires current_user = 'osionos_account_user'. Inside a SECURITY DEFINER
--   function current_user is the OWNER, so the helper would answer NULL for
--   every call and the function could never write a row. The claim
--   expression is therefore copied here verbatim, minus that one test, and
--   the EXECUTE grant takes the place of the current_user test: only the
--   account role may call this function at all.
--
-- WHY THE IDENTITIES ROW IS WRITTEN FIRST
--   A boot replay of P1-1's file holds SHARE ROW EXCLUSIVE on
--   osionos_bridge_identities for the whole file (:80) and later wants ACCESS
--   EXCLUSIVE on osionos_profiles (:246, and the DROP TRIGGER at :359). A
--   call that held a lock on the profiles table while it waited for the
--   identities table closes that cycle. So the identities UPDATE is the FIRST
--   statement that touches either table, and the profiles table is not read
--   before it. Measured against the real P1-1 file as the replay, 20 rounds
--   each: P1-1's three legs alone 0 deadlocks, a profile-first write 11, an
--   identities-first write after a FOR UPDATE on both rows 14 and 17, this
--   order 0 in 60 rounds.
--
-- WHY THE TRIGGER IS THE PROFILE'S WRITER
--   P1-1's legacy sync trigger fires on the identities UPDATE and copies the
--   name into the profile, so on the normal path THE TRIGGER writes the
--   profile, not this function. The trigger swallows its own errors
--   (EXCEPTION WHEN others -> WARNING), so a name that is held or already
--   taken is not refused there; the function's own UPDATE runs only when the
--   copy was refused, and then P1-1's hold guard and the unique index raise
--   23505 and the whole call rolls back, the identity row included.
--
-- public.users.username IS NOT TOUCHED
--   It is the gateway's registration-time copy: P1-1 reads it at
--   registration and in the backfill, and nothing writes it after that.
--
-- WHERE IT RUNS
--   scripts/apply-models-migrations.sh lists it in ORDERED_LAST, right after
--   osionos-account-profiles-migration.sql: it revokes a grant that file
--   makes, and it grants to the role that file creates.
--
-- Idempotent: a second run moves no grant and no function body.

BEGIN;

-- Fail fast, and say why: the REVOKE below takes back a grant another role
-- made, and only a superuser may revoke it.
DO $$
BEGIN
  IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
    RAISE EXCEPTION 'osionos-account-username-migration.sql must run as a superuser (REVOKE ... FROM osionos_account_user)';
  END IF;
END
$$;

-- Caveat: a busy table makes this file fail (the whole transaction rolls back)
-- instead of waiting; the next run retries it. 5 s is a budget, not a promise.
SET LOCAL lock_timeout = '5s';

-- The one function that writes a username.
-- SECURITY DEFINER: the account role may not write the legacy identity row,
-- and the profile's hold guard reads the history, which the role may not
-- select. The owner is the migration's superuser, so the function MAY write
-- any row; what confines it to the caller's own rows is the WHERE user_id =
-- v_uid clause on every statement it writes, not the ownership.
-- ON THE NORMAL PATH THE PROFILE IS WRITTEN BY P1-1's LEGACY SYNC TRIGGER,
-- not by this function: the trigger fires on the identities UPDATE below and
-- copies the name into the profile. The function's own UPDATE of the profile
-- runs only when that copy was refused.
-- The lock_timeout is the function's own: the migration's SET LOCAL above
-- covers only the migration transaction, and a call through PostgREST
-- inherits a session with none. Without the attribute a call blocked by a
-- boot replay would hold a pool connection for the replay's whole run.
-- Caveat: with it, such a call fails 55P03 after 3 s instead — the window is
-- the replay's duration (about 250 ms at 10K rows, seconds on a first boot).
--
-- THE BOUNDARY OF "THE ONLY PATH": the legacy PATCH /api/profile/me still
-- writes the identity row's username as the service role
-- (apps/osionos/app/scripts/bridge-profile.mjs:193,196), and the sync trigger
-- copies that into the profile without the sudo gate. The guarantee holds
-- once P1-2b's contract 7 refuses username on that route.
CREATE OR REPLACE FUNCTION public.osionos_account_change_username(p_username text) RETURNS text
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, public
  SET lock_timeout = '3s'
AS $$
DECLARE
  v_uid uuid;
  v_current text;
BEGIN
  -- The caller. The merged helper's claim expression
  -- (models/osionos-account-foundation-migration.sql:147-152), verbatim and
  -- without its current_user test: inside a SECURITY DEFINER function
  -- current_user is the owner, so that test would always be false. The
  -- EXECUTE grant is the boundary instead — only the account role may call
  -- this function, and it is the only role whose token carries these claims.
  -- The regex is applied BEFORE the cast, so a malformed sub is a refused
  -- caller (42501) and never a cast error (22P02); an array aud is refused
  -- with it, because a jsonb array has no 'aud' key to read.
  SELECT CASE
           WHEN c ->> 'role' = 'osionos_account_user'
            AND c ->> 'aud' = 'osionos-account'
            AND c ->> 'sub' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
           THEN (c ->> 'sub')::uuid
         END
    INTO v_uid
    FROM (SELECT NULLIF(current_setting('request.jwt.claims', true), '')::jsonb AS c) AS s;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'osionos_account_change_username: the token carries no account user'
      USING ERRCODE = '42501';
  END IF;

  -- Validation, before any table is touched: a name that is not usable is
  -- refused with 22023 and no lock is taken. The reserved list is an IMMUTABLE
  -- constant (models/osionos-account-profiles-migration.sql:110-115), so this
  -- reads no table.
  IF p_username IS NULL
     OR p_username !~ '^[A-Za-z0-9_][A-Za-z0-9_.-]{2,31}$'
     OR public.osionos_username_reserved(p_username) THEN
    RAISE EXCEPTION 'osionos_account_change_username: % is not a usable username',
      coalesce(p_username, '<null>')
      USING ERRCODE = '22023';
  END IF;

  -- Step 1: the identities UPDATE is the FIRST statement that touches either
  -- table (see the header: a lock on the profiles table held while this waits
  -- for the identities table closes a cycle with the replay's DROP TRIGGER).
  -- Zero rows means either that the caller has no identities row — there is
  -- then no legacy name to keep in step — or that the row already holds this
  -- name; either way the call goes on.
  -- The unique index (models/osionos-social-migration.sql:30) raises 23505 for
  -- a name another identity still holds from before P1-1; it is left to
  -- propagate.
  UPDATE public.osionos_bridge_identities
     SET username = p_username
   WHERE user_id = v_uid
     AND username IS DISTINCT FROM p_username;

  -- Step 2: P1-1's legacy sync trigger fires on that UPDATE and copies the
  -- name into the profile. ON THE NORMAL PATH THE TRIGGER IS WHAT WRITES THE
  -- PROFILE. It swallows its own errors, so a name that is held or already
  -- taken is not refused here.
  --
  -- Step 3: only now the profile is read, and locked for the rest of the
  -- call. No row means the caller has no profile: P0002 rolls step 1 back, so
  -- the caller sees a clean failure and not a half-done change.
  SELECT username INTO v_current
    FROM public.osionos_profiles
   WHERE user_id = v_uid
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'osionos_account_change_username: no profile for %', v_uid
      USING ERRCODE = 'P0002';
  END IF;

  -- Step 4: the profile holds the name, so the change is done — the trigger
  -- has just copied it (the normal path), or it was already the name (a
  -- same-name call). A same-name call whose identity row had drifted has
  -- just brought that row in step: the one write a same-name call may make.
  IF v_current = p_username THEN
    RETURN p_username;
  END IF;

  -- Step 5: the trigger's copy was refused (a held or an already taken name),
  -- so the profile is written here. P1-1's hold guard and the unique index on
  -- lower(username) raise 23505, and the whole call rolls back — the identity
  -- row included. That is the point: the two tables move together or not at
  -- all.
  UPDATE public.osionos_profiles
     SET username = p_username
   WHERE user_id = v_uid;
  RETURN p_username;
END
$$;

-- The EXECUTE grant is the boundary the helper's current_user test would have
-- been: only the account role may call this function.
REVOKE ALL ON FUNCTION public.osionos_account_change_username(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.osionos_account_change_username(text) TO osionos_account_user;

-- The role may no longer write the column itself: the function above is now
-- the only path that writes a username. P1-1 granted this column so that the
-- account route could change a name before the atomic path existed.
-- (The legacy route's boundary is stated in the function's own comment.)
REVOKE UPDATE (username) ON public.osionos_profiles FROM osionos_account_user;

COMMIT;

-- PostgREST caches the schema; a new function and a revoked grant are
-- invisible to it until it reloads.
NOTIFY pgrst, 'reload schema';

-- DOWN (manual). The grant comes back first, or the account route cannot
-- change a name at all:
--   GRANT UPDATE (username) ON public.osionos_profiles TO osionos_account_user;
--   DROP FUNCTION IF EXISTS public.osionos_account_change_username(text);
