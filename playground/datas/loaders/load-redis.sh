#!/usr/bin/env bash
# load-redis.sh — Load shop-sample CSVs into Redis (logical DB 15, shop: key prefix)
# Usage: ./load-redis.sh [csv-dir]   (default: sibling ../shop-sample)
#
# Re-runnable: FLUSHes DB 15 before loading (NEVER touches other DBs), leaves data in place.
# Key layout:
#   shop:customer:<id>   HASH — id name email created_at
#   shop:product:<id>    HASH — id name price_cents stock
#   shop:order:<id>      HASH — id customer_id product_id qty status created_at
#   shop:customers       SET  — index of customer keys
#   shop:products        SET  — index of product keys
#   shop:orders          SET  — index of order keys
# Total keys: 29 hashes + 3 sets = 32
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSV_DIR="${1:-${SCRIPT_DIR}/../shop-sample}"
CSV_DIR="$(cd "${CSV_DIR}" && pwd)"

CONTAINER="mini-baas-redis"

# ── RESP wire-format generator ────────────────────────────────────────────────
# Each argument becomes one RESP bulk string; passes through bash arg splitting
# so quoted strings with spaces work correctly.
resp() {
  printf "*%d\r\n" "$#"
  for arg in "$@"; do
    printf "\$%d\r\n%s\r\n" "${#arg}" "${arg}"
  done
}

# ── Cleanup (DB 15 only) ─────────────────────────────────────────────────────
echo "==> [Redis] Flushing DB 15 (cleanup for re-run — never touches other DBs)..."
docker exec "${CONTAINER}" redis-cli -n 15 FLUSHDB

# ── Load via --pipe ───────────────────────────────────────────────────────────
echo "==> [Redis] Streaming HSET + SADD commands via redis-cli --pipe (DB 15)..."
{
  # customers: id,name,email,created_at
  tail -n +2 "${CSV_DIR}/customers.csv" | while IFS=, read -r id name email created_at; do
    resp HSET "shop:customer:${id}" \
      id "${id}" name "${name}" email "${email}" created_at "${created_at}"
    resp SADD shop:customers "shop:customer:${id}"
  done

  # products: id,name,price_cents,stock
  tail -n +2 "${CSV_DIR}/products.csv" | while IFS=, read -r id name price_cents stock; do
    resp HSET "shop:product:${id}" \
      id "${id}" name "${name}" price_cents "${price_cents}" stock "${stock}"
    resp SADD shop:products "shop:product:${id}"
  done

  # orders: id,customer_id,product_id,qty,status,created_at
  tail -n +2 "${CSV_DIR}/orders.csv" | \
    while IFS=, read -r id customer_id product_id qty status created_at; do
      resp HSET "shop:order:${id}" \
        id "${id}" customer_id "${customer_id}" product_id "${product_id}" \
        qty "${qty}" status "${status}" created_at "${created_at}"
      resp SADD shop:orders "shop:order:${id}"
    done
} | docker exec -i "${CONTAINER}" redis-cli -n 15 --pipe

# ── Verify ───────────────────────────────────────────────────────────────────
echo "==> [Redis] Verifying counts via SCARD on index sets..."
CUST_COUNT="$(docker exec "${CONTAINER}" redis-cli -n 15 SCARD shop:customers)"
PROD_COUNT="$(docker exec "${CONTAINER}" redis-cli -n 15 SCARD shop:products)"
ORD_COUNT="$(docker exec "${CONTAINER}"  redis-cli -n 15 SCARD shop:orders)"
TOTAL_KEYS="$(docker exec "${CONTAINER}" redis-cli -n 15 DBSIZE)"

printf 'customers: %s  (expected 8)\n'  "${CUST_COUNT}"
printf 'products:  %s  (expected 6)\n'  "${PROD_COUNT}"
printf 'orders:    %s  (expected 15)\n' "${ORD_COUNT}"
printf 'total keys in DB 15: %s  (expected 32)\n' "${TOTAL_KEYS}"

if [ "${CUST_COUNT}" = "8" ] && [ "${PROD_COUNT}" = "6" ] && [ "${ORD_COUNT}" = "15" ]; then
  echo "==> [Redis] PASS — all counts match."
else
  echo "==> [Redis] FAIL — count mismatch!"
  exit 1
fi
