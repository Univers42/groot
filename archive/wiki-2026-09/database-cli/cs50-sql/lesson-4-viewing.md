# Lesson 4 — Viewing (CS50 SQL)

SQL tables hold raw data. Views let you name a query and treat it as though it were a table — without copying any rows. Lecture 4 of CS50's *Introduction to Databases with SQL* walks through the full lifecycle: creating views, deciding when to use them over CTEs, and hardening a schema by deliberately showing only what each consumer needs to see.

These notes use the shop schema that lives in this repository's development stack:

```
customers(id, name, email, created_at)
products(id, name, price_cents, stock)
orders(id, customer_id, product_id, qty, status, created_at)
```

Every SQL block is Postgres-flavoured and copy-pasteable into:

```bash
docker exec -it mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

SQLite differences — the engine CS50's course environment uses — are called out explicitly in the **CS50 specifics** section at the bottom.

---

## What you'll learn

- How a view differs from a table and why that distinction matters for storage
- The `CREATE VIEW`, `DROP VIEW`, and `CREATE TEMPORARY VIEW` statements
- The four workhorses: JOIN simplification, aggregation, partitioning, and access control
- When a CTE beats a view, and when a view beats a CTE
- Granting access on a view instead of a table as a direct least-privilege pattern
- Filtering soft-deleted rows transparently so callers never repeat the same `WHERE` clause
- Writable views via `INSTEAD OF` triggers in SQLite (with `WHEN` conditions)
- Materialized views in Postgres: the one place query caching enters the picture

---

## What a view is

A view is a saved SELECT statement that the database engine re-evaluates each time you query it. Nothing is duplicated on disk; the underlying base tables remain the single source of truth. Because of this, a view always reflects live data: insert a new order right now and every view that references `orders` immediately includes it.

Think of a view as a named window. The glass is transparent — the frame is fixed.

```sql
-- A view called order_summary resolves its saved SELECT at query time.
-- No data is stored separately from the base tables.
SELECT * FROM order_summary;
```

The practical payoff is that application code can query a stable, well-named surface even as the underlying table structure evolves. As long as the view continues to compile, callers are insulated from schema changes underneath it.

---

## Creating and dropping views

### CREATE VIEW

```sql
CREATE VIEW order_summary AS
SELECT
    o.id              AS order_id,
    c.name            AS customer,
    p.name            AS product,
    p.price_cents * o.qty AS total_cents,
    o.status,
    o.created_at
FROM orders o
JOIN customers c ON c.id = o.customer_id
JOIN products  p ON p.id = o.product_id;
```

The view `order_summary` now behaves like a table everywhere in the session — in `SELECT`, `WHERE`, `JOIN`, and subqueries. Callers do not need to know the three-table join that drives it.

### DROP VIEW

```sql
DROP VIEW IF EXISTS order_summary;
```

`IF EXISTS` keeps the statement idempotent in migration scripts: running it twice raises no error.

### CREATE TEMPORARY VIEW

A temporary view lives only for the duration of the current session. It is invisible to other connections and disappears automatically when the session closes, leaving no database object behind.

```sql
CREATE TEMPORARY VIEW cheap_products AS
SELECT id, name, price_cents
FROM products
WHERE price_cents < 1000;
```

Temporary views are useful for exploratory analysis or multi-step scripts that should clean up after themselves.

---

## Four use cases for views

### 1 — Simplifying complex JOINs

Queries that join three or more tables are easy to write once and tedious to re-derive on every access. A view codifies the canonical join so downstream queries remain readable.

The `order_summary` view above is the archetypal example: three tables joined into a flat result that the rest of the application treats as a single surface.

```sql
-- Application code sees one surface, not three tables.
SELECT customer, product, total_cents
FROM order_summary
WHERE status = 'shipped'
ORDER BY total_cents DESC;
```

### 2 — Aggregating

Aggregation views let you encapsulate business metrics as queryable objects, rather than embedding `GROUP BY` logic everywhere it is needed.

```sql
CREATE VIEW customer_spend AS
SELECT
    c.id,
    c.name,
    COUNT(o.id)                     AS order_count,
    SUM(p.price_cents * o.qty)      AS lifetime_cents
FROM customers c
LEFT JOIN orders  o ON o.customer_id = c.id
LEFT JOIN products p ON p.id = o.product_id
GROUP BY c.id, c.name;
```

```sql
-- Callers retrieve ranked metrics without rewriting GROUP BY.
SELECT name, lifetime_cents
FROM customer_spend
ORDER BY lifetime_cents DESC
LIMIT 10;
```

### 3 — Partitioning a dataset

A partitioning view exposes only the slice of a table that a given team or process cares about. The intent is clarity and convenience rather than access restriction — though the two often go hand in hand.

```sql
-- A focused view for the fulfilment queue dashboard.
CREATE VIEW pending_orders AS
SELECT
    o.id,
    c.name  AS customer,
    p.name  AS product,
    o.qty
