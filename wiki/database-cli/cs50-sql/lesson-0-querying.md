# Lesson 0 — Querying (CS50 SQL)

The first thing you do with any database is ask it questions. Before you can insert, update, or delete anything you need to know how to pull data back out in a useful shape — and that is exactly what Lecture 0 teaches. This lesson covers `SELECT` from first principles all the way to aggregation.

---

## What you'll learn

- What a database is and how it organises data into tables
- How to choose which columns and rows come back
- How to cap, sort, and filter a result set
- How to handle missing values correctly
- How to match partial strings with wildcards
- How to produce summary statistics over a set of rows

---

## Databases, DBMSs, and SQL

A **database** is an organised collection of data that is stored and retrieved in a structured way. By itself that is just a filing cabinet; the software you use to talk to it is the **Database Management System** (DBMS). PostgreSQL, MySQL, SQLite, and SQL Server are all DBMSs — each one stores data differently under the hood, but they all expose a common query language.

That language is **SQL** (Structured Query Language). It is declarative: you describe *what* you want, not *how* to fetch it. The DBMS figures out the plan.

Every DBMS organises data into **tables**. A table looks like a spreadsheet:
- Each **row** (also called a *record* or *tuple*) represents one entity — one customer, one order, one product.
- Each **column** (also called an *attribute* or *field*) represents one property that every entity in that table shares — a name, a price, a timestamp.

Our running example throughout these notes uses three tables:

```text
customers(id, name, email, created_at)
products (id, name, price_cents, stock)
orders   (id, customer_id, product_id, qty, status, created_at)
```

CS50 demonstrates these same concepts with an International Booker Prize database in SQLite, browsed interactively inside VS Code or DB Browser for SQLite.

---

## Connecting to Postgres in our stack

All examples below run in Postgres. Open an interactive session:

```bash
docker exec -it mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

For one-shot queries without opening an interactive shell, append `-c "..."`:

```bash
docker exec -it mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT name, email FROM customers LIMIT 5;"'
```

> **SQLite note.** In SQLite you open a file (`sqlite3 mydb.db`) and exit with `.quit`. Postgres is a server process you connect to over a socket — there is no file to open.

---

## SELECT and FROM

`SELECT` is the entry point for every read query. It tells the database which columns you care about; `FROM` tells it which table to look in.

```sql
-- Every column in the products table
SELECT * FROM products;

-- Just the name and price
SELECT name, price_cents FROM products;
```

The asterisk (`*`) is shorthand for "all columns". It is handy while exploring, but naming columns explicitly in production code makes queries more predictable when the table schema changes.

```bash
docker exec -it mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT name, price_cents FROM products;"'
```

---

## LIMIT

A table can hold millions of rows. Without any filter the database will return all of them, which is rarely what you want while exploring. `LIMIT` caps the number of rows in the result:

```sql
-- See the first ten customers registered in the system
SELECT id, name, email FROM customers LIMIT 10;
```

`LIMIT` does not guarantee any particular order unless you also use `ORDER BY` (covered below). Think of it as "give me at most N rows from whatever the engine felt like scanning first."

---

## WHERE — filtering rows

`SELECT` chooses columns; `WHERE` chooses rows. Only rows for which the condition is true make it into the result.

```sql
-- Orders that are still pending
SELECT id, customer_id, qty FROM orders WHERE status = 'pending';

-- Products that cost more than five dollars (price stored as cents)
SELECT name, price_cents FROM products WHERE price_cents > 500;
```

### Comparison operators

| Operator | Meaning |
|----------|---------|
| `=` | equal |
| `!=` or `<>` | not equal |
| `<` | less than |
| `>` | greater than |
| `<=` | less than or equal |
| `>=` | greater than or equal |

Both `!=` and `<>` mean "not equal" — they are synonyms. `<>` is the ANSI-standard form.

### Combining conditions with AND, OR, NOT

Multiple conditions can be chained. `AND` requires both sides to be true; `OR` requires at least one; `NOT` inverts a condition.

```sql
-- Pending orders with a quantity of more than one unit
SELECT id, customer_id, qty
FROM orders
WHERE status = 'pending'
  AND qty > 1;

-- Products that are either sold out or absurdly cheap (under 10 cents)
SELECT name, price_cents, stock
FROM products
WHERE stock = 0
   OR price_cents < 10;

