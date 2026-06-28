# Views and Materialized Views

After this file you can create regular views that simplify complex joins, add WITH CHECK OPTION
for safety on updatable views, and create materialized views for pre-computed snapshots that
you refresh on demand — and know which to reach for in different situations.

## Prerequisite

The `learn_cli` database must exist and contain the shop schema (see [01-crud.md](01-crud.md)).

## Regular views

A view is a named, stored query. It adds no storage — every `SELECT` on it re-runs the
underlying query live.

### CREATE OR REPLACE VIEW

`CREATE OR REPLACE` replaces an existing view's definition without needing to drop it first.
Use it to iterate on a view without breaking dependent objects.

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE OR REPLACE VIEW order_summary AS
SELECT o.id    AS order_id,
       c.name  AS customer,
       p.name  AS product,
       o.qty,
       o.status,
       (o.qty * p.price_cents) AS total_cents,
       o.created_at
FROM orders o
JOIN customers c ON c.id = o.customer_id
JOIN products  p ON p.id = o.product_id;"'
```

Query the view exactly like a table:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
SELECT * FROM order_summary ORDER BY order_id;"'
```

Expected:
```
 order_id |   customer   |  product  | qty | status  | total_cents |          created_at
----------+--------------+-----------+-----+---------+-------------+-------------------------------
        1 | Alice Martin | Notebook  |   2 | paid    |        2598 | 2026-06-28 10:28:31.530749+00
        2 | Alice Martin | Desk Lamp |   1 | paid    |        3999 | ...
        3 | Bob Chen     | Pen Set   |   5 | shipped |        2495 | ...
        4 | Carla Diaz   | Notebook  |   1 | shipped |        1299 | ...
```

Filter the view just like a table — PostgreSQL pushes the WHERE clause down:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
SELECT customer, SUM(total_cents) AS total
FROM order_summary
WHERE status = '"'"'paid'"'"'
GROUP BY customer;"'
```

### List views

```bash
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d learn_cli -c "\dv"'
```

```
            List of relations
 Schema |     Name      | Type |  Owner
--------+---------------+------+----------
 public | order_summary | view | postgres
```

### DROP VIEW

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
DROP VIEW IF EXISTS order_summary;"'
```

`IF EXISTS` avoids an error if the view is already gone — safe in scripts.

## Updatable views

PostgreSQL can automatically make a view updatable if it:
- selects from a single table (no JOINs, no DISTINCT, no aggregates)
- includes the primary key of the underlying table

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE OR REPLACE VIEW active_products AS
SELECT id, name, price_cents, stock
FROM products
WHERE stock > 0;"'
```

Because `active_products` is a simple single-table view, INSERT/UPDATE/DELETE work through it:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
UPDATE active_products SET price_cents = 1499 WHERE name = '"'"'Notebook'"'"' RETURNING id, price_cents;"'
```

### WITH CHECK OPTION — guard the view's own WHERE

Without `WITH CHECK OPTION`, you could insert a row that immediately disappears from the view
(a zero-stock product inserted through `active_products`). Add the check to prevent that:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE OR REPLACE VIEW active_products AS
SELECT id, name, price_cents, stock
FROM products
WHERE stock > 0
WITH CHECK OPTION;"'
```

Now an insert or update that would violate `stock > 0` is rejected:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
INSERT INTO active_products (name, price_cents, stock)
VALUES ('"'"'Ghost Item'"'"', 100, 0);"'
```

```
ERROR:  new row violates check option for view "active_products"
```

## Materialized views

A materialized view **stores the result set on disk**. Queries hit cached data — no live join
re-execution. The trade-off: data is stale until you `REFRESH`.

### CREATE MATERIALIZED VIEW

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE MATERIALIZED VIEW order_stats AS
SELECT p.name  AS product,
       COUNT(*) AS order_count,
       SUM(o.qty) AS units_sold,
       SUM(o.qty * p.price_cents) AS revenue_cents
FROM orders o
JOIN products p ON p.id = o.product_id
GROUP BY p.name;"'
```

Query it instantly (no live join):

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
SELECT * FROM order_stats ORDER BY revenue_cents DESC;"'
```

```
  product  | order_count | units_sold | revenue_cents
-----------+-------------+------------+---------------
 Desk Lamp |           1 |          1 |          3999
 Notebook  |           2 |          3 |          3897
 Pen Set   |           1 |          5 |          2495
```

### REFRESH MATERIALIZED VIEW

After new orders arrive, rebuild the snapshot:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
REFRESH MATERIALIZED VIEW order_stats;"'
```

### REFRESH CONCURRENTLY — non-blocking refresh

Plain `REFRESH` takes an `AccessExclusiveLock` — queries against the view block until refresh
finishes. Add `CONCURRENTLY` to update in the background without blocking reads. Requires a
unique index on the materialized view:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE UNIQUE INDEX ON order_stats(product);
REFRESH MATERIALIZED VIEW CONCURRENTLY order_stats;"'
```

Wait — `CREATE UNIQUE INDEX` and `REFRESH` are separate statements and each needs its own
`-c` flag if chained:

```bash
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d learn_cli -c "CREATE UNIQUE INDEX ON order_stats(product);"'
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d learn_cli -c "REFRESH MATERIALIZED VIEW CONCURRENTLY order_stats;"'
```

## When to use which

| Situation | Use |
|-----------|-----|
| Simplify a complex query shared across the app | Regular view |
| Expose a subset of a table to a restricted role | Regular view |
| Want INSERT/UPDATE to flow through to the base table | Updatable view |
| Guard a view against rows violating its own filter | WITH CHECK OPTION |
| Expensive aggregation queried many times per minute | Materialized view |
| Reporting snapshot, acceptable to be minutes stale | Materialized view |
| Need always-current data | Regular view (not materialized) |

## Scenario: order_summary view

Re-create it after the exercises above, then add a filter:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE OR REPLACE VIEW order_summary AS
SELECT o.id    AS order_id,
       c.name  AS customer,
       p.name  AS product,
       o.qty,
       o.status,
       (o.qty * p.price_cents) AS total_cents,
       o.created_at
FROM orders o
JOIN customers c ON c.id = o.customer_id
JOIN products  p ON p.id = o.product_id;"'

# Revenue per customer (live, always current)
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
SELECT customer, SUM(total_cents) AS lifetime_value_cents
FROM order_summary
GROUP BY customer
ORDER BY lifetime_value_cents DESC;"'
```

## Gotchas / Docker notes

- **`OR REPLACE` is not available for materialized views** — to update a materialized view's
  definition, drop and recreate it (`DROP MATERIALIZED VIEW order_stats;`).
- **Materialized views are not automatically refreshed**: you must call `REFRESH` yourself, or
  schedule it via `pg_cron` / an external job.
- **`REFRESH CONCURRENTLY` needs a unique index**: without one, you get
  `ERROR: cannot refresh materialized view "..." concurrently`. Create the index first.
- **Stale data is invisible**: a regular view always reflects the latest committed data.
  Materialized views do not. Document your refresh cadence clearly.
- **`WITH CHECK OPTION` only applies to the view's own filter**, not the underlying table's
  constraints (those still fire too, giving two layers of protection).

---

Previous: [01-crud.md](01-crud.md) | Next: [03-indexes.md](03-indexes.md)
