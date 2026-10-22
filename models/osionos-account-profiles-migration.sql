-- osionos-account-profiles-migration.sql — the account plane's profile, settings,
-- username and deletion schema.
--
-- WHY THIS FILE EXISTS
--   A profile today is a jsonb blob on osionos_bridge_identities.profile, written
--   read-modify-write by the bridge (apps/osionos/app/scripts/bridge-profile.mjs:
--   120-134,182-206): two concurrent edits lose one. The people directory is a
--   view that recomputes to_tsvector() per row over a three-way join
--   (models/osionos-people-directory-migration.sql:45-63), so every search is a
--   sequential scan over three tables. Usernames have two homes — public.users.
--   username (the gateway's rule, apps/opposite-osiris/scripts/auth/identity.mjs:
--   11) and osionos_bridge_identities.username (the bridge accepts any 48
--   characters) — and no table holds settings, a username history or a deletion
--   request.
--
-- WHAT IT CREATES
--   public.osionos_profiles                    one row per user; the profile's own
--                                               columns, indexed for the directory search
--   public.osionos_user_settings               one row per (user, section), so two
--                                               sections never contend
--   public.osionos_username_history            the 90-day hold on a released name
--   public.osionos_account_deletion_requests   the 14-day grace
--   public.osionos_people_directory            the directory view, rebuilt over the
--                                               profiles (its old file is a tombstone)
--
-- WHO REACHES WHAT
--   service_role          everything (the bridge; P5-6's deletion executor).
--   osionos_account_user  only the columns this plane publishes, through column
--                         grants and row-level security.
--   anon, authenticated   nothing.
--
-- WHY THE BACKFILL IS TWO PASSES
--   One statement with ON CONFLICT (user_id) aborts the whole statement on a
--   single username collision — every boot, and nobody gets a profile. A bare
--   ON CONFLICT DO NOTHING skips the colliding row; pass 2 then inserts every
--   source user still without a profile, with username = NULL.
--
-- WHY THE BACKFILL NEVER OVERWRITES
--   The trigger on public.users creates a profile the moment a user registers,
--   and the legacy trigger on osionos_bridge_identities keeps it current. A
--   second backfill must not replace what a user (or the bridge) wrote, so the
--   backfill only ever inserts.
--
-- WHY THE USERNAME CHECK CALLS A FUNCTION
--   The reserved list has to grow without a table rewrite, and a CHECK may not
--   contain a subquery. The function is IMMUTABLE, so the planner may fold it,
--   and its EXECUTE is granted to the two roles that write profiles: a CHECK is
--   re-checked for EXECUTE at DML time, and without the grant the account
--   role's own UPDATE fails with "permission denied for function".
--
-- THE LOCK ORDER
--   Registration takes public.users and then (through the trigger)
--   osionos_profiles; sign-in takes osionos_bridge_identities and then
--   osionos_profiles. This file takes the same order — users, identities, then
--   the new tables — so a replay cannot deadlock a sign-in or a registration.
--
-- WHERE IT RUNS
--   scripts/apply-models-migrations.sh lists it in ORDERED_LAST, right after
--   osionos-account-foundation-migration.sql: the account role it grants to must
--   exist first, and the service-role-only pass that follows must not take back
--   what this file grants.
--
-- Idempotent: a second run moves no grant, policy, role attribute or index
-- (check g of scripts/verify/models-grants.sh).

BEGIN;

-- Caveat: a busy table makes this file fail (the whole transaction rolls back)
-- instead of waiting; the next run retries it. 5 s is a budget, not a promise.
SET LOCAL lock_timeout = '5s';

-- 1. The hot paths' tables first, in the order the hot paths take them.
-- The lock mode blocks writers (ROW EXCLUSIVE conflicts with SHARE ROW
-- EXCLUSIVE) for the length of this file, which is what keeps a replay from
-- interleaving with a registration or a sign-in.
-- Caveat: the reviewer measured the window this opens — a registration waits
-- for the whole file (about 250 ms at 10K rows), and a writer that holds a
-- lock for more than 5 s makes the replay abort on lock_timeout (55P03),
-- failing that boot until the next one.
LOCK TABLE public.users, public.osionos_bridge_identities IN SHARE ROW EXCLUSIVE MODE;

-- 2. The prerequisites, named so a missing one is not a mystery error.
-- The backfill reads public.users.username (added by
-- auth-gateway-users-reconcile-migration.sql:42) and the identity row's
-- profile and username (added by osionos-chat-migration.sql:10 and
-- osionos-social-migration.sql:18). The runner applies all three in
-- ORDERED_FIRST, before this file.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'username') THEN
    RAISE EXCEPTION 'public.users.username is missing — auth-gateway-users-reconcile-migration.sql must run first';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'osionos_bridge_identities' AND column_name = 'profile') THEN
    RAISE EXCEPTION 'osionos_bridge_identities.profile is missing — osionos-chat-migration.sql must run first';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'osionos_bridge_identities' AND column_name = 'username') THEN
    RAISE EXCEPTION 'osionos_bridge_identities.username is missing — osionos-social-migration.sql must run first';
  END IF;
END
$$;

-- 3. The functions the CHECK constraints call. They come before the tables:
-- a CHECK may not contain a subquery, and the reserved list has to grow
-- without a table rewrite.
-- The reserved names are the ones a caller would mistake for a route
-- (/admin, /login, /settings) or for the product itself.
CREATE OR REPLACE FUNCTION public.osionos_username_reserved(p_name text) RETURNS boolean
  LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, public AS $$
  SELECT p_name IS NOT NULL
     AND lower(p_name) = ANY (ARRAY['admin','administrator','api','app','auth','help',
                                    'login','logout','me','new','osionos','p','root',
                                    'settings','signup','support','system','u','www'])
