# Indexes

After this file you can create the right index for a given query pattern, explain why small
tables do not use indexes, read `EXPLAIN ANALYZE` output to confirm index use, and recognize
when indexes hurt rather than help.

## Prerequisite

The `learn_cli` database must exist and contain the shop schema with data (see
[01-crud.md](01-crud.md)).

## Why indexes exist

Without an index, PostgreSQL reads every row of a table — a sequential scan (Seq Scan).
An index is a sorted data structure maintained alongside the table that lets the engine jump
directly to matching rows. The trade-off: indexes consume disk space and slow down writes
because they must be kept in sync on every INSERT, UPDATE, and DELETE.

## B-tree index (default)

B-tree is the default and covers `=`, `<`, `<=`, `>`, `>=`, `BETWEEN`, `LIKE 'prefix%'`.

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE INDEX idx_orders_customer_id ON orders(customer_id);"'
```

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE INDEX idx_orders_status ON orders(status);"'
```

## UNIQUE index

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE UNIQUE INDEX idx_customers_email ON customers(email);"'
```

A `UNIQUE` constraint (`UNIQUE` column definition or `ADD CONSTRAINT`) implicitly creates a
unique index. Creating one explicitly with `CREATE UNIQUE INDEX` gives you a named index you
can reference in `ON CONFLICT` clauses.

## Composite (multicolumn) index

Index on `(status, created_at DESC)` serves queries that filter by `status` and sort by
`created_at`:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE INDEX idx_orders_status_created ON orders(status, created_at DESC);"'
```

Column order matters: the leading column `status` can be used alone. The second column
`created_at` is only useful when `status` is also in the WHERE clause.

## Partial index — index only a subset of rows

Index only paid orders (smaller, faster for that specific query):

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE INDEX idx_orders_paid ON orders(customer_id) WHERE status = '"'"'paid'"'"';"'
```

Use partial indexes when a query always includes a fixed WHERE condition and the subset is
much smaller than the full table.

## Expression index

Index the lower-cased email so case-insensitive lookups use an index:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE INDEX idx_customers_email_lower ON customers(lower(email));"'
```

```bash
# This query now uses the index:
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
SELECT id, name FROM customers WHERE lower(email) = '"'"'alice@example.com'"'"';"'
```

The WHERE expression must match the index expression exactly for the planner to pick it up.

## GIN for JSONB and full-text search (note)

GIN (Generalized Inverted Index) is designed for multi-valued data types. You would use it
for JSONB columns or `tsvector` full-text search, not B-tree point lookups.

```sql
-- pattern (not verified here — learn_cli has no JSONB column)
CREATE INDEX idx_meta_gin ON products USING gin(metadata);
```

## Listing indexes

```bash
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d learn_cli -c "\di"'
```

```
                         List of relations
 Schema |           Name            | Type  |  Owner   |   Table
--------+---------------------------+-------+----------+-----------
 public | customers_email_key       | index | postgres | customers
 public | customers_pkey            | index | postgres | customers
 public | idx_customers_email       | index | postgres | customers
 public | idx_customers_email_lower | index | postgres | customers
 public | idx_orders_customer_id    | index | postgres | orders
 public | idx_orders_paid           | index | postgres | orders
 public | idx_orders_status         | index | postgres | orders
 public | idx_orders_status_created | index | postgres | orders
 public | orders_pkey               | index | postgres | orders
 public | products_pkey             | index | postgres | products
```

Or with SQL for scriptable output:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename IN ('"'"'orders'"'"', '"'"'customers'"'"')
ORDER BY indexname;"'
```

## EXPLAIN and EXPLAIN ANALYZE

`EXPLAIN` shows the query plan (estimated costs). `EXPLAIN ANALYZE` executes the query and
shows actual timings — use it on `learn_cli`, never on production without understanding the
impact (it runs the query for real).

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
EXPLAIN SELECT * FROM orders WHERE status = '"'"'paid'"'"' AND customer_id = 1;"'
```

```
                        QUERY PLAN
-----------------------------------------------------------
 Seq Scan on orders  (cost=0.00..1.06 rows=1 width=68)
   Filter: ((status = 'paid'::text) AND (customer_id = 1))
```

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
EXPLAIN ANALYZE SELECT * FROM orders WHERE status = '"'"'paid'"'"' AND customer_id = 1;"'
```

```
                                           QUERY PLAN
-------------------------------------------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..1.06 rows=1 width=68) (actual time=0.017..0.018 rows=2 loops=1)
   Filter: ((status = 'paid'::text) AND (customer_id = 1))
   Rows Removed by Filter: 2
 Planning Time: 1.181 ms
 Execution Time: 0.057 ms
```

### Why is it doing a Seq Scan even though we have indexes?

The table has only 4 rows. PostgreSQL's planner estimates that reading the index, then
fetching heap pages for 4 rows, costs *more* than a single sequential pass over 4 rows.
This is correct — indexes pay off at scale (typically thousands of rows and above). Do not
add indexes prematurely to tiny tables.

To force an index scan for testing (not for production):

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
SET enable_seqscan = off;
EXPLAIN SELECT * FROM orders WHERE status = '"'"'paid'"'"' AND customer_id = 1;
RESET enable_seqscan;"'
```

## DROP INDEX

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
DROP INDEX IF EXISTS idx_customers_email_lower;"'
```

`IF EXISTS` prevents errors in scripts that may run repeatedly.

## Scenario: finding slow queries

```bash
# Step 1: run EXPLAIN ANALYZE on a join to see which path the planner chose
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
EXPLAIN ANALYZE
SELECT c.name, COUNT(o.id)
FROM orders o
JOIN customers c ON c.id = o.customer_id
WHERE o.status = '"'"'paid'"'"'
GROUP BY c.name;"'

# Step 2: if you see a Seq Scan on a large table, add a targeted index
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE INDEX idx_orders_status_paid ON orders(status) WHERE status = '"'"'paid'"'"';"'

# Step 3: re-run EXPLAIN ANALYZE and confirm the plan changed
```

## When NOT to index

| Situation | Why indexes hurt here |
|-----------|-----------------------|
| Very small tables (< ~1 000 rows) | Sequential scan is faster; planner ignores indexes |
| Columns with very low cardinality (e.g., a boolean) | Index not selective enough to help |
| Columns that are only written, never queried | Write overhead with no read benefit |
| Bulk-load tables | Disable indexes, load data, rebuild — much faster |
| Columns already covered by a broader composite index | Redundant; wastes space |

## Gotchas / Docker notes

- **Indexes do not enforce data integrity by themselves** (except UNIQUE). Use CHECK
  constraints and FK constraints for that.
- **`CREATE INDEX` blocks writes by default** in PostgreSQL (takes a ShareLock). Use
  `CREATE INDEX CONCURRENTLY` on live production databases to avoid locking.
- **`CREATE INDEX CONCURRENTLY` cannot run inside a transaction block.** The standard
  `BEGIN; ... CREATE INDEX CONCURRENTLY; COMMIT;` will fail.
- **Partial index conditions must exactly match queries**: `WHERE status = 'paid'` in the
  index is only used when the query also has `WHERE status = 'paid'`, not `status = 'PAID'`.
- **Expression indexes require the exact same expression**: `lower(email)` in the index is
  used only when the WHERE clause says `lower(email) = '...'`.

---

Previous: [02-views.md](02-views.md) | Next: [04-users-roles.md](04-users-roles.md)
