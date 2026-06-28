#!/usr/bin/env bash
# load-minio.sh — Upload shop-sample files to MinIO (bucket learn-shop)
# Usage: ./load-minio.sh [csv-dir]   (default: sibling ../shop-sample)
#
# Re-runnable: removes bucket learn-shop before recreating, leaves data in place after verify.
# Objects uploaded under the shop-sample/ prefix:
#   baas/learn-shop/shop-sample/customers.csv
#   baas/learn-shop/shop-sample/products.csv
#   baas/learn-shop/shop-sample/orders.csv
#   baas/learn-shop/shop-sample/schema.sql  (if present)
# Client: minio/mc sidecar; creds resolved at runtime from mini-baas-minio container env.
# Network: mini-baas_mini-baas
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSV_DIR="${1:-${SCRIPT_DIR}/../shop-sample}"
CSV_DIR="$(cd "${CSV_DIR}" && pwd)"

CONTAINER="mini-baas-minio"
NETWORK="mini-baas_mini-baas"
MC_IMAGE="minio/mc:latest"
BUCKET="learn-shop"
PREFIX="shop-sample"

echo "==> [MinIO] Resolving credentials from container env..."
MINIO_USER="$(docker exec "${CONTAINER}" printenv MINIO_ROOT_USER)"
MINIO_PASS="$(docker exec "${CONTAINER}" printenv MINIO_ROOT_PASSWORD)"

# MC_HOST_baas is the alias URL: http://user:pass@host:port
MC_HOST="http://${MINIO_USER}:${MINIO_PASS}@${CONTAINER}:9000"

# ── mc helper (CSV dir mounted read-only as /data) ────────────────────────────
mccli() {
  docker run --rm \
    --network "${NETWORK}" \
    -e "MC_HOST_baas=${MC_HOST}" \
    -v "${CSV_DIR}:/data:ro" \
    "${MC_IMAGE}" \
    "$@"
}

# ── Cleanup (remove bucket if present) ───────────────────────────────────────
echo "==> [MinIO] Removing bucket ${BUCKET} if present (cleanup for re-run)..."
if mccli ls "baas/${BUCKET}" > /dev/null 2>&1; then
  mccli rb --force "baas/${BUCKET}"
  echo "    Removed."
else
  echo "    (bucket did not exist)"
fi

# ── Create bucket ─────────────────────────────────────────────────────────────
echo "==> [MinIO] Creating bucket ${BUCKET}..."
mccli mb "baas/${BUCKET}"

# ── Upload files ──────────────────────────────────────────────────────────────
echo "==> [MinIO] Uploading CSV files to baas/${BUCKET}/${PREFIX}/..."
for FILE in customers.csv products.csv orders.csv; do
  if [ -f "${CSV_DIR}/${FILE}" ]; then
    echo "    Uploading ${FILE}..."
    mccli cp "/data/${FILE}" "baas/${BUCKET}/${PREFIX}/${FILE}"
  else
    echo "    WARN: ${FILE} not found in ${CSV_DIR} — skipping"
  fi
done

# Upload schema.sql if present
if [ -f "${CSV_DIR}/schema.sql" ]; then
  echo "    Uploading schema.sql..."
  mccli cp "/data/schema.sql" "baas/${BUCKET}/${PREFIX}/schema.sql"
fi

# ── Verify ────────────────────────────────────────────────────────────────────
echo "==> [MinIO] Verifying uploaded objects..."
OBJECT_LIST="$(mccli ls "baas/${BUCKET}/${PREFIX}/" 2>/dev/null)"
echo "${OBJECT_LIST}"

CSV_COUNT="$(echo "${OBJECT_LIST}" | grep -c '\.csv$' || true)"
printf 'CSV files: %s  (expected 3)\n' "${CSV_COUNT}"

if [ "${CSV_COUNT}" -ge 3 ]; then
  echo "==> [MinIO] PASS — all 3 CSVs present in baas/${BUCKET}/${PREFIX}/."
else
  echo "==> [MinIO] FAIL — expected 3 CSVs, found ${CSV_COUNT}!"
  exit 1
fi