$$;
REVOKE ALL ON FUNCTION public.osionos_username_reserved(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.osionos_username_reserved(text) TO osionos_account_user, service_role;

-- The ORCID check digit is ISO 7064 MOD 11-2: the data digits are weighted
-- 2^15..2^1 from the left, and the check is (12 - sum mod 11) mod 11, with 10
-- written X.
CREATE OR REPLACE FUNCTION public.osionos_orcid_valid(p_orcid text) RETURNS boolean
  LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, public AS $$
DECLARE
  v_digits text;
  v_sum integer := 0;
  v_check integer;
  v_char text;
  i integer;
BEGIN
  IF p_orcid IS NULL THEN
    RETURN false;
  END IF;
  IF p_orcid !~ '^\d{4}-\d{4}-\d{4}-\d{3}[\dX]$' THEN
    RETURN false;
  END IF;
  v_digits := replace(p_orcid, '-', '');
  FOR i IN 1..15 LOOP
    v_sum := v_sum + substring(v_digits, i, 1)::integer * (1 << (16 - i));
  END LOOP;
  v_check := (12 - (v_sum % 11)) % 11;
  IF v_check = 10 THEN
    v_char := 'X';
  ELSE
    v_char := v_check::text;
  END IF;
  RETURN upper(right(p_orcid, 1)) = v_char;
END
$$;
REVOKE ALL ON FUNCTION public.osionos_orcid_valid(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.osionos_orcid_valid(text) TO osionos_account_user, service_role;

-- An array of links needs a subquery to be checked element by element, and a
-- CHECK may not contain one: at most four entries, each an https URL.
CREATE OR REPLACE FUNCTION public.osionos_links_valid(p_links text[]) RETURNS boolean
  LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, public AS $$
  SELECT p_links IS NULL
      OR (cardinality(p_links) <= 4
          AND NOT EXISTS (SELECT 1 FROM unnest(p_links) AS l
                          WHERE l IS NULL OR l !~ '^https://\S{1,250}$'))
$$;
REVOKE ALL ON FUNCTION public.osionos_links_valid(text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.osionos_links_valid(text[]) TO osionos_account_user, service_role;

-- 4. The account-plane tables.
-- The FK on auth.users is what makes a profile impossible without a GoTrue
-- row: a public.users row with no auth.users row gets no profile, and the
-- backfill says so in a NOTICE instead of failing.
-- Caveat: the trigram opclass is qualified with the schema the pg_trgm
-- extension actually landed in (models/osionos-social-migration.sql:11 creates
-- it without a SCHEMA clause, so the schema follows the session's search_path
-- and is NOT always public).
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE IF NOT EXISTS public.osionos_profiles (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name TEXT NOT NULL
    CHECK (char_length(display_name) BETWEEN 1 AND 100)
    CHECK (display_name !~ '[[:cntrl:]]'),
  -- The gateway's rule, verbatim (apps/opposite-osiris/scripts/auth/identity.mjs:11).
  username TEXT
    CHECK (username IS NULL OR username ~ '^[A-Za-z0-9_][A-Za-z0-9_.-]{2,31}$')
    CHECK (username IS NULL OR NOT public.osionos_username_reserved(username)),
  pronouns TEXT CHECK (pronouns IS NULL OR (char_length(pronouns) <= 40 AND pronouns !~ '[[:cntrl:]]')),
  headline TEXT CHECK (headline IS NULL OR (char_length(headline) <= 200 AND headline !~ '[[:cntrl:]]')),
  -- The bio is the one field that may hold a newline.
  bio TEXT CHECK (bio IS NULL OR (char_length(bio) <= 2000 AND bio !~ '[\x00-\x09\x0B-\x1F\x7F]')),
  location TEXT CHECK (location IS NULL OR (char_length(location) <= 120 AND location !~ '[[:cntrl:]]')),
  company TEXT CHECK (company IS NULL OR (char_length(company) <= 100 AND company !~ '[[:cntrl:]]')),
  website TEXT CHECK (website IS NULL OR website ~ '^https?://\S{1,250}$'),
  links TEXT[] CHECK (links IS NULL OR public.osionos_links_valid(links)),
  -- Real-zone validity is the bridge's job; the shape is the database's.
  timezone TEXT CHECK (timezone IS NULL OR (char_length(timezone) <= 64 AND timezone ~ '^[A-Za-z]+(/[A-Za-z0-9_+-]+){0,2}$')),
  orcid TEXT CHECK (orcid IS NULL OR public.osionos_orcid_valid(orcid)),
  patreon TEXT CHECK (patreon IS NULL OR patreon ~ '^[A-Za-z0-9_-]{1,64}$'),
  -- The avatar columns stay NULL until P0-6 moves avatars into storage; the
  -- directory view keeps the legacy fallback meanwhile.
  avatar_url TEXT CHECK (avatar_url IS NULL OR (char_length(avatar_url) <= 512 AND avatar_url ~ '^(https://|/)')),
  banner_url TEXT CHECK (banner_url IS NULL OR (char_length(banner_url) <= 512 AND banner_url ~ '^(https://|/)')),
  directory_opt_out BOOLEAN NOT NULL DEFAULT false,
  version INTEGER NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- concat_ws is STABLE and a generated column refuses it; the || form is
  -- IMMUTABLE and folds into the index.
  search_doc tsvector GENERATED ALWAYS AS (
    to_tsvector('simple'::regconfig,
      coalesce(display_name,'') || ' ' || coalesce(username,'') || ' ' ||
      coalesce(headline,'') || ' ' || coalesce(bio,''))
  ) STORED
);

CREATE TABLE IF NOT EXISTS public.osionos_user_settings (
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  section TEXT NOT NULL CHECK (section ~ '^[a-z][a-z0-9_-]{0,31}$'),
  value JSONB NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(value) = 'object' AND pg_column_size(value) <= 16384),
  version INTEGER NOT NULL DEFAULT 1,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, section)
);

CREATE TABLE IF NOT EXISTS public.osionos_username_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- A deleted user's names stay held: the row outlives the user.
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  username TEXT NOT NULL,
  changed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  released_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '90 days')
);

CREATE TABLE IF NOT EXISTS public.osionos_account_deletion_requests (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  requested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  scheduled_for TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '14 days'),
  successor_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  -- The client may push the date later, never earlier: the grace is the floor.
  CHECK (scheduled_for >= requested_at + interval '14 days'),
  CHECK (successor_user_id IS DISTINCT FROM user_id)
);

