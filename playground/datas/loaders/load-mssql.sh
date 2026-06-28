#!/usr/bin/env bash
# ============================================================
# load-mssql.sh  [csv-dir]
# ============================================================
# Load the shop-sample dataset into SQL Server 2022 (mini-baas-mssql)
# into a scratch database called learn_shop.
#
# Docker-only: all DB commands run inside the container via
# `docker exec`.  No host sqlcmd required.
# Credentials are resolved from the container's own env at runtime.
#
# Safe to re-run: DROPs and re-creates learn_shop each time.
# After the load, prints row counts (8 / 6 / 15) and a
# sample JOIN across all three tables.
#
# MSSQL notes:
#   - sqlcmd requires -C (trust server certificate) for local dev
#   - SQL batches are separated by GO
#   - No IDENTITY on id columns — we insert explicit values
#   - status is NVARCHAR(20) with a CHECK constraint (no ENUM type)
#   - TOP n instead of LIMIT n
#
# Usage:
#   bash load-mssql.sh                         # uses ../shop-sample
#   bash load-mssql.sh /path/to/csv-dir
#
# Requires: mini-baas-mssql container running (part of `make all`).
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV_DIR="${1:-${SCRIPT_DIR}/../shop-sample}"
CSV_DIR="$(cd "${CSV_DIR}" && pwd)"

CONTAINER="mini-baas-mssql"
DB="learn_shop"

echo "==> [SQL Server] CSV source : ${CSV_DIR}"
echo "==> [SQL Server] Target DB  : ${DB}"
echo ""

# ── Helper: sqlcmd wrapper — pipe SQL via stdin ────────────────────────────
run_sql() {
  # Reads SQL from stdin, executes via sqlcmd in the container.
  # -b  : abort batch on error
  # -C  : trust server certificate
  docker exec -i "${CONTAINER}" sh -lc \
    'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b'
}

# ── Helper: generate INSERT statements from a CSV file ──────────────────────
# \047 = single-quote (octal) avoids shell-quoting issues in awk.

inserts_customers() {
  awk -F',' 'NR>1 {
    gsub(/\r/, "", $NF)
    printf "INSERT INTO customers (id, name, email, created_at) VALUES (%d, N\047%s\047, N\047%s\047, \047%s\047);\n",
      $1, $2, $3, $4
  }' "$1"
}

inserts_products() {
  awk -F',' 'NR>1 {
    gsub(/\r/, "", $NF)
    printf "INSERT INTO products (id, name, price_cents, stock) VALUES (%d, N\047%s\047, %d, %d);\n",
      $1, $2, $3, $4
  }' "$1"
}

inserts_orders() {
  awk -F',' 'NR>1 {
    gsub(/\r/, "", $NF)
    printf "INSERT INTO orders (id, customer_id, product_id, qty, status, created_at) VALUES (%d, %d, %d, %d, N\047%s\047, \047%s\047);\n",
      $1, $2, $3, $4, $5, $6
  }' "$1"
}

# ── 1. Drop and recreate the scratch database ──────────────────────────────
echo "--- drop + create ${DB} ---"
run_sql <<SQL
USE master;
GO
IF EXISTS (SELECT name FROM sys.databases WHERE name = N'${DB}')
BEGIN
    ALTER DATABASE ${DB} SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE ${DB};
END
GO
CREATE DATABASE ${DB};
GO
SQL

# ── 2. Create schema ───────────────────────────────────────────────────────
echo "--- create schema ---"
run_sql <<'SQL'
USE learn_shop;
GO

CREATE TABLE customers (
  id          INT            NOT NULL PRIMARY KEY,
  name        NVARCHAR(255)  NOT NULL,
  email       NVARCHAR(255)  NOT NULL UNIQUE,
  created_at  DATE           NOT NULL
);
GO

CREATE TABLE products (
  id          INT            NOT NULL PRIMARY KEY,
  name        NVARCHAR(255)  NOT NULL,
  price_cents INT            NOT NULL CHECK (price_cents >= 0),
  stock       INT            NOT NULL DEFAULT 0
);
GO

CREATE TABLE orders (
  id          INT            NOT NULL PRIMARY KEY,
  customer_id INT            NOT NULL REFERENCES customers(id),
  product_id  INT            NOT NULL REFERENCES products(id),
  qty         INT            NOT NULL CHECK (qty > 0),
  status      NVARCHAR(20)   NOT NULL
                             CHECK (status IN ('pending','paid','shipped','cancelled')),
  created_at  DATE           NOT NULL
);
GO
SQL

# ── 3. Import via generated INSERTs ────────────────────────────────────────
echo "--- import customers (8 rows expected) ---"
{
  printf 'USE %s;\nGO\n' "${DB}"
  inserts_customers "${CSV_DIR}/customers.csv"
  printf 'GO\n'
} | run_sql

echo "--- import products (6 rows expected) ---"
{
  printf 'USE %s;\nGO\n' "${DB}"
  inserts_products "${CSV_DIR}/products.csv"
  printf 'GO\n'
} | run_sql

echo "--- import orders (15 rows expected) ---"
{
  printf 'USE %s;\nGO\n' "${DB}"
  inserts_orders "${CSV_DIR}/orders.csv"
  printf 'GO\n'
} | run_sql

# ── 4. Verify ──────────────────────────────────────────────────────────────
echo ""
echo "--- verification ---"
run_sql <<'SQL'
USE learn_shop;
GO

SELECT 'customers' AS [table], COUNT(*) AS rows FROM customers
UNION ALL
SELECT 'products',  COUNT(*) FROM products
UNION ALL
SELECT 'orders',    COUNT(*) FROM orders;
GO

SELECT TOP 5
  c.name  AS customer,
  p.name  AS product,
  o.qty,
  o.status
FROM   orders    o
JOIN   customers c ON c.id = o.customer_id
JOIN   products  p ON p.id = o.product_id
WHERE  o.status = 'shipped'
ORDER  BY o.id;
GO
SQL

echo ""
echo "==> [SQL Server] learn_shop loaded successfully."
