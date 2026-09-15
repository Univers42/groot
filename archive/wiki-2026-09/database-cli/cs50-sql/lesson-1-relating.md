# Lesson 1 — Relating (CS50 SQL)

Data rarely lives in a single table. Real systems are webs of connected things: a customer places many orders, each order targets one product, a product can appear in thousands of orders. Lecture 1 of CS50's Introduction to Databases with SQL is about **relationships** — how to model them, how to enforce them in a schema, and how to query across them once they exist.

All examples below use a shop schema rather than CS50's own datasets. The ideas transfer directly.

---

## What you'll learn

- The three fundamental relationship types and when each applies
- How to read an Entity Relationship (ER) diagram with crow's-foot notation
- What primary keys and foreign keys actually enforce
- Why junction tables exist and how to design one
- Subqueries and the `IN` operator as an alternative to joins
- Every JOIN variant: inner, left, right, full outer, natural
- Set operations: `UNION`, `INTERSECT`, `EXCEPT`
- `GROUP BY` and `HAVING` for aggregate analysis across groups

---

## Our shop schema

Three tables. Copy-pasteable into Postgres or SQLite.

```sql
CREATE TABLE customers (
    id         SERIAL PRIMARY KEY,
    name       TEXT        NOT NULL,
    email      TEXT UNIQUE NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE products (
    id          SERIAL PRIMARY KEY,
    name        TEXT    NOT NULL,
    price_cents INTEGER NOT NULL CHECK (price_cents >= 0),
    stock       INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE orders (
    id          SERIAL PRIMARY KEY,
    customer_id INTEGER     NOT NULL REFERENCES customers(id),
    product_id  INTEGER     NOT NULL REFERENCES products(id),
    qty         INTEGER     NOT NULL CHECK (qty > 0),
    status      TEXT        NOT NULL DEFAULT 'pending',
    created_at  TIMESTAMPTZ DEFAULT now()
);
```

Open a Postgres session against the running stack:

```bash
docker exec -it mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

---

## Relationship types

### One-to-one

One row in table A corresponds to exactly one row in table B, and the reverse is equally true. Example: a customer profile and its billing address stored separately so the main table stays lean. Neither side can belong to two records on the other side.

In practice, one-to-one relationships are rarer than they appear — often a signal that the two tables could be merged. They are useful when one side is optional or when access patterns differ significantly (you read the profile on every page load but only touch billing at checkout).

### One-to-many

One row in table A owns many rows in table B, but each row in B belongs to exactly one A. A customer can place many orders; each order belongs to exactly one customer. This is the most common relationship type.

The foreign key always lives on the *many* side. In the shop schema, `orders.customer_id` points back to `customers.id` — the order is the "many", the customer is the "one".

### Many-to-many

Any row in A can relate to many rows in B, and any row in B can relate to many rows in A. A student takes many courses; each course has many students. In commerce, a customer can buy many products, and each product can be bought by many customers.

Relational databases cannot express many-to-many directly between two tables. The solution is a third table that sits between them — a **junction table** (also called an associative table or join table). `orders` is exactly that: it resolves the many-to-many between `customers` and `products` while also carrying its own data (`qty`, `status`, `created_at`).

---

## Entity Relationship (ER) diagrams

An ER diagram is a visual map of tables and how they connect. Each table is drawn as a box, its columns listed inside. Lines between boxes represent relationships.

**Crow's-foot notation** encodes cardinality on each end of the line using small symbols:

| Symbol at line end | Meaning |
|--------------------|---------|
| Single vertical bar `|` | Exactly one |
| Double vertical bar `||` | One and only one |
| Crow's foot `<` or `>` | Many |
| Circle `o` | Zero (optional) |

A one-to-many line between `customers` and `orders` would show `||` at the customer end and `o<` (zero-or-many) at the orders end — a customer may have zero orders, or many.

ER diagrams are design artifacts. Tools like dbdiagram.io, pgAdmin, or even a whiteboard generate them. They are most valuable before the schema exists (catching design mistakes early) and as living documentation afterward.

---

## Primary keys and foreign keys

### Primary key

A primary key is a column (or combination of columns) whose value uniquely identifies every row in the table. The database enforces two rules automatically: no two rows share the same key value, and the key is never `NULL`.

```sql
-- customers.id is the primary key — every customer gets a unique integer
SELECT id, name FROM customers WHERE id = 42;
```

Using `SERIAL` (Postgres) or `INTEGER PRIMARY KEY` (SQLite) creates an auto-incrementing integer the database manages for you. You never insert the id directly; the engine assigns the next value.

### Foreign key

A foreign key is a column whose values must match an existing primary key in another table. It is a promise enforced at write time: you cannot insert an order referencing `customer_id = 999` unless a customer with `id = 999` already exists.

```sql
-- This will fail if customer_id 999 does not exist in customers
INSERT INTO orders (customer_id, product_id, qty) VALUES (999, 1, 3);
-- ERROR: insert or update on table "orders" violates foreign key constraint
```

Foreign keys also control what happens when the referenced row is deleted. `ON DELETE CASCADE` removes child rows automatically. `ON DELETE RESTRICT` (the default) blocks the deletion until children are removed first.

### Junction tables for many-to-many

The `orders` table is a junction between `customers` and `products`. Its primary key is its own `id` column; it carries two foreign keys pointing outward. That pattern — own PK plus two FKs plus payload columns — is the canonical junction table shape.

```sql
-- Every order is anchored to both a customer and a product
SELECT
    c.name    AS customer,
    p.name    AS product,
    o.qty,
    o.status
