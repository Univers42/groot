-- PS31 cover size (ADR 0067 CS5, models/osionos-page-cover-size-migration.sql).
-- Driven by cover-size.sh in its own psql stream. Each query returns exactly
-- one <label>|<count>|<detail> row; a missing column or constraint is a
-- violation, never a zero.

-- cs_columns: both columns exist with the right type and are nullable.
SELECT 'cs_columns', count(*), coalesce(string_agg(v, ' ' ORDER BY v), '')
  FROM (
    SELECT w.col || '_not_' || w.typ AS v
      FROM (VALUES ('cover_height', 'integer'), ('cover_width', 'text')) AS w(col, typ)
     WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns c
                        WHERE c.table_schema = 'public' AND c.table_name = 'osionos_pages'
                          AND c.column_name = w.col AND c.data_type = w.typ
                          AND c.is_nullable = 'YES' AND c.column_default IS NULL)
  ) AS violations;

-- cs_validated: both named constraints exist, are CHECKs and are validated.
SELECT 'cs_validated', count(*), coalesce(string_agg(v, ' ' ORDER BY v), '')
  FROM (
    SELECT w.name || '_not_validated' AS v
      FROM (VALUES ('osionos_pages_cover_height_check'), ('osionos_pages_cover_width_check')) AS w(name)
     WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c
                        WHERE c.conrelid = to_regclass('public.osionos_pages')
                          AND c.conname = w.name AND c.contype = 'c' AND c.convalidated)
  ) AS violations;

-- cs_constraint_count: exactly two CHECKs mention the new columns, so a replay
-- under another name (a duplicate) is a violation too.
SELECT 'cs_constraint_count', (count(*) <> 2)::int, 'found ' || count(*)
  FROM pg_constraint c
 WHERE c.conrelid = to_regclass('public.osionos_pages') AND c.contype = 'c'
   AND (pg_get_constraintdef(c.oid) LIKE '%cover_height%'
     OR pg_get_constraintdef(c.oid) LIKE '%cover_width%');
