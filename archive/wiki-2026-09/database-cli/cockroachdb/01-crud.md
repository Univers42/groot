# 01 — CRUD: Create, Read, Update, Delete

CockroachDB speaks PostgreSQL-compatible SQL. This file walks through the complete shop schema and the core DML statements, calling out places where CockroachDB behaves differently from a single-node Postgres.

## Setup: create the scratch database

```bash
docker exec mini-baas-cockroach cockroach sql --insecure \
  -e "CREATE DATABASE IF NOT EXISTS learn_cli;"
```

## CREATE TABLE — why UUID instead of SERIAL?

In a distributed database, each node generates primary keys independently. A `SERIAL` / `BIGSERIAL` column uses a cluster-wide sequence, which creates a write **hotspot**: all new rows hit the same range boundary. UUIDs spread new rows across ranges uniformly.

```sql
-- Run against learn_cli
CREATE TABLE customers (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name       STRING      NOT NULL,
  email      STRING      UNIQUE NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE products (
  id          UUID   PRIMARY KEY DEFAULT gen_random_uuid(),
  name        STRING NOT NULL,
  price_cents INT    NOT NULL CHECK (price_cents >= 0),
  stock       INT    NOT NULL DEFAULT 0 CHECK (stock >= 0)
);

CREATE TABLE orders (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID        NOT NULL REFERENCES customers(id),
  product_id  UUID        NOT NULL REFERENCES products(id),
  qty         INT         NOT NULL CHECK (qty > 0),
  status      STRING      NOT NULL DEFAULT 'pending',
  created_at  TIMESTAMPTZ DEFAULT now()
);
```

Run it as a one-shot:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
CREATE TABLE IF NOT EXISTS customers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name STRING NOT NULL,
  email STRING UNIQUE NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE TABLE IF NOT EXISTS products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name STRING NOT NULL,
  price_cents INT NOT NULL CHECK (price_cents >= 0),
  stock INT NOT NULL DEFAULT 0 CHECK (stock >= 0)
);
CREATE TABLE IF NOT EXISTS orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID NOT NULL REFERENCES customers(id),
  product_id  UUID NOT NULL REFERENCES products(id),
  qty INT NOT NULL CHECK (qty > 0),
  status STRING NOT NULL DEFAULT 'pending',
  created_at TIMESTAMPTZ DEFAULT now()
);
"
```

### CockroachDB type notes

| Use case | CockroachDB type | Postgres equivalent |
|---|---|---|
| Variable-length text | `STRING` | `TEXT` / `VARCHAR` |
| Date + time + tz | `TIMESTAMPTZ` | `TIMESTAMP WITH TIME ZONE` |
| UUID | `UUID` | `UUID` |
| Money (store as integer) | `INT` | `BIGINT` |
| JSON | `JSONB` | `JSONB` |

Both `STRING` and `TEXT` are accepted; they are aliases.

## INSERT — multi-row and RETURNING

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
INSERT INTO customers (name, email) VALUES
  ('Alice Martin', 'alice@example.com'),
  ('Bob Dupont',   'bob@example.com'),
  ('Carol Smith',  'carol@example.com')
RETURNING id, name;
"
```

```
id                                    name
cb430682-ac03-4dff-b240-f94ee3dcd78f  Alice Martin
7ce12764-2bbe-42f3-93c7-ce60263cb4f4  Bob Dupont
d43094a3-d4e5-4263-ae3d-ed7515ce342a  Carol Smith
```

`RETURNING` works on INSERT, UPDATE, and DELETE. It avoids a second round-trip to get generated values.

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
INSERT INTO products (name, price_cents, stock) VALUES
  ('Widget A',   999,  100),
  ('Gadget B',  4999,   25),
  ('Doohickey C', 199, 500)
RETURNING id, name, price_cents;
"
```

Use a `SELECT` subquery when you need to reference already-inserted rows by a unique field:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
INSERT INTO orders (customer_id, product_id, qty, status)
SELECT c.id, p.id, 2, 'pending'
FROM   customers c, products p
WHERE  c.email = 'alice@example.com'
  AND  p.name  = 'Widget A'
RETURNING id, qty, status;
"
```