-- The new tables are now in the hot path (the registration trigger writes
-- osionos_profiles), so they take the same lock the file already holds on the
-- two legacy tables. On the first run the CREATE above already holds it.
LOCK TABLE public.osionos_profiles, public.osionos_user_settings,
             public.osionos_username_history, public.osionos_account_deletion_requests
  IN SHARE ROW EXCLUSIVE MODE;

-- 5. The indexes. Every one is NAMED and IF NOT EXISTS: an unnamed CREATE
-- INDEX makes a duplicate on every boot.
-- The unique index is on lower(username), so two names that differ only in
-- case are one name.
CREATE UNIQUE INDEX IF NOT EXISTS osionos_profiles_username_lower_uidx
  ON public.osionos_profiles (lower(username));
-- The no-query listing: ORDER BY display_name LIMIT n walks this index and
-- stops after n rows.
CREATE INDEX IF NOT EXISTS osionos_profiles_display_name_user_idx
  ON public.osionos_profiles (display_name, user_id);
CREATE INDEX IF NOT EXISTS osionos_profiles_search_doc_idx
  ON public.osionos_profiles USING gin (search_doc) WITH (fastupdate = off);
-- The GIN indexes are built with the fast update technique OFF. A GIN index
-- that keeps a pending list holds its newest rows outside the index proper,
-- and the planner's cost model and the index's statistics then describe an
-- index that is not the one the query will walk: the directory search falls
-- back to a sequential scan of the profiles. The profiles are written a few
-- times per user, so the batching the pending list buys is worth nothing here.
DO $$
DECLARE
  v_schema text;
