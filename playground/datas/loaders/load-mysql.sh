#!/usr/bin/env bash
# ============================================================
# load-mysql.sh  [csv-dir]
# ============================================================
# Load the shop-sample dataset into MariaDB 11.4 (mini-baas-mariadb)
# into a scratch database called learn_shop.
#
# Docker-only: all DB commands run inside the container via
# `docker exec`.  No host mariadb/mysql client required.
# Credentials are resolved from the container's own env at runtime.
#
# Safe to re-run: DROPs and re-creates learn_shop each time.
# After the load, prints row counts (8 / 6 / 15) and a
# sample JOIN across all three tables.
#
# Usage:
#   bash load-mysql.sh                         # uses ../shop-sample
#   bash load-mysql.sh /path/to/csv-dir
#
# Requires: mini-baas-mariadb container running (part of `make all`).
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV_DIR="${1:-${SCRIPT_DIR}/../shop-sample}"
CSV_DIR="$(cd "${CSV_DIR}" && pwd)"

CONTAINER="mini-baas-mariadb"
DB="learn_shop"

echo "==> [MariaDB] CSV source : ${CSV_DIR}"
echo "==> [MariaDB] Target DB  : ${DB}"
echo ""

# ── Helper: generate INSERT statements from a CSV file ──────────────────────
# No embedded commas or quotes in the shop-sample data, so plain awk is fine.
# \047 = single-quote (octal) avoids shell-quoting tangles inside awk.

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
docker exec -i "${CONTAINER}" sh -lc \
  'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"' <<SQL
DROP DATABASE IF EXISTS ${DB};
CREATE DATABASE ${DB}
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;
SQL

# ── 2. Create schema ───────────────────────────────────────────────────────
echo "--- create schema ---"
docker exec -i "${CONTAINER}" sh -lc \
  "mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" ${DB}" <<'SQL'
CREATE TABLE customers (
  id          INT          NOT NULL PRIMARY KEY,
  name        VARCHAR(255) NOT NULL,
  email       VARCHAR(255) NOT NULL UNIQUE,
  created_at  DATE         NOT NULL
) ENGINE=InnoDB;

CREATE TABLE products (
  id          INT          NOT NULL PRIMARY KEY,
  name        VARCHAR(255) NOT NULL,
  price_cents INT          NOT NULL CHECK (price_cents >= 0),
  stock       INT          NOT NULL DEFAULT 0
) ENGINE=InnoDB;

CREATE TABLE orders (
  id          INT          NOT NULL PRIMARY KEY,
  customer_id INT          NOT NULL,
  product_id  INT          NOT NULL,
  qty         INT          NOT NULL CHECK (qty > 0),
  status      ENUM('pending','paid','shipped','cancelled') NOT NULL,
  created_at  DATE         NOT NULL,
  FOREIGN KEY (customer_id) REFERENCES customers(id),
  FOREIGN KEY (product_id)  REFERENCES products(id)
) ENGINE=InnoDB;
SQL

# ── 3. Import via generated INSERTs ────────────────────────────────────────
echo "--- import customers (8 rows expected) ---"
{
  inserts_customers "${CSV_DIR}/customers.csv"
} | docker exec -i "${CONTAINER}" sh -lc "mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" ${DB}"

echo "--- import products (6 rows expected) ---"
{
  inserts_products "${CSV_DIR}/products.csv"
} | docker exec -i "${CONTAINER}" sh -lc "mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" ${DB}"

echo "--- import orders (15 rows expected) ---"
{
  inserts_orders "${CSV_DIR}/orders.csv"
} | docker exec -i "${CONTAINER}" sh -lc "mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" ${DB}"

# ── 4. Verify ──────────────────────────────────────────────────────────────
echo ""
echo "--- verification ---"
docker exec -i "${CONTAINER}" sh -lc \
  "mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" ${DB} --table" <<'SQL'
SELECT 'customers' AS `table`, COUNT(*) AS `rows` FROM customers
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
echo "==> [MariaDB] learn_shop loaded successfully."
