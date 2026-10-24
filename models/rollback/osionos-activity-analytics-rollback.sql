-- The rollback of models/osionos-activity-analytics-migration.sql.
--
-- The runners' glob is models/*.sql, which does not reach models/rollback/: this is
-- run by hand. Functions first, then the rollup, then the events table (dropping the
-- partitioned parent drops osionos_activity_events_default and every monthly child).
--
-- WHAT A ROLLBACK COSTS
--   Every raw activity row and every daily cell is dropped with the tables.
--   The registry row in osionos-account-erasure-migration.sql stays on purpose: the
--   registry resolves tables with to_regclass, so a row for an absent table is inert,
--   and keeping it means a re-apply needs no registry edit.
--
-- Idempotent: every statement is IF EXISTS shaped.

DROP FUNCTION IF EXISTS public.osionos_activity_rollup(date);
DROP FUNCTION IF EXISTS public.osionos_activity_maintain(integer, integer);
DROP TABLE IF EXISTS public.osionos_activity_daily;
DROP TABLE IF EXISTS public.osionos_activity_events;
