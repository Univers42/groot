# 02 — Views and Materialized Views

A view is a saved SELECT query referenced by name. A materialized view stores the query result on disk, trading freshness for read speed. Both are fully supported in CockroachDB.

## Setup

```bash
docker exec mini-baas-cockroach cockroach sql --insecure \
  -e "CREATE DATABASE IF NOT EXISTS learn_cli;"
```

Then create the shop schema and insert sample data (see [01-crud.md](01-crud.md) for the full block). The examples below assume `customers`, `products`, and `orders` exist with at least a few rows.

## CREATE VIEW

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
CREATE VIEW order_summary AS
SELECT
  c.name                     AS customer,
  p.name                     AS product,
  o.qty,
  (o.qty * p.price_cents)    AS total_cents,
  o.status,
  o.created_at
FROM orders o
JOIN customers c ON c.id = o.customer_id
JOIN products  p ON p.id = o.product_id;
"
```

Query it like any table:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
SELECT customer, product, total_cents, status
FROM   order_summary
WHERE  status = 'shipped'
ORDER  BY total_cents DESC;
"
```

Example output:

```
customer      product   total_cents  status
Alice Martin  Widget A  1998         shipped
```

Views in CockroachDB are always **logical** — they re-execute the underlying query on every access. They add no storage cost but also no read speedup.

## Inspecting a view definition

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
SHOW CREATE VIEW order_summary;
"
```

Output:

```
table_name     create_statement
order_summary  CREATE VIEW public.order_summary (customer, product, ...) AS SELECT ...
```

Use `SHOW TABLES;` to confirm whether an object is a `view`, `materialized view`, or `table`:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "SHOW TABLES;"
```

```
schema_name  table_name         type               owner  estimated_row_count
public       customers          table              root   3
public       mv_product_sales   materialized view  root   0
public       order_summary      view               root   0
public       orders             table              root   1
public       products           table              root   3
```

## DROP VIEW

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
DROP VIEW order_summary;
"
```

Use `DROP VIEW IF EXISTS` to avoid errors in idempotent scripts. `CASCADE` also drops objects that depend on this view.

## CREATE MATERIALIZED VIEW

A materialized view snapshots the query result and stores it. Reads hit the snapshot rather than the base tables — useful for expensive aggregations.

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
CREATE MATERIALIZED VIEW mv_product_sales AS
SELECT
  p.name                AS product,
  SUM(o.qty)            AS total_sold,
  SUM(o.qty * p.price_cents) AS revenue_cents
FROM orders o
JOIN products p ON p.id = o.product_id
GROUP BY p.name;
"
```

Query it:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
SELECT product, total_sold, revenue_cents
FROM   mv_product_sales
ORDER  BY revenue_cents DESC;
"
```

```
product   total_sold  revenue_cents
Widget A  2           1998
```

## REFRESH MATERIALIZED VIEW

The snapshot does **not** update automatically when base data changes. You must refresh it manually:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
REFRESH MATERIALIZED VIEW mv_product_sales;
"
```

In production this is typically called from a scheduled job or after a bulk load. There is no `WITH NO DATA` option in CockroachDB — the initial `CREATE` always populates data.

## DROP MATERIALIZED VIEW

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
DROP MATERIALIZED VIEW mv_product_sales;
"
```

## Scenario: daily revenue snapshot

Picture a reporting dashboard that cannot afford to run heavy JOINs on every request. You materialise the aggregation once and refresh it each night:

```bash
# Create the snapshot view (run once)
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
CREATE MATERIALIZED VIEW mv_daily_revenue AS
SELECT
  date_trunc('day', o.created_at) AS day,
  p.name                           AS product,
  SUM(o.qty * p.price_cents)       AS revenue_cents
FROM orders o
JOIN products p ON p.id = o.product_id
GROUP BY 1, 2;
"

# Dashboard query — hits the snapshot, no JOIN overhead
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
SELECT day, product, revenue_cents
FROM   mv_daily_revenue
ORDER  BY day DESC, revenue_cents DESC
LIMIT  20;
"

# Nightly refresh (called from a cron or make target)
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
REFRESH MATERIALIZED VIEW mv_daily_revenue;
"
```

## Cleanup

```bash
docker exec mini-baas-cockroach cockroach sql --insecure \
  -e "DROP DATABASE learn_cli CASCADE;"
```

## Gotchas / Docker notes

- **No automatic refresh.** Unlike some databases with `REFRESH MATERIALIZED VIEW CONCURRENTLY`, CockroachDB's refresh is a full replace. Plan accordingly for busy base tables.
- **Views are not updatable.** `INSERT`/`UPDATE` through a view is not supported in CockroachDB.
- **`SHOW TABLES` includes views.** The `type` column distinguishes `table`, `view`, and `materialized view`. Don't rely on the table count alone.
- **Dropping base tables.** You cannot `DROP TABLE` a table that a view depends on unless you use `CASCADE` or drop the view first.
- **`SHOW CREATE VIEW` works for materialized views too** — just reference the materialized view name.

---

← [01-crud.md](01-crud.md) | [03-indexes.md](03-indexes.md) →
