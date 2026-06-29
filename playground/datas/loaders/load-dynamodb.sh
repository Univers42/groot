#!/usr/bin/env bash
# load-dynamodb.sh — Load shop-sample CSVs into DynamoDB Local (learn_shop_* tables)
# Usage: ./load-dynamodb.sh [csv-dir]   (default: sibling ../shop-sample)
#
# Re-runnable: deletes the three tables before recreating, leaves data in place after verify.
# Tables: learn_shop_customers  (PK: id N)
#         learn_shop_products   (PK: id N)
#         learn_shop_orders     (PK: id N)
# Client: amazon/aws-cli sidecar with dummy local creds; endpoint on mini-baas network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSV_DIR="${1:-${SCRIPT_DIR}/../shop-sample}"
CSV_DIR="$(cd "${CSV_DIR}" && pwd)"

NETWORK="mini-baas_mini-baas"
ENDPOINT="http://mini-baas-dynamodb-local:8000"
AWS_IMAGE="amazon/aws-cli:latest"

# Temp dir for generated JSON (auto-cleaned on exit)
TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_WORK}"' EXIT

# ── aws-cli helper ────────────────────────────────────────────────────────────
# Mounts TMPDIR_WORK as /json inside the container so file:// paths resolve.
awscli() {
  docker run --rm \
    --network "${NETWORK}" \
    -e AWS_ACCESS_KEY_ID=local \
    -e AWS_SECRET_ACCESS_KEY=local \
    -e AWS_DEFAULT_REGION=us-east-1 \
    -v "${TMPDIR_WORK}:/json:ro" \
    "${AWS_IMAGE}" \
    --endpoint-url "${ENDPOINT}" \
    dynamodb "$@"
}

# ── Delete-and-wait helper ────────────────────────────────────────────────────
drop_table() {
  local tname="$1"
  echo "    Dropping ${tname} (if present)..."
  if awscli describe-table --table-name "${tname}" >/dev/null 2>&1; then
    awscli delete-table --table-name "${tname}" >/dev/null
    # Poll until gone (DynamoDB Local deletes synchronously, but be safe)
    local retries=10
    while awscli describe-table --table-name "${tname}" >/dev/null 2>&1; do
      retries=$((retries - 1))
      [ "${retries}" -eq 0 ] && {
        echo "ERROR: ${tname} delete timed out"
        exit 1
      }
      sleep 0.5
    done
    echo "    Deleted."
  else
    echo "    (did not exist)"
  fi
}

# ── JSON helpers ──────────────────────────────────────────────────────────────
# Emit one DynamoDB PutRequest JSON object with typed attributes.
# Usage: put_item_N_fields  (one variant per table schema)

# customers: id(N) name(S) email(S) created_at(S)
customer_item() {
  local id="$1" name="$2" email="$3" created_at="$4"
  printf '{"PutRequest":{"Item":{"id":{"N":"%s"},"name":{"S":"%s"},"email":{"S":"%s"},"created_at":{"S":"%s"}}}}\n' \
    "${id}" "${name}" "${email}" "${created_at}"
}

# products: id(N) name(S) price_cents(N) stock(N)
product_item() {
  local id="$1" name="$2" price_cents="$3" stock="$4"
  printf '{"PutRequest":{"Item":{"id":{"N":"%s"},"name":{"S":"%s"},"price_cents":{"N":"%s"},"stock":{"N":"%s"}}}}\n' \
    "${id}" "${name}" "${price_cents}" "${stock}"
}

# orders: id(N) customer_id(N) product_id(N) qty(N) status(S) created_at(S)
order_item() {
  local id="$1" cid="$2" pid="$3" qty="$4" status="$5" created_at="$6"
  printf '{"PutRequest":{"Item":{"id":{"N":"%s"},"customer_id":{"N":"%s"},"product_id":{"N":"%s"},"qty":{"N":"%s"},"status":{"S":"%s"},"created_at":{"S":"%s"}}}}\n' \
    "${id}" "${cid}" "${pid}" "${qty}" "${status}" "${created_at}"
}

