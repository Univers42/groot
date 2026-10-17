-- users-pii-grants-migration.sql — the last word on who reads public.users.
--
-- WHY: gdpr-migration.sql, rls-hardening-migration.sql and grobase's
-- 001_initial_schema.sql each grant on public.users, and they disagree. A table-level
-- SELECT survives `REVOKE SELECT (col)`, so the only way to end with a column list is to
-- revoke the table grant and grant the columns back (ADR 0014, devil ML-7).
--
-- END STATE, whatever ran before:
--   anon           SELECT (id, username, is_email_verified), nothing else
--   authenticated  SELECT on every column except password_hash (INSERT/UPDATE/DELETE untouched)
--   password_hash  readable by neither; movieverse_profiles unreachable by both
-- Columns come from information_schema, so a users table without avatar_url (b2b) works.
-- Both runners run this file last (apply-models.sh by name order, the other via ORDERED_LAST).
-- Caveat: a column added to public.users after this runs is NOT granted to authenticated
-- until the next run; the runners re-run it only when its checksum changes or on every
-- apply-models-migrations.sh pass.

DO $$
DECLARE
  cols text;
BEGIN
  IF to_regclass('public.users') IS NOT NULL THEN
    REVOKE ALL ON public.users FROM PUBLIC, anon;
    REVOKE SELECT ON public.users FROM authenticated;

    SELECT string_agg(format('%I', column_name), ', ' ORDER BY ordinal_position) INTO cols
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'users'
       AND column_name IN ('id', 'username', 'is_email_verified');
    IF cols IS NOT NULL THEN
      EXECUTE format('GRANT SELECT (%s) ON public.users TO anon', cols);
    END IF;

    SELECT string_agg(format('%I', column_name), ', ' ORDER BY ordinal_position) INTO cols
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'users'
       AND column_name <> 'password_hash';
    IF cols IS NOT NULL THEN
      EXECUTE format('GRANT SELECT (%s) ON public.users TO authenticated', cols);
    END IF;
  END IF;

  IF to_regclass('public.movieverse_profiles') IS NOT NULL THEN
    REVOKE ALL ON public.movieverse_profiles FROM PUBLIC, anon, authenticated;
  END IF;
END $$;
