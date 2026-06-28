# 03 — Indexes

Indexes let CockroachDB satisfy queries without scanning every row. Because CockroachDB is distributed, index choice also affects which **ranges** (data shards) a query must contact — making index design a distributed-systems concern, not just a local I/O concern.

## Setup

```bash
docker exec mini-baas-cockroach cockroach sql --insecure \
  -e "CREATE DATABASE IF NOT EXISTS learn_cli;"
```

Create the shop schema from [01-crud.md](01-crud.md) and seed some rows before running the EXPLAIN examples below.

## Secondary index

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
CREATE INDEX idx_orders_status ON orders (status);
"
```

CockroachDB creates all indexes online (no table lock). The index is available immediately but may be built in the background for large tables.

## UNIQUE index

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
CREATE UNIQUE INDEX idx_customers_email ON customers (email);
"
```

`UNIQUE` indexes enforce a constraint in addition to accelerating lookups.

## Composite index

Order matters: the index supports queries that filter on `(customer_id)` alone or `(customer_id, status)` together, but **not** `(status)` alone (leftmost-prefix rule, same as Postgres).

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
CREATE INDEX idx_orders_customer_status ON orders (customer_id, status);
"
```

## STORING (covering index) — CockroachDB-specific

A `STORING` clause embeds extra columns in the index leaf, so CockroachDB can answer the query entirely from the index without a secondary KV lookup (index join) back to the primary.

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
CREATE INDEX idx_orders_customer ON orders (customer_id) STORING (qty, status);
"
```

Now a query for `SELECT qty, status FROM orders WHERE customer_id = $1` reads only the index, never the primary range. EXPLAIN will show no `index join` step.

## Inverted (GIN) index for JSONB

If your table has a `JSONB` column, create an inverted index to enable `@>`, `?`, `?|`, `?&` operators efficiently.

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
CREATE TABLE IF NOT EXISTS product_meta (
  id         UUID  PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID  REFERENCES products(id),
  attrs      JSONB
);

CREATE INVERTED INDEX idx_product_meta_attrs ON product_meta (attrs);
"
```

Query example:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
SELECT id FROM product_meta WHERE attrs @> '{\"color\": \"red\"}';
"
```

## Hash-sharded index — avoiding sequential hotspots

When a primary key is sequential (e.g., `unique_rowid()`, timestamps), all new inserts land on the same trailing range — a write hotspot. A hash-sharded PK distributes inserts across `bucket_count` shards:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
CREATE TABLE IF NOT EXISTS events (
  id         INT          NOT NULL DEFAULT unique_rowid(),
  event_type STRING,
  ts         TIMESTAMPTZ  DEFAULT now(),
  PRIMARY KEY (id) USING HASH WITH (bucket_count = 8)
);
"
```

The optimizer transparently routes queries; applications see a normal integer PK. Use this pattern for high-ingest tables with sequential keys. UUID PKs avoid the hotspot naturally and don't need hashing.

## Listing indexes

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
SHOW INDEXES FROM orders;
"
```

```
table_name  index_name            non_unique  seq_in_index  column_name  storing  implicit
orders      idx_orders_customer   t           1             customer_id  f        f
orders      idx_orders_customer   t           2             qty          t        f
orders      idx_orders_customer   t           3             status       t        f
orders      orders_pkey           f           1             id           f        f
```

`storing = t` means the column is stored in the index leaf (not indexed for sorting).

## EXPLAIN — understanding query plans

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
EXPLAIN SELECT * FROM orders WHERE status = 'shipped';
"
```

```
info
distribution: local
vectorized: true

• index join
│ table: orders@orders_pkey
│
└── • scan
      table: orders@idx_orders_status
      spans: [/'shipped' - /'shipped']
```

The `index join` step means the optimizer found the matching rows in `idx_orders_status` but then had to look up the full row in the primary (`orders_pkey`). Adding a `STORING (customer_id, product_id, qty, created_at)` to `idx_orders_status` would eliminate that join.

CockroachDB also surfaces **index recommendations** in EXPLAIN output when it detects a better index would help.

## EXPLAIN ANALYZE — runtime statistics

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
EXPLAIN ANALYZE
SELECT c.name, COUNT(o.id) AS order_count
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.id
GROUP BY c.name;
"
```

`EXPLAIN ANALYZE` actually executes the query and returns real row counts, KV bytes read, and CPU time alongside the plan. Use it to confirm that your index is actually used.

## DROP INDEX

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
DROP INDEX idx_orders_status;
"
```

Index data is reclaimed asynchronously (background GC). You may see a `NOTICE` about this.

## Scenario: speeding up the order dashboard

The dashboard query joins `orders`, `customers`, and `products` and filters by `status = 'shipped'`. Without an index, every query is a full scan of `orders`.

```bash
# Step 1: see the plan before indexing
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
EXPLAIN SELECT o.id, c.name, p.name AS product, o.qty
FROM orders o
JOIN customers c ON c.id = o.customer_id
JOIN products  p ON p.id = o.product_id
WHERE o.status = 'shipped';
"

# Step 2: create a covering index
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
CREATE INDEX idx_orders_shipped
ON orders (status)
STORING (customer_id, product_id, qty);
"

# Step 3: re-check the plan — index join should disappear or simplify
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
EXPLAIN SELECT o.id, c.name, p.name AS product, o.qty
FROM orders o
JOIN customers c ON c.id = o.customer_id
JOIN products  p ON p.id = o.product_id
WHERE o.status = 'shipped';
"
```

## Cleanup

```bash
docker exec mini-baas-cockroach cockroach sql --insecure \
  -e "DROP DATABASE learn_cli CASCADE;"
```

## Gotchas / Docker notes

- **`STORING` vs `INCLUDE` (Postgres).** Functionally the same concept; CockroachDB spells it `STORING`, Postgres spells it `INCLUDE`.
- **Index-join cost.** CockroachDB prefers an index scan + index join over a full table scan when the index is selective. STORING eliminates the join; use it for columns that appear in `SELECT` but not in `WHERE`/`ORDER BY`.
- **Inverted index required for JSONB.** A regular B-tree index on a JSONB column won't accelerate `@>` / `?` operators — you need `CREATE INVERTED INDEX`.
- **Hash-sharded indexes store a hidden `crdb_internal_...` shard column.** It is transparent to queries but visible in `SHOW INDEXES`.
- **`DROP INDEX` is non-blocking** — the index is removed online and storage is reclaimed later.

---

← [02-views.md](02-views.md) | [04-users-roles.md](04-users-roles.md) →
