# 01 — CRUD in SQL Server

Create, read, update, and delete data in SQL Server using `sqlcmd` inside Docker, against
the `learn_cli` scratch database with the shop schema.

## CREATE TABLE

SQL Server primary keys use `IDENTITY(1,1)` for auto-increment integers. The first argument
is the seed (starting value) and the second is the increment.

```bash
# customers table
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
CREATE TABLE customers (
  id         INT            IDENTITY(1,1) PRIMARY KEY,
  name       NVARCHAR(100)  NOT NULL,
  email      NVARCHAR(254)  NOT NULL UNIQUE,
  created_at DATETIME2      DEFAULT SYSUTCDATETIME()
)"'
```

```bash
# products table
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
CREATE TABLE products (
  id          INT            IDENTITY(1,1) PRIMARY KEY,
  name        NVARCHAR(200)  NOT NULL,
  price_cents INT            NOT NULL CHECK (price_cents >= 0),
  stock       INT            NOT NULL DEFAULT 0
)"'
```

```bash
# orders table — foreign keys reference customers and products
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
CREATE TABLE orders (
  id          INT            IDENTITY(1,1) PRIMARY KEY,
  customer_id INT            NOT NULL REFERENCES customers(id),
  product_id  INT            NOT NULL REFERENCES products(id),
  qty         INT            NOT NULL DEFAULT 1,
  status      NVARCHAR(20)   NOT NULL DEFAULT '"'"'pending'"'"',
  created_at  DATETIME2      DEFAULT SYSUTCDATETIME()
)"'
```

### Key types to know

| T-SQL type | Use for |
|-----------|---------|
| `INT` | 32-bit integer |
| `BIGINT` | 64-bit integer |
| `DECIMAL(p,s)` | Exact decimal (e.g. `DECIMAL(10,2)` for money) |
| `NVARCHAR(n)` | Unicode variable-length string (prefer over `VARCHAR` for any user content) |
| `DATETIME2` | Recommended datetime (fractional seconds, wider range than `DATETIME`) |
| `BIT` | Boolean (0/1) |

Use `NVARCHAR` over `VARCHAR` for any column that might hold non-ASCII characters.
Use `DATETIME2` over `DATETIME` for all new tables.

## INSERT

### Single and multi-row insert

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
INSERT INTO customers (name, email) VALUES
  ('"'"'Alice Martin'"'"', '"'"'alice@example.com'"'"'),
  ('"'"'Bob Durand'"'"',   '"'"'bob@example.com'"'"'),
  ('"'"'Carol Petit'"'"',  '"'"'carol@example.com'"'"')"'

docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
INSERT INTO products (name, price_cents, stock) VALUES
  ('"'"'Keyboard'"'"', 7999, 50),
  ('"'"'Mouse'"'"',    3499, 120)"'
```

### OUTPUT clause — see what was inserted

The `OUTPUT` clause echoes the inserted (or deleted/updated) rows. Unlike PostgreSQL's
`RETURNING`, it is placed between `INTO ... VALUES` and uses the `inserted` pseudo-table.

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
INSERT INTO orders (customer_id, product_id, qty, status)
OUTPUT inserted.id, inserted.customer_id, inserted.status, inserted.created_at
VALUES (1, 1, 1, '"'"'confirmed'"'"'),
       (2, 2, 2, '"'"'pending'"'"')"'
```

Expected output:

```
id          customer_id status               created_at
----------- ----------- -------------------- ---------------------------
          1           1 confirmed            2026-06-28 10:27:02.0826704
          2           2 pending              2026-06-28 10:27:02.0826704
```

`OUTPUT` works with `UPDATE` and `DELETE` too, using `inserted.*` (new values) and
`deleted.*` (old values).

## SELECT

### Basic WHERE and ORDER BY

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SELECT id, name, price_cents, stock
FROM   products
WHERE  stock > 50
ORDER  BY price_cents DESC"'
```

### JOIN and GROUP BY

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SELECT c.name                           AS customer,
       COUNT(o.id)                      AS total_orders,
       SUM(p.price_cents * o.qty)       AS total_cents
FROM   orders    o
JOIN   customers c ON c.id = o.customer_id
JOIN   products  p ON p.id = o.product_id
GROUP  BY c.name
ORDER  BY total_cents DESC"'
```

