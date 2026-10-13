-- Pre-1e407614 db-bootstrap.psql:23-24 (removed 2026-09-25): ran on every boot.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated;