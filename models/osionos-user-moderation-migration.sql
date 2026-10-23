-- osionos-user-moderation-migration.sql — the moderation decision on a report (P3-4-e).
--
-- WHY THIS FILE EXISTS
--   The console needs a queue item (the report) and its outcome (warn, suspend, ban,
--   dismiss). The decision lives on the report row, so no new table. A person's live
--   state is read from the reports that carry a decision, by subject_user_id.
--
-- WHAT IT DOES
--   Adds decision, decision_until, decision_by, decision_at, decision_note to
--   public.osionos_user_reports, a CHECK that admits exactly the four decisions, and a
--   partial index for the per-user state lookup (without it every sign-in is a seq scan).
--
-- ORDERING
--   Alphabetical pass: it only ALTERs osionos_user_reports, which
--   osionos-social-migration.sql creates, and that file is in ORDERED_FIRST of
--   scripts/apply-models-migrations.sh. ORDERED_LAST is untouched.
--
-- GRANTS
--   None. The table stays service-role-only: osionos-service-role-only-migration.sql
--   revokes every osionos_% relation from PUBLIC, anon and authenticated on every boot.
--
-- Caveat: decision_until is meaningful for 'suspend' only (NULL = until lifted); the
-- CHECK does not enforce that pairing, the bridge does.

ALTER TABLE public.osionos_user_reports
  ADD COLUMN IF NOT EXISTS decision TEXT,
  ADD COLUMN IF NOT EXISTS decision_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS decision_by UUID,
  ADD COLUMN IF NOT EXISTS decision_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS decision_note TEXT;

-- Replays on every boot: the drop + re-add (ACCESS EXCLUSIVE, full re-validation) is
-- skipped when the one decision CHECK already lists exactly the four values.
DO $$
DECLARE
  cname TEXT;
BEGIN
  IF (SELECT array_agg(con.conname::text)
        FROM pg_constraint con
       WHERE con.conrelid = 'public.osionos_user_reports'::regclass
         AND con.contype = 'c'
         AND pg_get_constraintdef(con.oid) LIKE '%decision IS NULL%'
         AND pg_get_constraintdef(con.oid) LIKE '%''warn''%'
         AND pg_get_constraintdef(con.oid) LIKE '%''suspend''%'
         AND pg_get_constraintdef(con.oid) LIKE '%''ban''%'
         AND pg_get_constraintdef(con.oid) LIKE '%''dismiss''%'
         AND (SELECT count(*) FROM regexp_matches(pg_get_constraintdef(con.oid), '''[a-z]+''', 'g')) = 4)
     = ARRAY['osionos_user_reports_decision_check'] THEN
    RETURN;
  END IF;

  FOR cname IN
    SELECT con.conname
      FROM pg_constraint con
     WHERE con.conrelid = 'public.osionos_user_reports'::regclass
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) LIKE '%decision IS NULL%'
  LOOP
    EXECUTE format('ALTER TABLE public.osionos_user_reports DROP CONSTRAINT %I', cname);
  END LOOP;

  ALTER TABLE public.osionos_user_reports
    ADD CONSTRAINT osionos_user_reports_decision_check
    CHECK (decision IS NULL OR decision IN ('warn', 'suspend', 'ban', 'dismiss'));
END $$;

CREATE INDEX IF NOT EXISTS osionos_user_reports_subject_decision_idx
  ON public.osionos_user_reports (subject_user_id, decision_at DESC)
  WHERE decision IS NOT NULL;
