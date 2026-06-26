-- auth-gateway-users-reconcile-migration.sql
-- ---------------------------------------------------------------------------
-- WHY: account creation through the opposite-osiris website (localhost:4322) was
-- impossible. Two root causes on the SHARED grobase public.users table:
--
--   1. SCHEMA MISMATCH. The pull-only prismatica auth-gateway is coded against the
--      LEGACY "fat" users table (id, username, email, password_hash, theme,
--      notifications_enabled, is_email_verified). The live grobase public.users is
--      the THIN profile mirror (id, email, name). So the availability check
--      GET /users?username=eq.X -> PostgREST 400 {"message":"column users.username
--      does not exist"} (auth-gateway.mjs:295,304). The throw is uncaught, so even a
--      valid /api/auth/register dies at the availability precheck with the same 400.
--
--   2. TRIGGER ROLLBACK (why public.users had 0 rows despite 39 auth.users). The
--      grobase handle_new_user() did INSERT user_profiles ... ON CONFLICT (user_id),
--      but user_profiles had NO unique index on user_id (only its pkey on id) ->
--      error 42P10 -> the single EXCEPTION WHEN OTHERS rolled back the WHOLE block,
--      discarding the public.users insert too.
--
-- FIX (DB-only, additive, idempotent — the gateway image is pull-only):
--   - add the 5 legacy columns the gateway reads/writes (all nullable/defaulted);
--   - add the missing user_profiles(user_id) unique index so the ON CONFLICT is valid;
--   - harden handle_new_user into independent sub-blocks so a user_profiles failure
--     can never again roll back the users row (the data-loss footgun above);
--   - a BEFORE INSERT reconcile trigger that turns the gateway's id-less duplicate-
--     email insert into an UPDATE of the existing auth-linked row and RETURN NULL,
--     so id = auth.users.id is preserved (osionos RLS users_select_own depends on it)
--     and the gateway insert no longer 409s. Scoped to the gateway path
--     (password_hash = 'managed-by-gotrue') so nothing else can overwrite a row via a
--     duplicate-email insert.
--
-- Safe to run twice. Apply:
--   docker exec -i mini-baas-postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     -f - < models/auth-gateway-users-reconcile-migration.sql
-- Then reload PostgREST: NOTIFY pgrst, 'reload schema';
-- ---------------------------------------------------------------------------
BEGIN;

-- 1) Additive legacy columns the gateway reads/writes. All NULLABLE/defaulted so the
--    grobase-native handle_new_user (id,email,name) insert keeps working. password_hash
--    only ever carries the placeholder 'managed-by-gotrue' (vestigial under gotrue).
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS username              text;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS password_hash         text;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS theme                 text    DEFAULT 'light';
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS notifications_enabled boolean DEFAULT true;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS is_email_verified     boolean DEFAULT false;

-- 2) Case-insensitive partial unique index for username (multiple NULLs allowed),
--    mirroring osionos-social-migration.sql's pattern on osionos_bridge_identities.
CREATE UNIQUE INDEX IF NOT EXISTS users_username_lower_uidx
  ON public.users (lower(username)) WHERE username IS NOT NULL;

-- 3) Unique index on user_profiles.user_id so handle_new_user's ON CONFLICT (user_id)
--    is valid. Safe: user_profiles has 0 dup user_ids and nothing FK-references it.
CREATE UNIQUE INDEX IF NOT EXISTS user_profiles_user_id_uidx
  ON public.user_profiles (user_id);

-- 4) Defensive idempotent grant (table grant already covers new columns; harmless).
GRANT SELECT, INSERT, UPDATE ON public.users TO service_role;

-- 5) Reconcile trigger: convert the gateway's id-less duplicate-email INSERT into an
--    UPDATE of the existing auth-linked row and RETURN NULL. Scoped to the gateway
--    (password_hash = 'managed-by-gotrue') so no other inserter can use a duplicate
--    email to overwrite username/theme/is_email_verified. SECURITY DEFINER (owner
--    postgres) bypasses the FORCED RLS on public.users.
CREATE OR REPLACE FUNCTION public.users_reconcile_email()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE existing_id uuid;
BEGIN
  IF NEW.password_hash IS DISTINCT FROM 'managed-by-gotrue' THEN
    RETURN NEW;  -- not the gateway path: let normal UNIQUE handling apply
  END IF;
  SELECT id INTO existing_id FROM public.users WHERE email = NEW.email;
  IF existing_id IS NOT NULL AND existing_id IS DISTINCT FROM NEW.id THEN
    UPDATE public.users SET
      username              = COALESCE(NEW.username, username),
      password_hash         = COALESCE(NEW.password_hash, password_hash),
      theme                 = COALESCE(NEW.theme, theme),
      notifications_enabled = COALESCE(NEW.notifications_enabled, notifications_enabled),
      is_email_verified     = COALESCE(NEW.is_email_verified, is_email_verified),
      name                  = COALESCE(name, NEW.name),
      updated_at            = now()
    WHERE id = existing_id;
    RETURN NULL;  -- skip duplicate insert; existing auth-linked row reconciled in place
  END IF;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS users_reconcile_email_trg ON public.users;
CREATE TRIGGER users_reconcile_email_trg
  BEFORE INSERT ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.users_reconcile_email();

-- 6) Harden handle_new_user: independent BEGIN/EXCEPTION sub-blocks so a user_profiles
--    failure can no longer roll back the users row (root cause of the 0/39 profiles),
--    plus best-effort username from gotrue metadata.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
BEGIN
  BEGIN
    INSERT INTO public.users (id, email, name)
    VALUES (NEW.id, NEW.email,
            COALESCE(NEW.raw_user_meta_data->>'display_name', split_part(NEW.email,'@',1)))
    ON CONFLICT (id) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'handle_new_user: users insert failed for %: %', NEW.id, SQLERRM;
  END;

  BEGIN
    UPDATE public.users
       SET username = NULLIF(NEW.raw_user_meta_data->>'username','')
     WHERE id = NEW.id
       AND NULLIF(NEW.raw_user_meta_data->>'username','') IS NOT NULL
       AND username IS DISTINCT FROM NULLIF(NEW.raw_user_meta_data->>'username','');
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'handle_new_user: username set failed for %: %', NEW.id, SQLERRM;
  END;

  BEGIN
    INSERT INTO public.user_profiles (user_id, display_name, avatar_url)
    VALUES (NEW.id,
            COALESCE(NEW.raw_user_meta_data->>'display_name', split_part(NEW.email,'@',1)),
            NEW.raw_user_meta_data->>'avatar_url')
    ON CONFLICT (user_id) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'handle_new_user: user_profiles insert failed for %: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$fn$;

-- 7) Idempotent backfill of the existing orphaned auth.users (public.users was 0 rows).
--    username left NULL to avoid metadata-dup collisions; reconcile/handle_new_user
--    populate it going forward.
INSERT INTO public.users (id, email, name)
SELECT au.id, au.email,
       COALESCE(au.raw_user_meta_data->>'display_name', split_part(au.email,'@',1))
FROM auth.users au
WHERE au.email IS NOT NULL
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.user_profiles (user_id, display_name, avatar_url)
SELECT au.id,
       COALESCE(au.raw_user_meta_data->>'display_name', split_part(au.email,'@',1)),
       au.raw_user_meta_data->>'avatar_url'
FROM auth.users au
WHERE au.email IS NOT NULL
ON CONFLICT (user_id) DO NOTHING;

COMMIT;