FROM orders o
JOIN customers c ON o.customer_id = c.id
JOIN products  p ON o.product_id  = p.id;
```

---

## Subqueries and the IN operator

A subquery is a `SELECT` statement nested inside another statement, wrapped in parentheses. The inner query runs first; its result set becomes input to the outer query.

The `IN` operator tests whether a value appears in a list — and a subquery can produce that list dynamically.

**Use case:** find every product that has ever been ordered.

```sql
SELECT name
FROM products
WHERE id IN (
    SELECT DISTINCT product_id
    FROM orders
);
```

The inner query returns the set of `product_id` values that appear in `orders`. The outer query fetches names for those ids. This reads naturally: "give me products whose id is in the set of ordered product ids."

Subqueries can also appear in `FROM` (derived tables) and in `SELECT` (scalar subqueries):

```sql
-- Scalar subquery: how many orders each customer has placed
SELECT
    name,
    (SELECT COUNT(*) FROM orders WHERE customer_id = customers.id) AS order_count
FROM customers;
```

Scalar subqueries return exactly one row and one column. If they return more than one row, the database raises an error.

Performance note: subqueries that run once per outer row (correlated subqueries) can be slow on large tables. Rewriting as a JOIN or a CTE is usually faster, but correctness first.

---

## JOINs

A `JOIN` combines rows from two tables based on a condition. The result is a virtual table whose columns come from both sides. Joins are how you "un-split" data that was normalized into separate tables.

### INNER JOIN

Returns only the rows where the join condition is satisfied on **both** sides. Rows with no match on either side are dropped.

```sql
-- Orders with customer names — only orders that have a matching customer
SELECT o.id, c.name, o.qty, o.status
FROM orders o
INNER JOIN customers c ON o.customer_id = c.id;
```

`INNER JOIN` is the default join type; writing `JOIN` alone means inner join.

### LEFT JOIN (LEFT OUTER JOIN)

Returns all rows from the left table, plus matching rows from the right. When there is no match on the right side, the right-side columns come back as `NULL`.

```sql
-- All customers, including those with no orders yet
SELECT c.name, o.id AS order_id, o.status
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.id;
```

Customers who have never ordered appear once with `order_id = NULL` and `status = NULL`. This is how you find rows that have no match: filter `WHERE o.id IS NULL`.

```sql
-- Customers who have never placed an order
SELECT c.name
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.id
WHERE o.id IS NULL;
```

### RIGHT JOIN (RIGHT OUTER JOIN)

The mirror image of a left join: all rows from the right table, matched against the left. Rare in practice because you can always flip the table order and use a left join instead, which reads more naturally.

```sql
-- All orders, even if the customer row is somehow missing
SELECT o.id, c.name
FROM customers c
RIGHT JOIN orders o ON o.customer_id = c.id;
```

> **SQLite note:** `RIGHT JOIN` and `FULL JOIN` were not supported until SQLite 3.39 (released August 2022). On older SQLite versions these raise a syntax error. Check `SELECT sqlite_version();` if you run into trouble.

### FULL JOIN (FULL OUTER JOIN)

Returns all rows from both tables. Unmatched rows on the left get `NULL` for right-side columns; unmatched rows on the right get `NULL` for left-side columns. Useful for finding gaps on either side simultaneously.

```sql
-- Every customer and every order; NULLs wherever there is no match
SELECT c.name, o.id AS order_id
FROM customers c
FULL JOIN orders o ON o.customer_id = c.id;
```

### NATURAL JOIN

Joins on all columns that share the same name across both tables, automatically. It is convenient but fragile — adding a column with a coincidentally matching name silently changes join behavior. Prefer explicit `ON` conditions in any code that needs to survive schema evolution.

```sql
-- Works if orders has a column named exactly 'id' that matches customers — usually not what you want
SELECT * FROM customers NATURAL JOIN orders;
```

### Joining more than two tables

Chains of joins are common. Add one `JOIN … ON …` clause per additional table:

```sql
-- Full picture: customer name, product name, qty, status
SELECT
    c.name    AS customer,
    p.name    AS product,
    o.qty,
    o.status