## SELECT — WHERE, JOIN, GROUP BY, ORDER BY, LIMIT

Basic filter:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
SELECT id, name, stock FROM products WHERE price_cents < 1000 ORDER BY price_cents;
"
```

Join across three tables:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
SELECT o.id, c.name AS customer, p.name AS product, o.qty, o.status
FROM   orders o
JOIN   customers c ON c.id = o.customer_id
JOIN   products  p ON p.id = o.product_id
ORDER  BY o.created_at DESC
LIMIT  10;
"
```

Aggregation:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
SELECT p.name, SUM(o.qty) AS total_sold, SUM(o.qty * p.price_cents) AS revenue_cents
FROM   orders o
JOIN   products p ON p.id = o.product_id
GROUP  BY p.name
ORDER  BY revenue_cents DESC;
"
```

## UPDATE

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
UPDATE orders
SET    status = 'shipped'
WHERE  status = 'pending'
RETURNING id, status;
"
```

```
id                                    status
e827fa75-4361-4f64-bdb4-e4bd114d89f5  shipped
```

## DELETE

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
DELETE FROM customers
WHERE  email = 'carol@example.com'
RETURNING id, name;
"
```

Deleting a parent row that has child rows referencing it via FK will fail unless `ON DELETE CASCADE` was declared on the FK. By default, CockroachDB enforces FK constraints.

## UPSERT

CockroachDB has a first-class `UPSERT` statement: if the row exists (by PK or UNIQUE constraint), it updates; otherwise it inserts.

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
UPSERT INTO customers (id, name, email)
VALUES (gen_random_uuid(), 'Dave Lee', 'dave@example.com')
RETURNING id, name;
"
```

The explicit `INSERT ... ON CONFLICT` form gives you finer control — you can update only specific columns:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
INSERT INTO customers (name, email)
VALUES ('Alice Renamed', 'alice@example.com')
ON CONFLICT (email) DO UPDATE SET name = EXCLUDED.name
RETURNING id, name, email;
"
```

`EXCLUDED` refers to the row that would have been inserted. `DO NOTHING` is also valid to silently skip conflicts.

## Scenario: full order lifecycle

```bash
# 1. Insert a new customer and immediately capture their id
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
INSERT INTO customers (name, email)
VALUES ('Eve Torres', 'eve@example.com')
RETURNING id;
"

# 2. Place an order (using subquery to avoid hardcoding UUIDs)
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
INSERT INTO orders (customer_id, product_id, qty)
SELECT c.id, p.id, 3
FROM   customers c, products p
WHERE  c.email = 'eve@example.com'
  AND  p.name  = 'Gadget B';
"

# 3. Ship it
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
UPDATE orders SET status = 'shipped'
WHERE  customer_id = (SELECT id FROM customers WHERE email = 'eve@example.com')
RETURNING id, status;
"

# 4. Report
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
SELECT c.name, p.name AS product, o.qty, o.status
FROM   orders o
JOIN   customers c ON c.id = o.customer_id
JOIN   products  p ON p.id = o.product_id
WHERE  c.email = 'eve@example.com';
"
```

## Cleanup

```bash
docker exec mini-baas-cockroach cockroach sql --insecure \
  -e "DROP DATABASE learn_cli CASCADE;"
```

## Gotchas / Docker notes

- **RETURNING is not Postgres-exclusive.** CockroachDB supports it fully on INSERT/UPDATE/DELETE. Use it to avoid a second query.
- **`SERIAL` still works** but generates sequential IDs that create write hotspots in multi-range clusters. Prefer `UUID DEFAULT gen_random_uuid()` for any table that will grow large.
- **FK enforcement is immediate by default.** No deferred constraints unless you declare `DEFERRABLE INITIALLY DEFERRED`.
- **Schema changes are online.** `ALTER TABLE ... ADD COLUMN` does not lock the table; it runs as a background job. Check `SHOW JOBS;` to watch progress.
- **`UPSERT` uses the PK.** If your table has additional UNIQUE constraints, use `ON CONFLICT (col) DO UPDATE` to target the right conflict column.

---

← [00-connect.md](00-connect.md) | [02-views.md](02-views.md) →
