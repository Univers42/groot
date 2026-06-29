#!/usr/bin/env bash
# ============================================================
# load-postgres.sh  [csv-dir]
# ============================================================
# Load the shop-sample dataset into Postgres (mini-baas-postgres)
# into a scratch database called learn_shop.
#
# Docker-only: all DB commands run inside the container via
# `docker exec`.  No host psql required.
#
# Safe to re-run: DROPs and re-creates learn_shop each time.
# After the load, prints row counts (8 / 6 / 15) and a
# sample JOIN across all three tables.
#
# Usage:
#   bash load-postgres.sh                         # uses ../shop-sample
#   bash load-postgres.sh /path/to/csv-dir
#
# Requires: mini-baas-postgres container running (part of `make all`).
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV_DIR="${1:-${SCRIPT_DIR}/../shop-sample}"
CSV_DIR="$(cd "${CSV_DIR}" && pwd)"

CONTAINER="mini-baas-postgres"
DB="learn_shop"

echo "==> [Postgres] CSV source : ${CSV_DIR}"
echo "==> [Postgres] Target DB  : ${DB}"
echo ""

# ── 1. Drop and recreate the scratch database ──────────────────────────────
echo "--- drop + create ${DB} ---"
docker exec "${CONTAINER}" sh -lc "
  psql -U \"\$POSTGRES_USER\" -d postgres \
    -c \"DROP DATABASE IF EXISTS ${DB};\" \
    -c \"CREATE DATABASE ${DB};\"
"

# ── 2. Create schema ───────────────────────────────────────────────────────
echo "--- create schema ---"
docker exec -i "${CONTAINER}" sh -lc "psql -U \"\$POSTGRES_USER\" -d ${DB} -q" <<'SQL'
CREATE TABLE customers (
  id          INTEGER     PRIMARY KEY,
  name        TEXT        NOT NULL,
  email       TEXT        NOT NULL UNIQUE,
  created_at  DATE        NOT NULL
);

CREATE TABLE products (
  id          INTEGER     PRIMARY KEY,
  name        TEXT        NOT NULL,
  price_cents INTEGER     NOT NULL CHECK (price_cents >= 0),
  stock       INTEGER     NOT NULL DEFAULT 0
);

CREATE TABLE orders (
  id          INTEGER     PRIMARY KEY,
  customer_id INTEGER     NOT NULL REFERENCES customers(id),
  product_id  INTEGER     NOT NULL REFERENCES products(id),
  qty         INTEGER     NOT NULL CHECK (qty > 0),
  status      TEXT        NOT NULL
                          CHECK (status IN ('pending','paid','shipped','cancelled')),
  created_at  DATE        NOT NULL
);
SQL

# ── 3. Import CSVs via \copy FROM STDIN (client-side, no server file access)
echo "--- import customers (8 rows expected) ---"
docker exec -i "${CONTAINER}" sh -lc \
  "psql -U \"\$POSTGRES_USER\" -d ${DB} -q -c \"\copy customers FROM STDIN WITH (FORMAT csv, HEADER true)\"" \
  <"${CSV_DIR}/customers.csv"

echo "--- import products (6 rows expected) ---"
docker exec -i "${CONTAINER}" sh -lc \
  "psql -U \"\$POSTGRES_USER\" -d ${DB} -q -c \"\copy products FROM STDIN WITH (FORMAT csv, HEADER true)\"" \
  <"${CSV_DIR}/products.csv"

echo "--- import orders (15 rows expected) ---"
docker exec -i "${CONTAINER}" sh -lc \
  "psql -U \"\$POSTGRES_USER\" -d ${DB} -q -c \"\copy orders FROM STDIN WITH (FORMAT csv, HEADER true)\"" \
  <"${CSV_DIR}/orders.csv"

# ── 4. Verify ──────────────────────────────────────────────────────────────
echo ""
echo "--- verification ---"
docker exec -i "${CONTAINER}" sh -lc "psql -U \"\$POSTGRES_USER\" -d ${DB}" <<'SQL'
SELECT 'customers' AS "table", COUNT(*) AS rows FROM customers
UNION ALL
SELECT 'products',  COUNT(*) FROM products
UNION ALL
SELECT 'orders',    COUNT(*) FROM orders;

SELECT c.name AS customer, p.name AS product, o.qty, o.status
FROM   orders    o
JOIN   customers c ON c.id = o.customer_id
JOIN   products  p ON p.id = o.product_id
WHERE  o.status = 'shipped'
ORDER  BY o.id
LIMIT  5;
SQL

echo ""
echo "==> [Postgres] learn_shop loaded successfully."