BEGIN
  SELECT n.nspname INTO v_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
   WHERE e.extname = 'pg_trgm';
  IF v_schema IS NULL THEN
    RAISE EXCEPTION 'pg_trgm is required for the osionos profile search indexes';
  END IF;
  EXECUTE format('CREATE INDEX IF NOT EXISTS osionos_profiles_display_name_trgm_idx ON public.osionos_profiles USING gin (display_name %I.gin_trgm_ops) WITH (fastupdate = off)', v_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS osionos_profiles_username_trgm_idx ON public.osionos_profiles USING gin (username %I.gin_trgm_ops) WITH (fastupdate = off)', v_schema);
  EXECUTE format('CREATE INDEX IF NOT EXISTS osionos_profiles_headline_trgm_idx ON public.osionos_profiles USING gin (headline %I.gin_trgm_ops) WITH (fastupdate = off)', v_schema);
END
$$;
-- The option above only applies to an index this file creates. An install that
-- already has one (a database that ran the file before the option existed)
-- still needs it, and only that install does: the ALTER takes a lock, and a
-- boot that takes it every time blocks the writers it is meant to protect.
DO $$
DECLARE
  v_idx text;
BEGIN
  FOREACH v_idx IN ARRAY ARRAY['osionos_profiles_search_doc_idx',
                               'osionos_profiles_display_name_trgm_idx',
                               'osionos_profiles_username_trgm_idx',
                               'osionos_profiles_headline_trgm_idx'] LOOP
    IF EXISTS (SELECT 1 FROM pg_class c
                WHERE c.relname = v_idx AND c.relnamespace = 'public'::regnamespace
                  AND NOT (coalesce(c.reloptions, '{}'::text[]) @> ARRAY['fastupdate=off'])) THEN
      EXECUTE format('ALTER INDEX public.%I SET (fastupdate = off)', v_idx);
    END IF;
  END LOOP;
END
$$;
CREATE INDEX IF NOT EXISTS osionos_username_history_name_released_idx
  ON public.osionos_username_history (lower(username), released_at);

-- 6. The merge function.
-- The merge is SECURITY INVOKER on purpose: the row it writes is the caller's
-- own row, and the uid helper — not the function — decides who the caller is.
-- A shallow merge in one statement, so two concurrent PATCHes to one section
-- both land; a null in the patch deletes the key.
CREATE OR REPLACE FUNCTION public.osionos_user_settings_merge(p_section text, p_patch jsonb)
  RETURNS jsonb
  LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public AS $$
DECLARE
  v_uid uuid;
  v_value jsonb;
BEGIN
  v_uid := public.osionos_account_uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'osionos_user_settings_merge: the token carries no account user'
      USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.osionos_user_settings (user_id, section, value)
  VALUES (v_uid, p_section, coalesce(p_patch, '{}'::jsonb))
  ON CONFLICT (user_id, section) DO UPDATE
    SET value = jsonb_strip_nulls(public.osionos_user_settings.value || EXCLUDED.value),
        version = public.osionos_user_settings.version + 1,
        updated_at = now()
  RETURNING value INTO v_value;
  RETURN v_value;
END
$$;
REVOKE ALL ON FUNCTION public.osionos_user_settings_merge(text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.osionos_user_settings_merge(text, jsonb) TO osionos_account_user, service_role;

-- 7. The triggers.
-- Every UPDATE bumps the version: the bridge's If-Match is
-- PATCH ...&version=eq.N, and zero rows updated is a 412.
-- An UPDATE that changes nothing does not: the row is rewritten either way, and
-- a version that moves on a no-op makes the next If-Match fail for nothing.
CREATE OR REPLACE FUNCTION public.osionos_profiles_touch() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  -- The comparison is made before the bump, so NEW.version still holds
  -- OLD.version unless a caller set it (a caller that sets a version has
  -- changed the row, and the bump below then overwrites it with OLD + 1).
  -- The generated column is left out of the comparison: a BEFORE trigger runs
  -- before the generated value is computed, so the new row never holds it yet
  -- and the two rows would never compare equal.
  IF to_jsonb(NEW) - 'search_doc' IS NOT DISTINCT FROM to_jsonb(OLD) - 'search_doc' THEN
    RETURN NEW;
  END IF;
  NEW.version := OLD.version + 1;
  NEW.updated_at := now();
  RETURN NEW;
END
$$;
REVOKE ALL ON FUNCTION public.osionos_profiles_touch() FROM PUBLIC;
DROP TRIGGER IF EXISTS osionos_profiles_touch ON public.osionos_profiles;
CREATE TRIGGER osionos_profiles_touch BEFORE UPDATE ON public.osionos_profiles
  FOR EACH ROW EXECUTE FUNCTION public.osionos_profiles_touch();

-- The hold: a name released less than 90 days ago belongs to the user who
-- released it, and to nobody else. The owner may reclaim their own name.
-- SECURITY DEFINER: the guard reads the history's user_id, which the account
-- role may not select — the hold is the server's decision, not the user's.
-- Caveat: the hold is 90 calendar days, not 2160 hours: a daylight-saving
-- change in the session timezone moves the release by an hour.
CREATE OR REPLACE FUNCTION public.osionos_username_hold_guard() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_until timestamptz;
BEGIN
  IF NEW.username IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT max(h.released_at) INTO v_until
    FROM public.osionos_username_history h
   WHERE lower(h.username) = lower(NEW.username)
     AND h.released_at > now()
     AND h.user_id IS DISTINCT FROM NEW.user_id;
  IF v_until IS NOT NULL THEN
    RAISE EXCEPTION 'username % is held until %', NEW.username, v_until
      USING ERRCODE = '23505';
  END IF;
  RETURN NEW;
END
$$;
REVOKE ALL ON FUNCTION public.osionos_username_hold_guard() FROM PUBLIC;
DROP TRIGGER IF EXISTS osionos_profiles_username_hold ON public.osionos_profiles;
CREATE TRIGGER osionos_profiles_username_hold BEFORE INSERT OR UPDATE OF username
  ON public.osionos_profiles
  FOR EACH ROW EXECUTE FUNCTION public.osionos_username_hold_guard();

-- The history is written AFTER the change, so it records the name that was
-- released, not the one that was taken.
-- SECURITY DEFINER: the account role may read the history's own rows but may
-- not write them — the history is the server's record of a name it gave up.
CREATE OR REPLACE FUNCTION public.osionos_username_history_capture() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_now timestamptz;
BEGIN
  IF OLD.username IS NULL OR NEW.username IS NOT DISTINCT FROM OLD.username THEN
    RETURN NEW;
  END IF;
  v_now := now();
  INSERT INTO public.osionos_username_history (user_id, username, changed_at, released_at)
  VALUES (OLD.user_id, OLD.username, v_now, v_now + interval '90 days');
  RETURN NEW;
END
$$;
REVOKE ALL ON FUNCTION public.osionos_username_history_capture() FROM PUBLIC;
DROP TRIGGER IF EXISTS osionos_profiles_username_history ON public.osionos_profiles;
CREATE TRIGGER osionos_profiles_username_history AFTER UPDATE OF username
  ON public.osionos_profiles
  FOR EACH ROW EXECUTE FUNCTION public.osionos_username_history_capture();

-- A new user gets a profile the moment the row lands in public.users.
-- SECURITY DEFINER: the inserter is GoTrue's handle_new_user or the gateway,
-- and neither is granted on osionos_profiles.
-- The trigger never raises: a registration must not fail, and the next boot's
-- backfill heals the gap.
CREATE OR REPLACE FUNCTION public.osionos_profile_on_user_insert() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_display_name text;
BEGIN
  BEGIN
    -- No auth.users row means the profile's FK cannot be satisfied.
    IF NOT EXISTS (SELECT 1 FROM auth.users a WHERE a.id = NEW.id) THEN
      RAISE WARNING 'osionos: no auth.users row for % — no profile created', NEW.id;
      RETURN NEW;
    END IF;
    v_display_name := left(coalesce(nullif(btrim(regexp_replace(coalesce(
        (SELECT nullif(btrim(up.display_name), '') FROM public.user_profiles up WHERE up.user_id = NEW.id),
        (SELECT nullif(btrim(bi.display_name), '') FROM public.osionos_bridge_identities bi WHERE bi.user_id = NEW.id),
        nullif(btrim(NEW.name), ''),
        nullif(btrim(NEW.username), ''),
        'Member'), '[[:cntrl:]]', '', 'g')), ''), 'Member'), 100);
    BEGIN
      INSERT INTO public.osionos_profiles (user_id, display_name, username)
      VALUES (NEW.id, v_display_name, NEW.username)
      ON CONFLICT (user_id) DO NOTHING;
    EXCEPTION WHEN others THEN
      -- A name that is invalid or already taken must not cost the user their
      -- profile: the profile lands without one.
      INSERT INTO public.osionos_profiles (user_id, display_name)
      VALUES (NEW.id, v_display_name)
      ON CONFLICT (user_id) DO NOTHING;
    END;
  EXCEPTION WHEN others THEN
    RAISE WARNING 'osionos: no profile for user %: %', NEW.id, SQLERRM;
  END;
  RETURN NEW;
END
$$;
REVOKE ALL ON FUNCTION public.osionos_profile_on_user_insert() FROM PUBLIC;
DROP TRIGGER IF EXISTS osionos_profiles_on_user_insert ON public.users;
CREATE TRIGGER osionos_profiles_on_user_insert AFTER INSERT ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.osionos_profile_on_user_insert();

-- The legacy path: until P1-2 switches the readers, the bridge still writes
-- the profile blob on the identity row. This copies what it wrote into the
-- profile's own columns.
-- It never touches display_name (the identities row rewrites it at sign-in)
-- and never raises: an invalid value keeps the old one, with a warning.
--
-- IT COPIES ONLY WHAT CHANGED. The identities row is written by the bridge on
-- every sign-in and by the legacy path whenever one field moves; a copy of
-- everything would overwrite a value the user typed through the new account
-- route with an older value from the blob. So on an UPDATE only the fields
-- whose source moved are copied; on an INSERT everything is, because there is
-- nothing to compare against.
CREATE OR REPLACE FUNCTION public.osionos_profile_from_identity() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
  v_headline text;
  v_bio text;
  v_location text;
  v_username text;
  v_profile_changed boolean;
  v_optout_changed boolean;
  v_username_changed boolean;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_profile_changed := true;
    v_optout_changed := true;
    v_username_changed := true;
  ELSE
    v_profile_changed := NEW.profile IS DISTINCT FROM OLD.profile;
    v_optout_changed := NEW.directory_opt_out IS DISTINCT FROM OLD.directory_opt_out;
    v_username_changed := NEW.username IS DISTINCT FROM OLD.username;
  END IF;
  IF v_profile_changed THEN
    BEGIN
      v_headline := nullif(btrim(coalesce(NEW.profile->>'headline', '')), '');
      IF v_headline IS NOT NULL AND (char_length(v_headline) > 200 OR v_headline ~ '[[:cntrl:]]') THEN
        RAISE WARNING 'osionos: headline for % is invalid — the old one is kept', NEW.user_id;
        v_headline := NULL;
      END IF;
      v_bio := nullif(coalesce(NEW.profile->>'bio', ''), '');
      IF v_bio IS NOT NULL AND (char_length(v_bio) > 2000 OR v_bio ~ '[\x00-\x09\x0B-\x1F\x7F]') THEN
        RAISE WARNING 'osionos: bio for % is invalid — the old one is kept', NEW.user_id;
        v_bio := NULL;
      END IF;
      v_location := nullif(btrim(coalesce(NEW.profile->>'location', '')), '');
      IF v_location IS NOT NULL AND (char_length(v_location) > 120 OR v_location ~ '[[:cntrl:]]') THEN
        RAISE WARNING 'osionos: location for % is invalid — the old one is kept', NEW.user_id;
        v_location := NULL;
      END IF;
      -- The row is left alone when the copy would not change it: an UPDATE
      -- that rewrites a row with the values it already holds still bumps the
      -- profile's version.
      UPDATE public.osionos_profiles
         SET headline = coalesce(v_headline, headline),
             bio = coalesce(v_bio, bio),
             location = coalesce(v_location, location)
       WHERE user_id = NEW.user_id
         AND (coalesce(v_headline, headline) IS DISTINCT FROM headline
              OR coalesce(v_bio, bio) IS DISTINCT FROM bio
              OR coalesce(v_location, location) IS DISTINCT FROM location);
    EXCEPTION WHEN others THEN
      RAISE WARNING 'osionos: profile sync for % failed: %', NEW.user_id, SQLERRM;
    END;
  END IF;
  IF v_optout_changed THEN
    BEGIN
      UPDATE public.osionos_profiles
         SET directory_opt_out = coalesce(NEW.directory_opt_out, directory_opt_out)
       WHERE user_id = NEW.user_id
         AND coalesce(NEW.directory_opt_out, directory_opt_out) IS DISTINCT FROM directory_opt_out;
    EXCEPTION WHEN others THEN
      RAISE WARNING 'osionos: opt-out sync for % failed: %', NEW.user_id, SQLERRM;
    END;
  END IF;
  IF v_username_changed THEN
    BEGIN
      v_username := NEW.username;
      IF v_username IS NOT NULL
         AND (v_username !~ '^[A-Za-z0-9_][A-Za-z0-9_.-]{2,31}$' OR public.osionos_username_reserved(v_username)) THEN
        RAISE WARNING 'osionos: username % is not usable — the old one is kept', v_username;
        v_username := NULL;
      END IF;
      IF v_username IS NOT NULL THEN
        UPDATE public.osionos_profiles SET username = v_username
         WHERE user_id = NEW.user_id AND username IS DISTINCT FROM v_username;
      END IF;
    EXCEPTION WHEN others THEN
      RAISE WARNING 'osionos: username % could not be taken: %', NEW.username, SQLERRM;
    END;
  END IF;
  RETURN NEW;
END
$$;
REVOKE ALL ON FUNCTION public.osionos_profile_from_identity() FROM PUBLIC;
DROP TRIGGER IF EXISTS osionos_profiles_from_identity ON public.osionos_bridge_identities;
CREATE TRIGGER osionos_profiles_from_identity
  AFTER INSERT OR UPDATE OF profile, username, directory_opt_out
  ON public.osionos_bridge_identities
  FOR EACH ROW EXECUTE FUNCTION public.osionos_profile_from_identity();

-- 8. Row-level security, grants and the account-plane marker.
-- grobase's CREATE TABLE hook (apps/grobase/scripts/migrations/postgresql/012_realtime_triggers_all_tables.sql:64)
-- broadcasts every row of every new public table; a profile row is a person's
-- public face, but the realtime socket has no grant check. The trigger is
-- dropped here, not only by realtime-cdc-off, because this file may run
-- without that pass.
DROP TRIGGER IF EXISTS osionos_profiles_realtime_trigger ON public.osionos_profiles;
DROP TRIGGER IF EXISTS osionos_user_settings_realtime_trigger ON public.osionos_user_settings;
DROP TRIGGER IF EXISTS osionos_username_history_realtime_trigger ON public.osionos_username_history;
DROP TRIGGER IF EXISTS osionos_account_deletion_requests_realtime_trigger ON public.osionos_account_deletion_requests;

ALTER TABLE public.osionos_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_user_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_username_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.osionos_account_deletion_requests ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.osionos_profiles FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.osionos_user_settings FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.osionos_username_history FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.osionos_account_deletion_requests FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.osionos_profiles TO service_role;
GRANT ALL ON public.osionos_user_settings TO service_role;
GRANT ALL ON public.osionos_username_history TO service_role;
GRANT ALL ON public.osionos_account_deletion_requests TO service_role;

-- The account role. Column grants, not a table grant: the role can never
-- select=* (PostgREST answers 42501), so a caller names the columns it wants.
-- The REVOKE first: a table-level grant left over from an earlier run (or from
-- a hand-made grant) survives a replay, and only this line takes it back.
REVOKE ALL ON public.osionos_profiles FROM osionos_account_user;
GRANT SELECT (user_id, display_name, username, pronouns, headline, bio, location,
              company, website, links, timezone, orcid, patreon, avatar_url,
              banner_url, directory_opt_out, version, created_at, updated_at, search_doc)
  ON public.osionos_profiles TO osionos_account_user;
-- The avatar and banner columns stay out of reach: P0-6 owns them, and a user
-- must not repoint their own avatar. The version and the timestamps are the
-- server's.
GRANT UPDATE (display_name, username, pronouns, headline, bio, location, company,
               website, links, timezone, orcid, patreon, directory_opt_out)
  ON public.osionos_profiles TO osionos_account_user;
DROP POLICY IF EXISTS osionos_profiles_service_role_all ON public.osionos_profiles;
CREATE POLICY osionos_profiles_service_role_all ON public.osionos_profiles FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS osionos_profiles_owner_read ON public.osionos_profiles;
-- (SELECT public.osionos_account_uid()) is deliberate: wrapped, it is evaluated
-- once per query (an InitPlan); bare, it would be evaluated once per row.
CREATE POLICY osionos_profiles_owner_read ON public.osionos_profiles FOR SELECT TO osionos_account_user
  USING (user_id = (SELECT public.osionos_account_uid()));
DROP POLICY IF EXISTS osionos_profiles_owner_update ON public.osionos_profiles;
CREATE POLICY osionos_profiles_owner_update ON public.osionos_profiles FOR UPDATE TO osionos_account_user
  USING (user_id = (SELECT public.osionos_account_uid()))
  WITH CHECK (user_id = (SELECT public.osionos_account_uid()));
COMMENT ON TABLE public.osionos_profiles IS 'osionos:account-plane';

REVOKE ALL ON public.osionos_user_settings FROM osionos_account_user;
GRANT SELECT (user_id, section, value, version, updated_at) ON public.osionos_user_settings TO osionos_account_user;
GRANT INSERT (user_id, section, value) ON public.osionos_user_settings TO osionos_account_user;
-- The UPDATE grant covers the merge's DO UPDATE: ON CONFLICT reads the
-- arbiter columns and writes version and updated_at, and without these the
-- merge fails with "permission denied".
GRANT UPDATE (user_id, section, value, version, updated_at) ON public.osionos_user_settings TO osionos_account_user;
DROP POLICY IF EXISTS osionos_user_settings_service_role_all ON public.osionos_user_settings;
CREATE POLICY osionos_user_settings_service_role_all ON public.osionos_user_settings FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS osionos_user_settings_owner_all ON public.osionos_user_settings;
CREATE POLICY osionos_user_settings_owner_all ON public.osionos_user_settings FOR ALL TO osionos_account_user
  USING (user_id = (SELECT public.osionos_account_uid()))
  WITH CHECK (user_id = (SELECT public.osionos_account_uid()));
COMMENT ON TABLE public.osionos_user_settings IS 'osionos:account-plane';

REVOKE ALL ON public.osionos_username_history FROM osionos_account_user;
GRANT SELECT (username, changed_at, released_at) ON public.osionos_username_history TO osionos_account_user;
DROP POLICY IF EXISTS osionos_username_history_service_role_all ON public.osionos_username_history;
CREATE POLICY osionos_username_history_service_role_all ON public.osionos_username_history FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS osionos_username_history_owner_read ON public.osionos_username_history;
CREATE POLICY osionos_username_history_owner_read ON public.osionos_username_history FOR SELECT TO osionos_account_user
  USING (user_id = (SELECT public.osionos_account_uid()));
COMMENT ON TABLE public.osionos_username_history IS 'osionos:account-plane';

REVOKE ALL ON public.osionos_account_deletion_requests FROM osionos_account_user;
GRANT SELECT (user_id, requested_at, scheduled_for, successor_user_id) ON public.osionos_account_deletion_requests TO osionos_account_user;
GRANT INSERT (user_id, successor_user_id) ON public.osionos_account_deletion_requests TO osionos_account_user;
-- Cancelling a deletion is a DELETE: the audit table records it.
GRANT DELETE ON public.osionos_account_deletion_requests TO osionos_account_user;
DROP POLICY IF EXISTS osionos_account_deletion_requests_service_role_all ON public.osionos_account_deletion_requests;
CREATE POLICY osionos_account_deletion_requests_service_role_all ON public.osionos_account_deletion_requests FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS osionos_account_deletion_requests_owner_all ON public.osionos_account_deletion_requests;
CREATE POLICY osionos_account_deletion_requests_owner_all ON public.osionos_account_deletion_requests FOR ALL TO osionos_account_user
  USING (user_id = (SELECT public.osionos_account_uid()))
  WITH CHECK (user_id = (SELECT public.osionos_account_uid()));
COMMENT ON TABLE public.osionos_account_deletion_requests IS 'osionos:account-plane';

-- 9. The directory view, rebuilt over the profiles.
-- The columns keep the old order (the old bridge image selects them by name)
-- and headline is added at the end. display_name, username, search_doc and
-- headline are the profile's own columns — no COALESCE — so the indexes apply.
DROP VIEW IF EXISTS public.osionos_people_directory;
-- The user_profiles join is a LATERAL, not a plain LEFT JOIN: a plain one lets
-- the planner hash-join the whole legacy table (a sequential scan of every
-- user_profiles row) instead of looking the one row up by its unique index,
-- and the directory lookup is the one query that must not scan a legacy table.
-- Caveat: the LATERAL keeps one avatar per profile even if user_profiles held
-- two rows for the same user; the plain join would have doubled the row.
CREATE VIEW public.osionos_people_directory WITH (security_invoker = true) AS
SELECT
  p.user_id,
  p.display_name,
  p.username,
  jsonb_build_object(
    'avatar', COALESCE(p.avatar_url, up.avatar_url, bi.profile->>'avatar'),
    'headline', COALESCE(p.headline, '')
  ) AS profile,
  bi.last_seen_at,
  p.directory_opt_out,
  p.search_doc,
  p.headline
FROM public.osionos_profiles p
LEFT JOIN LATERAL (
  SELECT up.avatar_url FROM public.user_profiles up
   WHERE up.user_id = p.user_id LIMIT 1
) up ON true
LEFT JOIN public.osionos_bridge_identities bi ON bi.user_id = p.user_id;

-- The legacy default privilege hands anon and authenticated SELECT on a new
-- view (legacy-default.sql:2), so the view is revoked before it is granted.
REVOKE ALL ON public.osionos_people_directory FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.osionos_people_directory TO service_role;

-- 10. The backfill: every user in the directory, on every boot.
-- The source set is (public.users.id UNION osionos_bridge_identities.user_id)
-- INTERSECT auth.users.id — a profile's FK needs a GoTrue row, so a
-- public.users row without one gets no profile, and the NOTICE below says how
-- many were left out.
CREATE TEMP TABLE p1_backfill ON COMMIT DROP AS
WITH source AS (
  SELECT u.id AS user_id,
         coalesce(u.created_at, u.updated_at, '-infinity'::timestamptz) AS created_at,
         u.username AS u_username,
         u.name AS u_name,
         (SELECT up.display_name FROM public.user_profiles up
           WHERE up.user_id = u.id ORDER BY up.id LIMIT 1) AS up_display_name,
         bi.username AS bi_username,
         bi.display_name AS bi_display_name,
         bi.profile AS bi_profile,
         bi.directory_opt_out AS bi_opt_out
    FROM public.users u
    LEFT JOIN public.osionos_bridge_identities bi ON bi.user_id = u.id
   WHERE EXISTS (SELECT 1 FROM auth.users a WHERE a.id = u.id)
  UNION ALL
  SELECT bi.user_id,
         coalesce(bi.created_at, '-infinity'::timestamptz),
         NULL, NULL, NULL, bi.username, bi.display_name, bi.profile, bi.directory_opt_out
    FROM public.osionos_bridge_identities bi
   WHERE bi.user_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.users u WHERE u.id = bi.user_id)
     AND EXISTS (SELECT 1 FROM auth.users a WHERE a.id = bi.user_id)
),
named AS (
  SELECT s.*,
         left(coalesce(nullif(btrim(regexp_replace(coalesce(
             nullif(btrim(s.up_display_name), ''),
             nullif(btrim(s.bi_display_name), ''),
             nullif(btrim(s.u_name), ''),
             nullif(btrim(s.u_username), ''),
             'Member'), '[[:cntrl:]]', '', 'g')), ''), 'Member'), 100) AS display_name,
         CASE WHEN s.bi_profile->>'headline' IS NOT NULL
                   AND char_length(s.bi_profile->>'headline') <= 200
                   AND s.bi_profile->>'headline' !~ '[[:cntrl:]]'
              THEN s.bi_profile->>'headline' END AS headline,
         CASE WHEN s.bi_profile->>'bio' IS NOT NULL
                   AND char_length(s.bi_profile->>'bio') <= 2000
                   AND s.bi_profile->>'bio' !~ '[\x00-\x09\x0B-\x1F\x7F]'
              THEN s.bi_profile->>'bio' END AS bio,
         CASE WHEN s.bi_profile->>'location' IS NOT NULL
                   AND char_length(s.bi_profile->>'location') <= 120
                   AND s.bi_profile->>'location' !~ '[[:cntrl:]]'
              THEN s.bi_profile->>'location' END AS location,
         coalesce(s.bi_opt_out, false) AS directory_opt_out
    FROM source s
),
candidates AS (
  SELECT n.user_id, n.created_at, 0 AS cand_rank, n.u_username AS username
    FROM named n WHERE n.u_username IS NOT NULL
  UNION ALL
  SELECT n.user_id, n.created_at, 1, n.bi_username
    FROM named n WHERE n.bi_username IS NOT NULL
),
scored AS (
  SELECT c.*,
         CASE
           WHEN c.username !~ '^[A-Za-z0-9_][A-Za-z0-9_.-]{2,31}$' THEN 'format'
           WHEN public.osionos_username_reserved(c.username) THEN 'reserved'
           WHEN EXISTS (SELECT 1 FROM public.osionos_username_history h
                        WHERE lower(h.username) = lower(c.username)
                          AND h.released_at > now()
                          AND h.user_id IS DISTINCT FROM c.user_id) THEN 'held'
           WHEN EXISTS (SELECT 1 FROM public.osionos_profiles p
                        WHERE lower(p.username) = lower(c.username)
                          AND p.user_id IS DISTINCT FROM c.user_id) THEN 'taken'
           ELSE 'ok'
         END AS reason
    FROM candidates c
),
ranked AS (
  SELECT e.*,
         row_number() OVER (PARTITION BY lower(e.username)
                            ORDER BY e.cand_rank, e.created_at NULLS FIRST, e.user_id) AS rn
    FROM scored e WHERE e.reason = 'ok'
),
won AS (
  SELECT r.user_id, r.username, r.cand_rank, r.created_at
    FROM ranked r WHERE r.rn = 1
),
picked AS (
  SELECT user_id, username FROM (
    SELECT w.*, row_number() OVER (PARTITION BY w.user_id
                                   ORDER BY w.cand_rank, w.created_at NULLS FIRST, w.username) AS pick
      FROM won w
  ) z WHERE z.pick = 1
),
drops AS (
  SELECT user_id,
         count(*) FILTER (WHERE reason = 'format')   AS dropped_format,
         count(*) FILTER (WHERE reason = 'reserved') AS dropped_reserved,
         count(*) FILTER (WHERE reason = 'held')     AS dropped_held,
         count(*) FILTER (WHERE reason = 'taken')    AS dropped_taken
    FROM scored GROUP BY user_id
)
SELECT n.user_id, n.display_name, p.username, n.headline, n.bio, n.location,
       n.directory_opt_out,
       coalesce(d.dropped_format, 0)   AS dropped_format,
       coalesce(d.dropped_reserved, 0) AS dropped_reserved,
       coalesce(d.dropped_held, 0)     AS dropped_held,
       coalesce(d.dropped_taken, 0)    AS dropped_taken
  FROM named n
  LEFT JOIN picked p ON p.user_id = n.user_id
  LEFT JOIN drops d ON d.user_id = n.user_id;

DO $$
DECLARE
  v_format bigint;
  v_reserved bigint;
  v_held bigint;
  v_taken bigint;
  v_named bigint;
  v_nameless bigint;
  v_noauth_users bigint;
  v_noauth_identities bigint;
  v_pass1 bigint;
  v_pass2 bigint;
BEGIN
  SELECT coalesce(sum(dropped_format), 0), coalesce(sum(dropped_reserved), 0),
         coalesce(sum(dropped_held), 0), coalesce(sum(dropped_taken), 0)
    INTO v_format, v_reserved, v_held, v_taken
    FROM pg_temp.p1_backfill;
  -- The counts, never the names: a name in a NOTICE is a name in a log.
  RAISE NOTICE 'osionos backfill: username candidates dropped (invalid format): %', v_format;
  RAISE NOTICE 'osionos backfill: username candidates dropped (reserved name): %', v_reserved;
  RAISE NOTICE 'osionos backfill: username candidates dropped (held by another user): %', v_held;
  RAISE NOTICE 'osionos backfill: username candidates dropped (taken by another profile): %', v_taken;
  SELECT count(*) FILTER (WHERE username IS NOT NULL), count(*) FILTER (WHERE username IS NULL)
    INTO v_named, v_nameless
    FROM pg_temp.p1_backfill;
  RAISE NOTICE 'osionos backfill: source users to create with a username: %', v_named;
  RAISE NOTICE 'osionos backfill: source users to create without a username: %', v_nameless;
  -- A public.users row with no auth.users row cannot have a profile: the FK
  -- makes it impossible, and the row is counted here rather than failing the
  -- whole backfill.
  SELECT count(*) INTO v_noauth_users
    FROM public.users u WHERE NOT EXISTS (SELECT 1 FROM auth.users a WHERE a.id = u.id);
  RAISE NOTICE 'osionos backfill: public.users rows left out (no auth.users row): %', v_noauth_users;
  SELECT count(*) INTO v_noauth_identities
    FROM public.osionos_bridge_identities bi
   WHERE bi.user_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM auth.users a WHERE a.id = bi.user_id);
  RAISE NOTICE 'osionos backfill: osionos_bridge_identities rows left out (no auth.users row): %', v_noauth_identities;

  -- Pass 1: the chosen usernames. The bare ON CONFLICT DO NOTHING is the
  -- point: with a conflict target the statement aborts on a single username
  -- collision and nobody gets a profile.
  WITH ins AS (
    INSERT INTO public.osionos_profiles (user_id, display_name, username, headline, bio, location, directory_opt_out)
    SELECT user_id, display_name, username, headline, bio, location, directory_opt_out
      FROM pg_temp.p1_backfill
    ON CONFLICT DO NOTHING
    RETURNING username
  )
  SELECT count(*) FILTER (WHERE username IS NOT NULL), count(*) FILTER (WHERE username IS NULL), count(*)
    INTO v_named, v_nameless, v_pass1
    FROM ins;
  RAISE NOTICE 'osionos backfill: profiles created: % (with a username: %, without: %)', v_pass1, v_named, v_nameless;

  -- Pass 2: everyone the first pass could not insert — a username that
  -- collided with an existing profile — gets a profile without a name.
  WITH ins AS (
    INSERT INTO public.osionos_profiles (user_id, display_name, headline, bio, location, directory_opt_out)
    SELECT b.user_id, b.display_name, b.headline, b.bio, b.location, b.directory_opt_out
      FROM pg_temp.p1_backfill b
     WHERE NOT EXISTS (SELECT 1 FROM public.osionos_profiles p WHERE p.user_id = b.user_id)
    ON CONFLICT DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO v_pass2 FROM ins;
  RAISE NOTICE 'osionos backfill: profiles created without a name (pass 2): %', v_pass2;
END
$$;

COMMIT;

-- PostgREST caches the schema; a new table, a new view and a new role are
-- invisible to it until it reloads.
-- The NOTIFY is deliberately after the COMMIT: the view is dropped and
-- recreated, so PostgREST must reload the schema only once the new view
-- exists. Before the commit it would cache the dropped view's OID.
NOTIFY pgrst, 'reload schema';

-- DOWN (manual, in reverse order). Valid only while nothing reads these
-- objects: the view is the bridge's directory, and the moment the profiles are
-- gone the bridge's People panel is empty.
--   DROP VIEW IF EXISTS public.osionos_people_directory;
--   DROP TRIGGER IF EXISTS osionos_profiles_from_identity ON public.osionos_bridge_identities;
--   DROP TRIGGER IF EXISTS osionos_profiles_on_user_insert ON public.users;
--   DROP TRIGGER IF EXISTS osionos_profiles_username_history ON public.osionos_profiles;
--   DROP TRIGGER IF EXISTS osionos_profiles_username_hold ON public.osionos_profiles;
--   DROP TRIGGER IF EXISTS osionos_profiles_touch ON public.osionos_profiles;
--   DROP FUNCTION IF EXISTS public.osionos_profile_from_identity();
--   DROP FUNCTION IF EXISTS public.osionos_profile_on_user_insert();
--   DROP FUNCTION IF EXISTS public.osionos_username_history_capture();
--   DROP FUNCTION IF EXISTS public.osionos_username_hold_guard();
--   DROP FUNCTION IF EXISTS public.osionos_profiles_touch();
--   DROP FUNCTION IF EXISTS public.osionos_user_settings_merge(text, jsonb);
--   DROP FUNCTION IF EXISTS public.osionos_links_valid(text[]);
--   DROP FUNCTION IF EXISTS public.osionos_orcid_valid(text);
--   DROP FUNCTION IF EXISTS public.osionos_username_reserved(text);
--   DROP TABLE IF EXISTS public.osionos_account_deletion_requests;
--   DROP TABLE IF EXISTS public.osionos_username_history;
--   DROP TABLE IF EXISTS public.osionos_user_settings;
--   DROP TABLE IF EXISTS public.osionos_profiles;
--   DROP INDEX IF EXISTS osionos_profiles_username_lower_uidx;
--   DROP INDEX IF EXISTS osionos_profiles_display_name_user_idx;
--   DROP INDEX IF EXISTS osionos_profiles_search_doc_idx;
--   DROP INDEX IF EXISTS osionos_profiles_display_name_trgm_idx;
--   DROP INDEX IF EXISTS osionos_profiles_username_trgm_idx;
--   DROP INDEX IF EXISTS osionos_profiles_headline_trgm_idx;
--   DROP INDEX IF EXISTS osionos_username_history_name_released_idx;