-- Everyone except the customer with id 7
SELECT name, email FROM customers WHERE NOT id = 7;
-- equivalently:
SELECT name, email FROM customers WHERE id != 7;
```

---

## NULL — the absent value

`NULL` is SQL's way of saying "this value is unknown or not applicable." It is not zero, it is not an empty string — it is the absence of a value entirely.

Comparing anything to `NULL` with `=` always produces `NULL` (not true, not false — unknown), so the following query will never return any rows no matter what:

```sql
-- This does NOT work — NULL = NULL is not TRUE, it is NULL
SELECT * FROM orders WHERE product_id = NULL;
```

The correct operators are `IS NULL` and `IS NOT NULL`:

```sql
-- Orders that were never linked to a product (data quality issue)
SELECT id, customer_id FROM orders WHERE product_id IS NULL;

-- Orders that do have a product assigned
SELECT id, customer_id, product_id FROM orders WHERE product_id IS NOT NULL;
```

The same logic applies in `WHERE` conditions involving `AND`/`OR`: any expression that touches `NULL` can silently drop rows if you use `=` instead of `IS NULL`.

---

## LIKE — partial string matching

`WHERE name = 'Alice'` only matches the exact string. `LIKE` lets you match patterns using two special characters:

| Wildcard | Matches |
|----------|---------|
| `%` | any sequence of zero or more characters |
| `_` | exactly one character |

```sql
-- Customers whose name starts with "Al"
SELECT name, email FROM customers WHERE name LIKE 'Al%';

-- Customers with a Gmail address
SELECT name, email FROM customers WHERE email LIKE '%@gmail.com';

-- Products whose name is exactly five characters long
SELECT name FROM products WHERE name LIKE '_____';

-- Products with "pro" anywhere in the name (case-sensitive in Postgres)
SELECT name FROM products WHERE name LIKE '%pro%';
```

> **SQLite vs. Postgres.** SQLite's `LIKE` is case-insensitive for ASCII letters by default — `LIKE 'al%'` matches `Alice`. Postgres `LIKE` is case-sensitive; use `ILIKE` for case-insensitive matching, which is a Postgres extension not available in standard SQL or SQLite.

```bash
docker exec -it mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT name, email FROM customers WHERE email ILIKE '\''%@gmail.com'\'';"'
```

---

## Ranges with comparison operators and BETWEEN

You already saw `<` and `>` above. When you want to express "between X and Y inclusive," you can either chain two comparisons or use the `BETWEEN` shorthand:

```sql
-- Products priced between £2.00 and £10.00 (200–1000 cents), verbose form
SELECT name, price_cents
FROM products
WHERE price_cents >= 200
  AND price_cents <= 1000;

-- Same thing, shorter
SELECT name, price_cents
FROM products
WHERE price_cents BETWEEN 200 AND 1000;

-- Orders created in June 2025
SELECT id, customer_id, created_at
FROM orders
WHERE created_at BETWEEN '2025-06-01' AND '2025-06-30 23:59:59';
```

`BETWEEN x AND y` is inclusive on both ends, so it is exactly equivalent to `>= x AND <= y`.

---

## ORDER BY — sorting results

Rows come back in an arbitrary order unless you sort them. `ORDER BY` lets you specify one or more columns to sort on, and the direction for each.

```sql
-- Products cheapest-first
SELECT name, price_cents FROM products ORDER BY price_cents ASC;

-- Products most expensive first (DESC = descending)
SELECT name, price_cents FROM products ORDER BY price_cents DESC;

-- Orders sorted by customer, then newest first within each customer
SELECT id, customer_id, created_at
FROM orders
ORDER BY customer_id ASC, created_at DESC;
```

`ASC` (ascending) is the default, so writing `ORDER BY price_cents` and `ORDER BY price_cents ASC` are equivalent. Use multiple sort keys separated by commas — the second key only breaks ties left by the first.

Combining `ORDER BY` with `LIMIT` is a common pattern for "top N" queries:

```sql
-- The five most recently placed orders
SELECT id, customer_id, status, created_at
FROM orders
ORDER BY created_at DESC
LIMIT 5;
```

---

## Aggregate functions

So far every query has returned individual rows. Aggregate functions collapse a set of rows into a single computed value. They are always used in a `SELECT` list and operate on all rows that survive the `WHERE` clause.

### COUNT

`COUNT(*)` counts every row. `COUNT(column)` counts only rows where that column is not null.

```sql
-- How many customers are in the system?
SELECT COUNT(*) FROM customers;

