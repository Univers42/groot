-- ===========================================================================
-- osionos NATIVE edition — minimal bootstrap for a fresh, STOCK Postgres.
--
-- Validated by the Phase-2 PoC: the osionos schema needs only this (NOT the
-- mini-baas track-binocle-postgres image, and NONE of db-bootstrap.psql's
-- tenant/adapter/realtime/supabase_admin machinery). Run ONCE on first launch,
-- BEFORE the migrations. Idempotent (safe to re-run).
-- ===========================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- PostgREST roles. anon/authenticated are SET ROLE'd into per request from the
-- JWT; service_role bypasses RLS for the bridge's server-side reads/writes.
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon')          THEN CREATE ROLE anon NOLOGIN; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF; END $$;

-- The LOGIN role PostgREST authenticates as; NOINHERIT so it holds no privilege
-- until it SET ROLEs into one of the three above (per the request's JWT). Its
-- password is set by firstrun.mjs to the generated local secret.
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticator') THEN CREATE ROLE authenticator NOINHERIT LOGIN; END IF; END $$;
GRANT anon, authenticated, service_role TO authenticator;

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES   TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL                          ON TABLES   TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT                 ON SEQUENCES TO anon, authenticated, service_role;
