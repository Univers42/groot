#!/usr/bin/env bash
# ============================================================
# load-cs50-postgres.sh  <sqlite.db>  [target-db]
# ============================================================
# Load a WHOLE SQLite .db file (schema + data) into Postgres
# using a `dimitri/pgloader` sidecar container on the
# mini-baas_mini-baas Docker network.
#
# Docker-only: uses docker exec for credential retrieval and
# docker run for the pgloader sidecar.  No host pgloader or
# psql required.
#
# Workflow:
#   1. Resolve the target-db name (default: learn_<stem of .db file>)
#   2. Read POSTGRES_USER / POSTGRES_PASSWORD from the running
#      mini-baas-postgres container (never hardcoded here)
#   3. DROP + CREATE the target database in Postgres
#   4. Run pgloader as a throwaway container on mini-baas_mini-baas
#      to migrate schema + data in one shot
#
# Usage:
#   bash load-cs50-postgres.sh cs50/downloads/pset1-relating/packages/packages.db
#   bash load-cs50-postgres.sh /path/to/movies.db learn_movies
#
# Requires:
#   - mini-baas-postgres container running (part of `make all`)
#   - dimitri/pgloader image pullable from Docker Hub
#     (if the image cannot be pulled in your environment, the
#      pgloader step is marked as "pattern — unverified here"
#      in the error output; the DROP/CREATE step still runs)
# ============================================================
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <sqlite.db> [target-db]" >&2
  exit 1
fi

SQLITE_DB="$1"
SQLITE_ABS="$(cd "$(dirname "${SQLITE_DB}")" && pwd)/$(basename "${SQLITE_DB}")"
SQLITE_DIR="$(dirname "${SQLITE_ABS}")"
SQLITE_FILE="$(basename "${SQLITE_ABS}")"

# Derive target DB name from the .db filename (e.g. packages.db → learn_packages)
STEM="${SQLITE_FILE%.db}"
TARGET_DB="${2:-learn_${STEM}}"

PG_CONTAINER="mini-baas-postgres"
NETWORK="mini-baas_mini-baas"
PG_HOST="mini-baas-postgres" # hostname inside the Docker network

echo "==> [cs50→postgres] SQLite source : ${SQLITE_ABS}"
echo "==> [cs50→postgres] Target DB     : ${TARGET_DB}"
echo ""

# ── 1. Read credentials from the running Postgres container ────────────────
# These are used only to build the pgloader connection URL; they are stored
# in local shell variables and never echoed to stdout.
PG_USER=$(docker exec "${PG_CONTAINER}" sh -lc 'printf "%s" "$POSTGRES_USER"')
PG_PASS=$(docker exec "${PG_CONTAINER}" sh -lc 'printf "%s" "$POSTGRES_PASSWORD"')

# ── 2. Drop and recreate the target database ───────────────────────────────
echo "--- drop + create ${TARGET_DB} in Postgres ---"
docker exec "${PG_CONTAINER}" sh -lc "
  psql -U \"\$POSTGRES_USER\" -d postgres \
    -c \"DROP DATABASE IF EXISTS ${TARGET_DB};\" \
    -c \"CREATE DATABASE ${TARGET_DB};\"
"

# ── 3. Run pgloader sidecar ────────────────────────────────────────────────
# The dimitri/pgloader image is large (~500 MB); pull may fail in air-gapped
# or bandwidth-constrained environments.  If it does, the migration pattern is:
#
#   docker run --rm --network mini-baas_mini-baas \
#     -v /path/to/sqlite-dir:/data:ro \
#     dimitri/pgloader \
#     pgloader /data/<file>.db postgresql://USER:PASS@mini-baas-postgres:5432/<target>
#
# (pattern — unverified here if image pull fails)

echo "--- running pgloader (SQLite → Postgres) ---"
echo "    source: /data/${SQLITE_FILE}"
echo "    target: postgresql://<user>:***@${PG_HOST}:5432/${TARGET_DB}"
echo ""

if docker run --rm \
  --network "${NETWORK}" \
  -v "${SQLITE_DIR}:/data:ro" \
  dimitri/pgloader \
  pgloader "/data/${SQLITE_FILE}" \
  "postgresql://${PG_USER}:${PG_PASS}@${PG_HOST}:5432/${TARGET_DB}"; then

  echo ""
  echo "--- verification (table list + row counts) ---"
  docker exec "${PG_CONTAINER}" sh -lc "
    psql -U \"\$POSTGRES_USER\" -d ${TARGET_DB} -c \"
      SELECT table_name, (
        SELECT COUNT(*) FROM information_schema.columns
        WHERE table_name = t.table_name
          AND table_schema = 'public'
      ) AS columns
      FROM information_schema.tables t
      WHERE table_schema = 'public'
      ORDER BY table_name;
    \"
  "
  echo ""
  echo "==> [cs50→postgres] ${TARGET_DB} loaded successfully."

else
  echo "" >&2
  echo "ERROR: pgloader run failed." >&2
  echo "If the image could not be pulled, use the pattern above manually." >&2
  echo "(pattern — unverified here)" >&2
  exit 1
fi