-- How many orders have a non-null product_id?
SELECT COUNT(product_id) FROM orders;
```

### SUM, AVG, MIN, MAX

```sql
-- Total revenue in cents from all completed orders
SELECT SUM(price_cents * qty)
FROM orders
JOIN products ON products.id = orders.product_id
WHERE orders.status = 'completed';

-- Average product price in cents
SELECT AVG(price_cents) FROM products;

-- Cheapest and most expensive product
SELECT MIN(price_cents), MAX(price_cents) FROM products;

-- Largest single-order quantity ever placed
SELECT MAX(qty) FROM orders;
```

### ROUND

`AVG` often produces a long decimal. `ROUND(value, decimal_places)` trims it:

```sql
SELECT ROUND(AVG(price_cents), 2) FROM products;
```

### AS — column aliases

The default column header for an aggregate is the function call itself (`round(avg(price_cents), 2)`), which is ugly in a report. `AS` lets you rename it:

```sql
SELECT
    COUNT(*)                        AS total_customers,
    MIN(created_at)                 AS oldest_signup,
    MAX(created_at)                 AS newest_signup
FROM customers;
```

Aliases also work on regular columns:

```sql
SELECT name AS product_name, price_cents AS price FROM products LIMIT 5;
```

### DISTINCT

`DISTINCT` de-duplicates the values returned. Applied to a column it gives you the unique set; combined with `COUNT` it counts unique values:

```sql
-- What statuses exist in the orders table?
SELECT DISTINCT status FROM orders;

-- How many unique customers have placed at least one order?
SELECT COUNT(DISTINCT customer_id) FROM orders;
```

---

## CS50 specifics

CS50's Lecture 0 works exclusively in **SQLite** using the **International Booker Prize** dataset (`.db` file distributed with the course), opened in **DB Browser for SQLite** or the **SQLite extension for VS Code**. A few SQLite quirks worth knowing when you later read CS50's examples:

- **SQL keywords are case-insensitive.** `SELECT`, `select`, and `Select` are all the same in SQLite (and in Postgres). CS50's style tends to use uppercase keywords — a common convention.
- **Exiting the SQLite CLI** is done with `.quit` (a dot-command, not SQL). In Postgres it's `\q`; in MySQL it's `quit` or `exit`.
- **String literals use single quotes** (`'pending'`). This is standard SQL and applies to Postgres too.
- **Identifiers (table and column names) use double quotes** when they need quoting (`"order"` because `order` is a reserved word). In Postgres the same rule applies; MySQL uses backticks instead.
- **`LIKE` case sensitivity** differs: SQLite is case-insensitive for `LIKE` by default; Postgres is case-sensitive (use `ILIKE` for case-insensitive matching).
- SQLite has no separate `boolean` type — it stores `true`/`false` as `1`/`0`. Postgres has a proper `BOOLEAN` type.

---

## Maps to your wiki

These querying fundamentals are covered from an operational angle in the Postgres engine guides:

- [postgres/00-connect](../postgres/00-connect.md) — connecting to the mini-baas Postgres container, `psql` meta-commands (`\d`, `\dt`, `\q`), and one-shot `-c` queries
- [postgres/01-crud](../postgres/01-crud.md) — `SELECT`/`INSERT`/`UPDATE`/`DELETE` in depth, including filtering, ordering, and working with returning clauses

---

## Key takeaways

- Every read query starts with `SELECT` (columns) and `FROM` (table); `WHERE` narrows rows, `LIMIT` caps the count.
- Use `IS NULL` / `IS NOT NULL`, never `= NULL` — equality comparisons against `NULL` always produce `NULL`, silently dropping rows.
- `LIKE` with `%` (any sequence) and `_` (exactly one character) matches patterns; in Postgres prefer `ILIKE` when you want case-insensitive behaviour.
- `ORDER BY` without `LIMIT` sorts everything; with `LIMIT` it gives you "top N by some criterion."
- Aggregate functions (`COUNT`, `SUM`, `AVG`, `MIN`, `MAX`) collapse multiple rows into one value; `DISTINCT` de-duplicates before aggregating.
- `AS` renames columns in the output — essential for readability when aggregates are involved.
- SQLite (CS50's tool) and Postgres agree on all standard SQL covered here; the meaningful differences are `LIKE` case-sensitivity, dot-commands vs. backslash-commands, and how you connect.

---

> **Source & license.** Original study notes following *CS50's Introduction to Databases with SQL*, Lecture 0 — Querying (<https://cs50.harvard.edu/sql/notes/0/>). Course materials © President and Fellows of Harvard College, licensed [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/). These notes are an original summary in our own words; see the source for the canonical lecture.
