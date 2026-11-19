-- osionos-page-cover-size-migration.sql — cover height and width on a page
-- (PS31, ADR 0067 CS1-CS5).
--
-- WHAT IT CREATES
--   public.osionos_pages.cover_height  integer, NULL, CHECK 120..640 (pixels)
--   public.osionos_pages.cover_width   text,    NULL, CHECK 'full' or 'content'
--   NULL means "the reader's default size"; no row is rewritten or backfilled.
--
-- WHY NO WRITER MAY NAME THE COLUMNS BEFORE THIS FILE HAS RUN EVERYWHERE (CS13)
--   A backend without the columns answers a PostgREST request that names them
--   with PGRST204 (400); a value outside a CHECK answers 23514 (400); a
--   non-integer cover_height answers 22P02 (400). The osionos client maps every
--   status other than 403, 404 and 413 to "failed" (store/sync/publishResult.ts:55-60,
--   publishResultFor), and a "failed" page STOPS the whole flush batch and backs
--   off (store/sync/pageFlush.ts:25, the stop decision at :130). One page naming
--   an absent column therefore stalls every page behind it, forever, because
--   re-sending the same body never lands. The bridge validates both fields
--   before PostgREST (CS15); the CHECKs here are the backstop, never the first line.
--
-- WHY THE CONSTRAINTS ARE ADDED SEPARATELY AND NOT VALID
--   An inline CHECK on ADD COLUMN IF NOT EXISTS is skipped silently when the
--   column already exists, leaving that backend unconstrained. So each CHECK is
--   added by name, only when pg_constraint lacks the name, as NOT VALID (no
--   scan under ACCESS EXCLUSIVE), then VALIDATEd in a second transaction that
--   holds only SHARE UPDATE EXCLUSIVE.
--
-- WHY NO GRANT AND NO REVOKE (CS2)
--   service_role holds the table-level grants, which cover new columns.
--   osionos-service-role-only-migration.sql runs last and is unaffected.
--
-- WHERE IT RUNS
--   scripts/apply-models-migrations.sh picks it up in the alphabetical pass; it
--   sorts after osionos-bridge-migration.sql (ORDERED_FIRST), which creates
--   osionos_pages, so no ordering list names it. On production it is applied
--   alone, never through the runner (CS9).
--
-- Idempotent: a replay adds no column and no constraint (CS4).
--
-- DOWN (manual). Roll back every piece of code that names cover_height or
-- cover_width FIRST (the bridge's PAGE_LIST_SELECT and PATCH), then, only while
--   SELECT count(*) FROM public.osionos_pages WHERE cover_height IS NOT NULL;
--   SELECT count(*) FROM public.osionos_pages WHERE cover_width  IS NOT NULL;
-- both return 0 (CS16: otherwise the DROP deletes user data):
--   ALTER TABLE public.osionos_pages DROP CONSTRAINT osionos_pages_cover_height_check;
--   ALTER TABLE public.osionos_pages DROP CONSTRAINT osionos_pages_cover_width_check;
--   ALTER TABLE public.osionos_pages DROP COLUMN cover_height;
--   ALTER TABLE public.osionos_pages DROP COLUMN cover_width;
--   NOTIFY pgrst, 'reload schema';

BEGIN;

-- Caveat: a busy table makes this file fail (the whole transaction rolls
-- back) instead of waiting; the next run retries it. 5 s is a budget, not a
-- promise.
SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                  WHERE table_schema = 'public' AND table_name = 'osionos_pages') THEN
    RAISE EXCEPTION 'public.osionos_pages is missing — osionos-bridge-migration.sql must run first';
  END IF;
END
$$;

-- No DEFAULT: the change is metadata-only and rewrites no row.
ALTER TABLE public.osionos_pages
  ADD COLUMN IF NOT EXISTS cover_height integer,
  ADD COLUMN IF NOT EXISTS cover_width text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.osionos_pages'::regclass
                    AND conname = 'osionos_pages_cover_height_check') THEN
    ALTER TABLE public.osionos_pages
      ADD CONSTRAINT osionos_pages_cover_height_check
      CHECK (cover_height BETWEEN 120 AND 640) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.osionos_pages'::regclass
                    AND conname = 'osionos_pages_cover_width_check') THEN
    ALTER TABLE public.osionos_pages
      ADD CONSTRAINT osionos_pages_cover_width_check
      CHECK (cover_width IN ('full', 'content')) NOT VALID;
  END IF;
END
$$;

COMMIT;

BEGIN;

-- Caveat: same budget as above; VALIDATE scans the table (about 10k rows, all
-- NULL, on production) and takes SHARE UPDATE EXCLUSIVE, so writers go on.
SET LOCAL lock_timeout = '5s';

ALTER TABLE public.osionos_pages VALIDATE CONSTRAINT osionos_pages_cover_height_check;
ALTER TABLE public.osionos_pages VALIDATE CONSTRAINT osionos_pages_cover_width_check;

COMMIT;

-- PostgREST caches the schema; the NOTIFY is after the COMMIT so the columns
-- exist before PostgREST reads them.
NOTIFY pgrst, 'reload schema';