Expected:

```
customer     total_orders total_cents
------------ ------------ -----------
Alice Martin            1        7999
Bob Durand              1        6998
```

### Pagination with TOP and OFFSET…FETCH

`TOP` returns the first N rows — quick but not suited for page-N style pagination because
there is no "skip" concept:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SELECT TOP 2 name, email FROM customers ORDER BY id"'
```

`OFFSET … FETCH` is the SQL-standard approach for keyset/offset pagination:

```bash
# Page 2, 2 rows per page
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SELECT name, email
FROM   customers
ORDER  BY id
OFFSET 2 ROWS
FETCH  NEXT 2 ROWS ONLY"'
```

`ORDER BY` is mandatory with `OFFSET…FETCH`.

## UPDATE

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
UPDATE products
SET    price_cents = 8499,
       stock       = stock - 5
OUTPUT deleted.price_cents AS old_price, inserted.price_cents AS new_price
WHERE  name = '"'"'Keyboard'"'"'"'
```

`OUTPUT` with `UPDATE` gives you both the old (`deleted.*`) and new (`inserted.*`) values
in a single statement.

## DELETE

```bash
# Safe pattern: preview before delete
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SELECT id, name FROM customers WHERE email = '"'"'carol@example.com'"'"'"'

docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
DELETE FROM customers
OUTPUT deleted.id, deleted.name, deleted.email
WHERE  email = '"'"'carol@example.com'"'"'"'
```

Always scope DELETE with a WHERE clause. SQL Server has no `DELETE LIMIT`.
Use a CTE or a subquery if you need to limit rows deleted.

## UPSERT via MERGE

`MERGE` is SQL Server's UPSERT. It matches source rows to target rows and branches on
MATCHED / NOT MATCHED:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
MERGE products AS target
USING (VALUES ('"'"'Keyboard'"'"', 8999, 45),
              ('"'"'Headset'"'"',  5999, 30)) AS src (name, price_cents, stock)
  ON  target.name = src.name
WHEN MATCHED THEN
  UPDATE SET price_cents = src.price_cents,
             stock       = src.stock
WHEN NOT MATCHED THEN
  INSERT (name, price_cents, stock)
  VALUES (src.name, src.price_cents, src.stock);
SELECT name, price_cents, stock FROM products ORDER BY id"'
```

Expected (Keyboard updated, Headset inserted):

```
name      price_cents stock
--------- ----------- -----
Keyboard         8999    45
Mouse            3499   120
Headset          5999    30
```

## Scenario — restocking a low-stock product

A warehouse report flags any product with stock below 20. Restock it and confirm the change
in one round-trip:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
-- Find low-stock items
SELECT id, name, stock FROM products WHERE stock < 20;

-- Restock them, capturing old and new values
UPDATE products
SET    stock = stock + 100
OUTPUT deleted.name,
       deleted.stock AS before_restock,
       inserted.stock AS after_restock
WHERE  stock < 20"'
```

## Gotchas / Docker notes

- IDENTITY columns cannot be inserted to unless `SET IDENTITY_INSERT table ON` is active.
  Normally you omit `id` from your INSERT column list and let the server assign it.
- `NVARCHAR` literals must be prefixed with `N` inside T-SQL when the literal contains
  non-ASCII characters: `N'Ñoño'`. For pure ASCII values the `N` prefix is optional but harmless.
- `DATETIME2` has sub-microsecond precision. `DATETIME` is limited to 1/300-second resolution
  and has a narrower date range — avoid it in new tables.
- Shell quoting in one-liners: single quotes inside `sh -lc '...'` must be escaped as `'"'"'`.
  For queries with many string literals, use the `docker cp` + `sqlcmd -i` pattern instead.

---

Previous: [00-connect.md](00-connect.md) | Next: [02-views.md](02-views.md)
