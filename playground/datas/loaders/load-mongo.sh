#!/usr/bin/env bash
# load-mongo.sh — Import shop-sample CSVs into MongoDB 7 (learn_shop database)
# Usage: ./load-mongo.sh [csv-dir]   (default: sibling ../shop-sample)
#
# Re-runnable: drops learn_shop before loading, leaves data in place after verify.
# Engine client: mongo:7 sidecar for mongoimport; mongosh inside mini-baas-mongo for verify.
# Network: mini-baas_mini-baas
# Scratch namespace: database learn_shop, collections customers / products / orders
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSV_DIR="${1:-${SCRIPT_DIR}/../shop-sample}"
CSV_DIR="$(cd "${CSV_DIR}" && pwd)"

CONTAINER="mini-baas-mongo"
NETWORK="mini-baas_mini-baas"
MONGO_IMAGE="mongo:7"

echo "==> [Mongo] Resolving credentials from container env..."
MONGO_USER="$(docker exec "${CONTAINER}" printenv MONGO_INITDB_ROOT_USERNAME)"
MONGO_PASS="$(docker exec "${CONTAINER}" printenv MONGO_INITDB_ROOT_PASSWORD)"

# URI used by the sidecar (resolves mini-baas-mongo over the Docker network)
SIDECAR_URI="mongodb://${MONGO_USER}:${MONGO_PASS}@${CONTAINER}:27017/learn_shop?authSource=admin"

# ── Cleanup (idempotent drop) ────────────────────────────────────────────────
echo "==> [Mongo] Dropping scratch database learn_shop (cleanup for re-run)..."
docker exec "${CONTAINER}" \
  mongosh --quiet \
  "mongodb://${MONGO_USER}:${MONGO_PASS}@localhost:27017/admin?authSource=admin" \
  --eval "db.getSiblingDB('learn_shop').dropDatabase()"

# ── Load ─────────────────────────────────────────────────────────────────────
for COLLECTION in customers products orders; do
  echo "==> [Mongo] Importing ${COLLECTION}.csv via ${MONGO_IMAGE} sidecar..."
  # Note: mount to /csv, not /data — mongo:7 declares /data as a volume so
  # mounting there triggers an OCI rootfs conflict.
  docker run --rm \
    --network "${NETWORK}" \
    -v "${CSV_DIR}:/csv:ro" \
    "${MONGO_IMAGE}" \
    mongoimport \
    --uri "${SIDECAR_URI}" \
    --collection "${COLLECTION}" \
    --type csv \
    --headerline \
    "/csv/${COLLECTION}.csv"
done

# ── Verify ───────────────────────────────────────────────────────────────────
echo "==> [Mongo] Verifying document counts..."
docker exec "${CONTAINER}" \
  mongosh --quiet \
  "mongodb://${MONGO_USER}:${MONGO_PASS}@localhost:27017/admin?authSource=admin" \
  --eval "
      const d = db.getSiblingDB('learn_shop');
      const c = d.customers.countDocuments();
      const p = d.products.countDocuments();
      const o = d.orders.countDocuments();
      print('customers: ' + c + '  (expected 8)');
      print('products:  ' + p + '  (expected 6)');
      print('orders:    ' + o + '  (expected 15)');
      if (c !== 8 || p !== 6 || o !== 15) {
        print('FAIL — count mismatch!');
        process.exit(1);
      }
      print('==> [Mongo] PASS — all counts match.');
    "
