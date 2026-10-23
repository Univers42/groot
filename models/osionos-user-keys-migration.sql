-- osionos-user-keys-migration.sql — the public SSH and GPG keys of an account.
--
-- WHY THIS FILE EXISTS
--   A user registers public keys (SSH, GPG) so their IDE sandbox can verify
--   commit signatures. The table holds PUBLIC material only: there is no
--   private-key column, and the bridge refuses private material by content
--   (scripts/bridge-key-parse.mjs) before a row is ever written.
--
-- WHO REACHES WHAT
--   service_role          everything; the bridge is the only writer.
--   osionos_account_user  the published columns of its OWN rows (column grants
--                         plus row-level security), never a write.
--   anon, authenticated   nothing.
--
-- WHY THE 50-ROW CAP IS A TRIGGER
--   An application-side count races: two concurrent POSTs both read 49 and both
--   insert. The trigger takes a per-user advisory lock for the transaction, so
--   the count and the insert are serial per user, and it raises 'key_limit'
--   (the bridge maps that text to 409 key_limit).
--
-- WHY THE REALTIME TRIGGER IS DROPPED HERE
--   grobase's CREATE TABLE hook (apps/grobase/scripts/migrations/postgresql/
--   012_realtime_triggers_all_tables.sql) broadcasts every row of every new
--   public table to every subscriber.
--
-- WHERE IT RUNS
--   scripts/apply-models-migrations.sh lists it in ORDERED_LAST after
--   osionos-personal-access-tokens-migration.sql and before
--   osionos-service-role-only-migration.sql (the catalog pass must SEE it).
--
-- Idempotent: a second run moves no grant, policy, trigger or index.

BEGIN;

-- Caveat: a busy table makes this file fail (the transaction rolls back) instead
-- of waiting; the next run retries it. 5 s is a budget, not a promise.
SET LOCAL lock_timeout = '5s';

-- Caveat: the CHECKs bound size and shape, not validity: a row whose public_key
-- is not a real key is stored if the service role writes it. The bridge is the
-- only place a key is parsed.
CREATE TABLE IF NOT EXISTS public.osionos_user_keys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('ssh','gpg')),
  title TEXT NOT NULL CHECK (char_length(title) BETWEEN 1 AND 80),
  public_key TEXT NOT NULL CHECK (octet_length(public_key) <= 16384),
  fingerprint TEXT NOT NULL,
  key_type TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT osionos_user_keys_user_kind_fingerprint_key UNIQUE (user_id, kind, fingerprint)
);

CREATE OR REPLACE FUNCTION public.osionos_user_keys_limit() RETURNS trigger
  LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.user_id IS NOT DISTINCT FROM OLD.user_id THEN
    RETURN NEW;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext(NEW.user_id::text));
  IF (SELECT count(*) FROM public.osionos_user_keys WHERE user_id = NEW.user_id) >= 50 THEN
    RAISE EXCEPTION 'key_limit' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.osionos_user_keys_limit() FROM PUBLIC;

DROP TRIGGER IF EXISTS osionos_user_keys_limit_trigger ON public.osionos_user_keys;
CREATE TRIGGER osionos_user_keys_limit_trigger BEFORE INSERT OR UPDATE OF user_id ON public.osionos_user_keys
  FOR EACH ROW EXECUTE FUNCTION public.osionos_user_keys_limit();

CREATE INDEX IF NOT EXISTS osionos_user_keys_user_idx
  ON public.osionos_user_keys (user_id, created_at DESC);

DROP TRIGGER IF EXISTS osionos_user_keys_realtime_trigger ON public.osionos_user_keys;

ALTER TABLE public.osionos_user_keys ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.osionos_user_keys FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.osionos_user_keys TO service_role;
REVOKE ALL ON public.osionos_user_keys FROM osionos_account_user;
GRANT SELECT (id, user_id, kind, title, public_key, fingerprint, key_type, created_at)
  ON public.osionos_user_keys TO osionos_account_user;
DROP POLICY IF EXISTS osionos_user_keys_service_role_all ON public.osionos_user_keys;
CREATE POLICY osionos_user_keys_service_role_all ON public.osionos_user_keys FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS osionos_user_keys_owner_read ON public.osionos_user_keys;
CREATE POLICY osionos_user_keys_owner_read ON public.osionos_user_keys FOR SELECT TO osionos_account_user
  USING (user_id = (SELECT public.osionos_account_uid()));
COMMENT ON TABLE public.osionos_user_keys IS 'osionos:account-plane';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- DOWN (manual): valid only while no bridge reads the table.
--   DROP TRIGGER IF EXISTS osionos_user_keys_limit_trigger ON public.osionos_user_keys;
--   DROP FUNCTION IF EXISTS public.osionos_user_keys_limit();
--   DROP TABLE IF EXISTS public.osionos_user_keys;