FROM orders o
JOIN customers c ON c.id = o.customer_id
JOIN products  p ON p.id = o.product_id
WHERE o.status = 'pending';
```

The fulfilment application queries `pending_orders` directly. If the status lifecycle ever gains a new pre-pending state, a single view update propagates the change everywhere.

### 4 — Securing (exposing only selected columns or rows)

This is the access-control pattern, which gets its own dedicated section below. The key idea: grant `SELECT` on the view, revoke direct table access, and callers cannot reach columns or rows you chose not to include.

---

## Common Table Expressions: a single-query alternative

A CTE uses `WITH ... AS` to name an intermediate result set *within a single query*. It is not persisted as a database object and cannot be referenced outside the query that defines it.

```sql
WITH enriched AS (
    SELECT
        o.id,
        c.name            AS customer,
        p.name            AS product,
        p.price_cents * o.qty AS total_cents
    FROM orders o
    JOIN customers c ON c.id = o.customer_id
    JOIN products  p ON p.id = o.product_id
)
SELECT
    customer,
    SUM(total_cents) AS revenue_cents
FROM enriched
GROUP BY customer
ORDER BY revenue_cents DESC;
```

**CTEs vs. views — when to choose which:**

| Dimension | CTE | View |
|-----------|-----|------|
| Scope | Single query only | Persistent database object |
| Reusability | One-use; invisible to other queries | Referenceable anywhere by any caller |
| Requires DDL | No | Yes (`CREATE VIEW`) |
| Cross-session visibility | No | Yes |

Choose a CTE when a helper expression is used in exactly one place and you want everything self-contained in a single statement. Choose a view when multiple queries, multiple applications, or multiple roles all need the same named surface.

---

## Securing data with views

Views are a clean expression of the principle of least privilege: each consumer receives exactly the columns and rows their role requires, with nothing extra exposed.

Consider `customers` — it holds email addresses that the fulfilment team should not see.

```sql
-- Expose only the columns the fulfilment role needs.
CREATE VIEW fulfilment_customers AS
SELECT id, name, created_at
FROM customers;
```

In Postgres you pair the view with explicit privilege management:

```sql
-- Revoke direct table access from the fulfilment role.
REVOKE SELECT ON customers FROM fulfilment_role;

-- Grant access only through the view.
GRANT SELECT ON fulfilment_customers TO fulfilment_role;
```

```bash
# Verify the restriction is in place.
docker exec -it mini-baas-postgres sh -lc \
  'psql -U fulfilment_role -d "$POSTGRES_DB" -c "SELECT * FROM customers;"'
# => ERROR: permission denied for table customers

docker exec -it mini-baas-postgres sh -lc \
  'psql -U fulfilment_role -d "$POSTGRES_DB" -c "SELECT * FROM fulfilment_customers;"'
# => Returns id, name, created_at only — email never appears.
```

Row filtering follows the same pattern. A view that includes `WHERE status != 'internal'` permanently hides those rows from any caller who only has access to the view, no matter how they query it.

---

## Soft deletions revisited via views

A soft delete marks a row as inactive — typically a `deleted_at` timestamp or an `is_deleted` flag — instead of removing it. The data is preserved for auditing and recovery. A view that filters out soft-deleted rows shields the rest of the application from needing to repeat that condition on every query.

Adding a `deleted_at` column to `products` (in practice this belongs in a migration):

```sql
ALTER TABLE products ADD COLUMN deleted_at TIMESTAMPTZ DEFAULT NULL;
```

```sql
-- Application code queries this view instead of the raw table.
CREATE VIEW active_products AS
SELECT id, name, price_cents, stock
FROM products
WHERE deleted_at IS NULL;
```

```sql
-- Soft-delete a product.
UPDATE products SET deleted_at = NOW() WHERE id = 42;

-- The view excludes it automatically; no caller changes required.
SELECT * FROM active_products WHERE id = 42;
-- 0 rows returned
```

The deleted row still exists in `products` for an analyst who queries the table directly, or for a recovery script that clears `deleted_at`.

---

## Making views writable: INSTEAD OF triggers

In SQLite, views are read-only by design. Issuing `INSERT`, `UPDATE`, or `DELETE` against a view raises an error unless an `INSTEAD OF` trigger intercepts the write and redirects it to the appropriate base table.

```sql
-- SQLite syntax.
-- Allow inserts through active_products to land in the products table.
CREATE TRIGGER insert_active_product
INSTEAD OF INSERT ON active_products
BEGIN
    INSERT INTO products (name, price_cents, stock, deleted_at)
    VALUES (NEW.name, NEW.price_cents, NEW.stock, NULL);
END;
```

The `WHEN` clause makes a trigger conditional — useful for inline validation:

```sql
-- Only fire when the incoming price is positive.
CREATE TRIGGER insert_valid_product
INSTEAD OF INSERT ON active_products
WHEN NEW.price_cents > 0
BEGIN
    INSERT INTO products (name, price_cents, stock, deleted_at)
    VALUES (NEW.name, NEW.price_cents, NEW.stock, NULL);
