#!/bin/bash
# Take a backup and upload it to MinIO. Idempotent — each run uses a unique
# timestamp-keyed object; old objects beyond PG_BACKUP_RETAIN_DAYS are pruned.
set -euo pipefail

: "${DATABASE_URL:?required}"
: "${PG_BACKUP_BUCKET:?required}"
: "${PG_BACKUP_PREFIX:?required}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LOGICAL_FILE="${TMP}/postgres-${STAMP}.dump"

echo "[pg-backup] $(date -u +%F\ %T) starting logical backup -> ${LOGICAL_FILE}"

# Custom format (-Fc) is compressed and supports parallel restore.
pg_dump --no-owner --no-privileges --format=custom \
        --file="$LOGICAL_FILE" \
        "$DATABASE_URL"

echo "[pg-backup] dump complete ($(du -h "$LOGICAL_FILE" | cut -f1))"

DEST_KEY="baas/${PG_BACKUP_BUCKET}/${PG_BACKUP_PREFIX}/logical/postgres-${STAMP}.dump"
mc cp "$LOGICAL_FILE" "$DEST_KEY"
echo "[pg-backup] uploaded to ${DEST_KEY}"

# Optional physical base backup (PITR-ready).
if [ "${PG_BACKUP_PHYSICAL:-0}" = "1" ]; then
  PHYS_DIR="${TMP}/base-${STAMP}"
  mkdir -p "$PHYS_DIR"
  echo "[pg-backup] starting physical base backup -> ${PHYS_DIR}"

  # pg_basebackup needs PG* connection vars; the URL doesn't always parse.
  PGHOST="$(echo "$DATABASE_URL" | sed -E 's#.*@([^:/]+).*#\1#')"
  PGPORT="$(echo "$DATABASE_URL" | sed -E 's#.*:([0-9]+).*#\1#')"
  PGUSER="$(echo "$DATABASE_URL" | sed -E 's#.*://([^:]+):.*#\1#')"
  PGPASSWORD="$(echo "$DATABASE_URL" | sed -E 's#.*://[^:]+:([^@]+)@.*#\1#')"
  export PGHOST PGPORT PGUSER PGPASSWORD

  pg_basebackup -D "$PHYS_DIR" --format=tar --gzip --checkpoint=fast \
                --progress --no-password
  for f in "$PHYS_DIR"/*; do
    mc cp "$f" "baas/${PG_BACKUP_BUCKET}/${PG_BACKUP_PREFIX}/physical/base-${STAMP}/$(basename "$f")"
  done
  echo "[pg-backup] physical base uploaded"
fi

# Retention pruning. mc has --older-than which accepts e.g. "14d".
DAYS="${PG_BACKUP_RETAIN_DAYS:-14}"
echo "[pg-backup] pruning artifacts older than ${DAYS}d"
mc rm --recursive --force --older-than "${DAYS}d" \
       "baas/${PG_BACKUP_BUCKET}/${PG_BACKUP_PREFIX}/logical/" 2>/dev/null || true
mc rm --recursive --force --older-than "${DAYS}d" \
       "baas/${PG_BACKUP_BUCKET}/${PG_BACKUP_PREFIX}/physical/" 2>/dev/null || true

echo "[pg-backup] $(date -u +%F\ %T) done"