build_batch_json() {
  local table="$1" items_file="$2" out_file="$3"
  # --request-items is already the RequestItems parameter; provide the bare table map.
  local items
  items="$(paste -sd ',' "${items_file}")"
  printf '{"%s":[%s]}' "${table}" "${items}" >"${out_file}"
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
echo "==> [DynamoDB] Dropping scratch tables (cleanup for re-run)..."
drop_table learn_shop_customers
drop_table learn_shop_products
drop_table learn_shop_orders

# ── Create tables ─────────────────────────────────────────────────────────────
echo "==> [DynamoDB] Creating tables..."
for TABLE in learn_shop_customers learn_shop_products learn_shop_orders; do
  echo "    Creating ${TABLE}..."
  awscli create-table \
    --table-name "${TABLE}" \
    --attribute-definitions AttributeName=id,AttributeType=N \
    --key-schema AttributeName=id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    >/dev/null
done

# ── Generate JSON batch files ─────────────────────────────────────────────────
echo "==> [DynamoDB] Generating batch-write JSON from CSVs..."

# customers
CUST_ITEMS="${TMPDIR_WORK}/cust_items.txt"
: >"${CUST_ITEMS}"
tail -n +2 "${CSV_DIR}/customers.csv" | while IFS=, read -r id name email created_at; do
  customer_item "${id}" "${name}" "${email}" "${created_at}" >>"${CUST_ITEMS}"
done
build_batch_json learn_shop_customers "${CUST_ITEMS}" "${TMPDIR_WORK}/batch_customers.json"

# products
PROD_ITEMS="${TMPDIR_WORK}/prod_items.txt"
: >"${PROD_ITEMS}"
tail -n +2 "${CSV_DIR}/products.csv" | while IFS=, read -r id name price_cents stock; do
  product_item "${id}" "${name}" "${price_cents}" "${stock}" >>"${PROD_ITEMS}"
done
build_batch_json learn_shop_products "${PROD_ITEMS}" "${TMPDIR_WORK}/batch_products.json"

# orders
ORD_ITEMS="${TMPDIR_WORK}/ord_items.txt"
: >"${ORD_ITEMS}"
tail -n +2 "${CSV_DIR}/orders.csv" |
  while IFS=, read -r id customer_id product_id qty status created_at; do
    order_item "${id}" "${customer_id}" "${product_id}" "${qty}" "${status}" "${created_at}" \
      >>"${ORD_ITEMS}"
  done
build_batch_json learn_shop_orders "${ORD_ITEMS}" "${TMPDIR_WORK}/batch_orders.json"

# ── Load ─────────────────────────────────────────────────────────────────────
echo "==> [DynamoDB] Loading via batch-write-item..."
for PAIR in "learn_shop_customers:batch_customers.json" "learn_shop_products:batch_products.json" "learn_shop_orders:batch_orders.json"; do
  TABLE="${PAIR%%:*}"
  JSON_FILE="${PAIR##*:}"
  echo "    Writing to ${TABLE}..."
  awscli batch-write-item \
    --request-items "file:///json/${JSON_FILE}" \
    >/dev/null
done

# ── Verify ────────────────────────────────────────────────────────────────────
echo "==> [DynamoDB] Verifying item counts via scan --select COUNT..."
CUST_COUNT="$(awscli scan --table-name learn_shop_customers --select COUNT --query 'Count' --output text)"
PROD_COUNT="$(awscli scan --table-name learn_shop_products --select COUNT --query 'Count' --output text)"
ORD_COUNT="$(awscli scan --table-name learn_shop_orders --select COUNT --query 'Count' --output text)"

printf 'customers: %s  (expected 8)\n' "${CUST_COUNT}"
printf 'products:  %s  (expected 6)\n' "${PROD_COUNT}"
printf 'orders:    %s  (expected 15)\n' "${ORD_COUNT}"

if [ "${CUST_COUNT}" = "8" ] && [ "${PROD_COUNT}" = "6" ] && [ "${ORD_COUNT}" = "15" ]; then
  echo "==> [DynamoDB] PASS — all counts match."
else
  echo "==> [DynamoDB] FAIL — count mismatch!"
  exit 1
fi
