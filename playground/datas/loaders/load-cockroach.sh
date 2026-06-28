#!/usr/bin/env bash
# ============================================================
# load-cockroach.sh  [csv-dir]
# ============================================================
# Load the shop-sample dataset into CockroachDB v24.3
# (mini-baas-cockroach) into a scratch database called learn_shop.
#
# Docker-only: all DB commands run inside the container via
# `docker exec`.  No host cockroach client required.
# CockroachDB is PostgreSQL-compatible; the schema mirrors Postgres
# except that ids are plain INT (not SERIAL) since we insert
# explicit values from the CSVs.
#
# Safe to re-run: DROPs and re-creates learn_shop each time.
# After the load, prints row counts (8 / 6 / 15) and a
# sample JOIN across all three tables.
#
# Usage:
#   bash load-cockroach.sh                         # uses ../shop-sample
#   bash load-cockroach.sh /path/to/csv-dir
#
# Requires: mini-baas-cockroach container running (part of `make all`).
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV_DIR="${1:-${SCRIPT_DIR}/../shop-sample}"
CSV_DIR="$(cd "${CSV_DIR}" && pwd)"

CONTAINER="mini-baas-cockroach"
DB="learn_shop"

echo "==> [CockroachDB] CSV source : ${CSV_DIR}"
echo "==> [CockroachDB] Target DB  : ${DB}"
echo ""

# ── Helper: cockroach sql wrapper — pipe SQL via stdin ─────────────────────
run_sql() {
  # -d flag sets the database; use "defaultdb" for DB-level DDL.
  local db_arg="${1:-${DB}}"
  docker exec -i "${CONTAINER}" cockroach sql --insecure -d "${db_arg}"
}

# ── Helper: generate INSERT statements from a CSV file ──────────────────────
# \047 = single-quote (octal) avoids shell-quoting issues in awk.

inserts_customers() {
  awk -F',' 'NR>1 {
    gsub(/\r/, "", $NF)
    printf "INSERT INTO customers (id, name, email, created_at) VALUES (%d, \047%s\047, \047%s\047, \047%s\047);\n",
      $1, $2, $3, $4
  }' "$1"
}

inserts_products() {
  awk -F',' 'NR>1 {
    gsub(/\r/, "", $NF)
    printf "INSERT INTO products (id, name, price_cents, stock) VALUES (%d, \047%s\047, %d, %d);\n",
      $1, $2, $3, $4
  }' "$1"
}

inserts_orders() {
  awk -F',' 'NR>1 {
    gsub(/\r/, "", $NF)
    printf "INSERT INTO orders (id, customer_id, product_id, qty, status, created_at) VALUES (%d, %d, %d, %d, \047%s\047, \047%s\047);\n",
      $1, $2, $3, $4, $5, $6
  }' "$1"
}

# ── 1. Drop and recreate the scratch database ──────────────────────────────
echo "--- drop + create ${DB} ---"
docker exec "${CONTAINER}" cockroach sql --insecure \
  -e "DROP DATABASE IF EXISTS ${DB} CASCADE;" \
  -e "CREATE DATABASE ${DB};"

# ── 2. Create schema ───────────────────────────────────────────────────────
echo "--- create schema ---"
run_sql <<'SQL'
CREATE TABLE customers (
  id          INT         PRIMARY KEY,
  name        TEXT        NOT NULL,
  email       TEXT        NOT NULL UNIQUE,
  created_at  DATE        NOT NULL
);

CREATE TABLE products (
  id          INT         PRIMARY KEY,
  name        TEXT        NOT NULL,
  price_cents INT         NOT NULL CHECK (price_cents >= 0),
  stock       INT         NOT NULL DEFAULT 0
);

CREATE TABLE orders (
  id          INT         PRIMARY KEY,
  customer_id INT         NOT NULL REFERENCES customers(id),
  product_id  INT         NOT NULL REFERENCES products(id),
  qty         INT         NOT NULL CHECK (qty > 0),
  status      TEXT        NOT NULL
                          CHECK (status IN ('pending','paid','shipped','cancelled')),
  created_at  DATE        NOT NULL
);
SQL

# ── 3. Import via generated INSERTs ────────────────────────────────────────
echo "--- import customers (8 rows expected) ---"
inserts_customers "${CSV_DIR}/customers.csv" | run_sql

echo "--- import products (6 rows expected) ---"
inserts_products "${CSV_DIR}/products.csv" | run_sql

echo "--- import orders (15 rows expected) ---"
inserts_orders "${CSV_DIR}/orders.csv" | run_sql

# ── 4. Verify ──────────────────────────────────────────────────────────────
echo ""
echo "--- verification ---"
run_sql <<'SQL'
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
echo "==> [CockroachDB] learn_shop loaded successfully."