FROM orders o
JOIN customers c ON o.customer_id = c.id
JOIN products  p ON o.product_id  = p.id
ORDER BY o.created_at DESC;
```

---

## Set operations

Set operations combine the result sets of two independent `SELECT` statements. Both queries must return the same number of columns with compatible types.

### UNION

Merges two result sets and removes duplicates. Use `UNION ALL` to keep duplicates (faster — no dedup pass).

```sql
-- Names of everyone who has either created an account or placed an order
-- (in this schema they're the same people, but illustrates the pattern)
SELECT name FROM customers WHERE created_at < '2025-01-01'
UNION
SELECT name FROM customers WHERE status = 'vip';  -- hypothetical column
```

A more realistic use: combine two differently filtered sets from different tables into one list.

```sql
-- Products never ordered OR out of stock — two conditions, one list
SELECT name FROM products WHERE stock = 0
UNION
SELECT p.name
FROM products p
WHERE p.id NOT IN (SELECT DISTINCT product_id FROM orders);
```

### INTERSECT

Returns only rows that appear in **both** result sets.

```sql
-- Customers who placed an order in both January and February 2025
SELECT customer_id FROM orders WHERE created_at BETWEEN '2025-01-01' AND '2025-01-31'
INTERSECT
SELECT customer_id FROM orders WHERE created_at BETWEEN '2025-02-01' AND '2025-02-28';
```

### EXCEPT

Returns rows from the first set that do not appear in the second set.

```sql
-- Products that have been ordered but are now out of stock
SELECT DISTINCT product_id FROM orders
EXCEPT
SELECT id FROM products WHERE stock > 0;
```

---

## GROUP BY and HAVING

### GROUP BY

`GROUP BY` collapses many rows with the same value into a single summary row. Every column in the `SELECT` list that is not an aggregate function must appear in the `GROUP BY` clause.

```sql
-- Total quantity ordered per product
SELECT
    product_id,
    SUM(qty)   AS total_units_sold,
    COUNT(*)   AS order_count
FROM orders
GROUP BY product_id;
```

Join to get readable names:

```sql
SELECT
    p.name,
    SUM(o.qty)                        AS units_sold,
    SUM(o.qty * p.price_cents) / 100.0 AS revenue_dollars
FROM orders o
JOIN products p ON o.product_id = p.id
GROUP BY p.id, p.name
ORDER BY revenue_dollars DESC;
```

```bash
docker exec -it mini-baas-postgres sh -lc '
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
    SELECT p.name, SUM(o.qty) AS units_sold
    FROM orders o
    JOIN products p ON o.product_id = p.id
    GROUP BY p.name
    ORDER BY units_sold DESC
    LIMIT 5;
  "
'
```

### HAVING

`WHERE` filters rows before grouping. `HAVING` filters groups after aggregation. Use `WHERE` to exclude raw rows; use `HAVING` to exclude entire groups based on their aggregate value.

```sql
-- Only products that have sold more than 100 units total
SELECT
    p.name,
    SUM(o.qty) AS units_sold
FROM orders o
JOIN products p ON o.product_id = p.id
GROUP BY p.id, p.name
HAVING SUM(o.qty) > 100
ORDER BY units_sold DESC;
```

You cannot reference an aggregate alias in `HAVING` in standard SQL — repeat the expression, or wrap in a subquery/CTE.

```sql
-- Customers with more than 3 pending orders (combining WHERE and HAVING)
SELECT
    customer_id,
    COUNT(*) AS pending_count
FROM orders
WHERE status = 'pending'          -- WHERE filters rows first
GROUP BY customer_id
HAVING COUNT(*) > 3;              -- HAVING filters the resulting groups
```

---

## CS50 specifics

CS50's Introduction to Databases with SQL uses **SQLite** as its engine. SQLite is serverless — the entire database is a single `.db` file opened directly by the process, not a separate server process. That makes it perfect for a course: no setup, no daemon, just `sqlite3 longlist.db`.

**Datasets used in Lecture 1:**
- `longlist.db` — a Booker Prize fiction longlist database (books, authors, publishers)
- `sea_lions.db` — population counts of sea lions over time (used for set operation examples)

**SQLite-specific notes:**

| Feature | SQLite behavior |
|---------|----------------|
| `RIGHT JOIN` / `FULL JOIN` | Added in SQLite 3.39 (August 2022). Older versions raise `RIGHT and FULL OUTER JOINs are not currently supported`. |
| List tables | Use `.tables` in the SQLite CLI (dot-command). In Postgres use `\dt`; in MySQL use `SHOW TABLES;`. |
| `SERIAL` / sequences | SQLite uses `INTEGER PRIMARY KEY` which auto-increments. No `SERIAL` type. |
| Type affinity | SQLite uses type affinity, not strict types (unless `STRICT` mode). A column declared `TEXT` will happily store an integer. Postgres enforces types strictly. |

To start SQLite against CS50's file:

```bash
sqlite3 longlist.db
```

Then inside the SQLite shell:

```
.tables           -- list all tables
.schema books     -- show CREATE TABLE for the books table
.mode column      -- aligned column output
.headers on       -- show column names
```

Everything else — `SELECT`, `JOIN`, `GROUP BY`, `HAVING`, `UNION` — is standard SQL that runs identically in SQLite and Postgres.

---

## Maps to your wiki

These concepts appear elsewhere in the wiki under different engines:

- [postgres/01-crud](../postgres/01-crud.md) — the Postgres CRUD guide covers the same JOINs in the context of the full Postgres feature set, including CTEs and window functions that extend what GROUP BY alone can express.
- [mongodb/03-aggregation-views](../mongodb/03-aggregation-views.md) — MongoDB has no native JOIN because documents are not rows. The analog is `$lookup` in the aggregation pipeline, which does a left-outer-join from a collection to another collection. Understanding SQL JOINs first makes `$lookup` much less mysterious.

---

## Key takeaways

1. **Relationships model the real world.** One-to-many is the workhorse; many-to-many needs a junction table.
2. **Foreign keys enforce integrity at write time**, not query time — they prevent orphaned rows before they happen.
3. **Subqueries with IN** are readable and correct; reach for a JOIN when you also need columns from the related table or when performance matters at scale.
4. **INNER JOIN drops unmatched rows; LEFT/RIGHT/FULL JOIN preserves them as NULLs.** Which behavior you need determines which join type you reach for.
5. **WHERE filters rows; HAVING filters groups.** They operate at different stages of query execution and are not interchangeable.
6. **Set operations (UNION / INTERSECT / EXCEPT) work on result sets**, not on individual rows — both sides must be shape-compatible.
7. **SQLite is the teaching engine; Postgres is production.** Standard SQL travels between them; the syntax for listing tables, data types, and join support (pre-3.39 SQLite) does not.

---

> **Source & license.** Original study notes following *CS50's Introduction to Databases with SQL*, Lecture 1 — Relating (<https://cs50.harvard.edu/sql/notes/1/>). Course materials © President and Fellows of Harvard College, licensed [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/). These notes are an original summary in our own words; see the source for the canonical lecture.
