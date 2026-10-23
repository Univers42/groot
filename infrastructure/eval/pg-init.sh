#!/bin/sh
# pg-init.sh — the eval engine's own initialization. Runs ONCE, when the
# postgres data directory is empty (the image's /docker-entrypoint-initdb.d
# hook).
#
# It does exactly two things, and they are the two that GoTrue cannot
# start without:
#
#   CREATE SCHEMA auth — GoTrue's first migration creates auth.users, and it
#   cannot create a table in a schema that does not exist.
#
#   ALTER ROLE postgres IN DATABASE postgres SET search_path = auth, public —
#   GoTrue's migrator records its versions in an UNQUALIFIED
#   `schema_migrations` table, so the table lands in the FIRST schema of the
#   search_path. With the default search_path that is `public`, and grobase's
#   own 001_initial_schema.sql then cannot create ITS tracker there — the
#   column shape is different and the migration fails.
#
# Live gets both from its db-bootstrap init container, which the compose
# file makes GoTrue depend on (service_completed_successfully). Eval has no
# such container: the bootstrap runs in migrate.sh, and GoTrue is already
# running by then. This script closes that window.
#
# The roles (anon, authenticated, service_role, authenticator, ...) are NOT
# created here: grobase's db-bootstrap.psql owns them and still creates them
# (migrate.sh, step a).
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<EOSQL
CREATE SCHEMA IF NOT EXISTS auth;
ALTER ROLE postgres IN DATABASE ${POSTGRES_DB} SET search_path = auth, public;
EOSQL