END;
```

`INSTEAD OF` triggers can be written for `INSERT`, `UPDATE`, and `DELETE` independently. Once all three are in place, the view becomes a fully writable proxy over the base table.

> **Postgres note.** Postgres also supports `INSTEAD OF` triggers on views, but it additionally offers `CREATE RULE` and the simpler `WITH CHECK OPTION` clause for updatable views. See the cross-link below for the Postgres-specific walkthrough.

---

## Materialized views: caching expensive aggregates

A standard view re-runs its defining query on every access. When that query is expensive — a multi-table join over millions of rows followed by aggregation — the cost recurs constantly. Postgres (and several other server-side engines) address this with **materialized views**: a view whose result set is computed once and stored physically on disk.

```sql
-- Postgres only — not available in SQLite.
CREATE MATERIALIZED VIEW monthly_revenue AS
SELECT
    DATE_TRUNC('month', o.created_at)   AS month,
    SUM(p.price_cents * o.qty)          AS revenue_cents
FROM orders o
JOIN products p ON p.id = o.product_id
GROUP BY 1
ORDER BY 1;
```

```bash
docker exec -it mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT * FROM monthly_revenue;"'
```

The stored result goes stale the moment the base tables change. Refresh it explicitly:

```sql
-- Blocking refresh — the view is locked until the refresh completes.
REFRESH MATERIALIZED VIEW monthly_revenue;

-- Non-blocking refresh — requires a unique index on the materialized view.
REFRESH MATERIALIZED VIEW CONCURRENTLY monthly_revenue;
```

A common pattern is to trigger a refresh on a schedule (nightly, hourly) or immediately after a batch write. The trade-off is data recency against query latency: pick the refresh cadence that matches the staleness tolerance of the use case.

SQLite has no materialized view syntax. Approximating the behaviour requires a physical table plus manual refresh logic — workable for small datasets but not a built-in feature.

---

## CS50 specifics

CS50's *Introduction to Databases with SQL* uses **SQLite** as its course engine. A few SQLite constraints are worth keeping in mind when reading the lecture:

- **Views are read-only by default.** Any write against a view fails unless an `INSTEAD OF` trigger handles it.
- **No materialized views.** SQLite has no `CREATE MATERIALIZED VIEW` syntax. The workaround is a regular table refreshed manually.
- **`CREATE TEMPORARY VIEW` is supported** and behaves as described above: session-scoped, invisible to other connections.
- **CTEs are fully supported** via the standard `WITH ... AS` syntax across all modern SQLite versions.

Datasets the lecture references: **longlist.db** (a catalogue of literary works nominated for international prizes), **rideshare.db** (a ride-sharing service schema), and **mfa.db** (a museum of fine arts collection). These notes substitute the shop schema throughout, but every view technique demonstrated here applies identically to those datasets.

---

## Maps to your wiki

The concepts in this lesson have direct counterparts in the engine-specific guides under `wiki/database-cli/`:

- **Postgres views** — full lifecycle, updatable views, `WITH CHECK OPTION`, `SECURITY DEFINER`, and materialized view management:
  [postgres/02-views](../postgres/02-views.md)

- **SQL Server (MSSQL) views** — indexed views (the MSSQL equivalent of materialized views), schema binding, and encrypted view definitions:
  [mssql/02-views](../mssql/02-views.md)

- **MongoDB aggregation views** — `db.createView()` wraps an aggregation pipeline as a named, queryable collection surface:
  [mongodb/03-aggregation-views](../mongodb/03-aggregation-views.md)

---

## Key takeaways

1. A view is a stored query, not a stored copy of data. It always reflects the current state of its base tables.
2. Use `CREATE VIEW` for a reusable, named surface shared across queries and callers. Use a CTE for a scoped intermediate result needed only within a single statement.
3. The four practical reasons to reach for a view — join simplification, aggregation, partitioning, and access restriction — each solve a different organisational or security problem.
4. Granting `SELECT` on the view and revoking it on the underlying table is a direct, auditable implementation of least privilege.
5. A soft-delete filter in a view propagates to every caller automatically; no application code needs to repeat `WHERE deleted_at IS NULL`.
6. SQLite views are read-only; `INSTEAD OF` triggers are the only mechanism to intercept writes. The optional `WHEN` clause adds inline validation logic without a separate check constraint.
7. Materialized views (Postgres) trade data freshness for query speed. SQLite has no built-in equivalent — approximate with a physical table and a scheduled refresh.

---

> **Source & license.** Original study notes following *CS50's Introduction to Databases with SQL*, Lecture 4 — Viewing (<https://cs50.harvard.edu/sql/notes/4/>). Course materials © President and Fellows of Harvard College, licensed [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/). These notes are an original summary in our own words; see the source for the canonical lecture.
