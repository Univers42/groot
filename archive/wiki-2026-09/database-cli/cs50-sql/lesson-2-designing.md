# Lesson 2 — Designing (CS50 SQL)

Knowing how to *query* a database and knowing how to *build* one are separate skills. Lesson 1 handed you an already-formed schema and taught you to navigate it. This lesson starts one step earlier: you are the person who decides what tables to create, what columns live in them, what types those columns carry, and what rules prevent bad data from ever landing in the first place.

Good design is mostly about asking the right questions before writing a single `CREATE TABLE`. Bad design is cheap to prototype and expensive to fix once there is real data in it.

---

## What you'll learn

- How to identify the entities in a problem domain and sketch a first schema
- Why normalization matters and how splitting tables removes redundancy
- `CREATE TABLE` and `DROP TABLE` — the basics of DDL
- SQLite's type affinity system versus the strict column types in server engines
- Table-level constraints: `PRIMARY KEY`, `FOREIGN KEY … REFERENCES`
- Column-level constraints: `NOT NULL`, `UNIQUE`, `CHECK`, `DEFAULT`
- `ALTER TABLE` — renaming, adding, and dropping columns after the fact
- Many-to-many relationships and how a junction table resolves them

---

## Identifying entities and designing a schema

The first question is not "what columns do I need?" — it is "what *things* does this system track?" Each distinct real-world concept that has properties of its own becomes a table. Each table's rows represent individual instances of that concept.

For a small online shop, the obvious entities are:

- A **customer** who places orders (has a name, an email, a sign-up date)
- A **product** that can be ordered (has a name, a price, a stock count)
- An **order** that records one purchase event (links a customer to a product, carries quantity and status)

Before writing SQL, ask yourself:

1. Can a single row in this table stand alone, or does it only make sense attached to another row? (If the latter, it probably needs a foreign key.)
2. Is any piece of information repeated across multiple rows? (If yes, that data belongs in its own table.)
3. What can never be empty? What must be unique? What must stay within a range?

Answering these questions turns a vague domain description into concrete constraints, which is most of what `CREATE TABLE` actually expresses.

---

## CREATE TABLE and DROP TABLE

`CREATE TABLE` declares the structure of a table — its column names, the type each column holds, and any constraints. Nothing is stored yet; you are defining the shape.

```sql
-- Run inside a scratch Postgres session:
-- docker exec -it mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'

CREATE TABLE customers (
    id         SERIAL      PRIMARY KEY,
    name       VARCHAR(120) NOT NULL,
    email      VARCHAR(255) NOT NULL UNIQUE,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE products (
    id          SERIAL  PRIMARY KEY,
    name        VARCHAR(200) NOT NULL,
    price_cents INT     NOT NULL CHECK (price_cents >= 0),
    stock       INT     NOT NULL DEFAULT 0 CHECK (stock >= 0)
);

CREATE TABLE orders (
    id          SERIAL      PRIMARY KEY,
    customer_id INT         NOT NULL REFERENCES customers(id),
    product_id  INT         NOT NULL REFERENCES products(id),
    qty         INT         NOT NULL CHECK (qty > 0),
    status      VARCHAR(20) NOT NULL DEFAULT 'pending',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

`DROP TABLE` removes the table and every row it contains. It is irreversible without a backup, so treat it with the same caution you would a production `DELETE`.

```sql
-- Dropping a table that other tables reference via FOREIGN KEY will fail
-- unless you also drop or alter those tables first.
DROP TABLE orders;
DROP TABLE products;
DROP TABLE customers;
```

In SQLite (the engine CS50 uses), the same `CREATE TABLE` and `DROP TABLE` syntax works, though some type names and constraint details differ — covered below.

---

## Data types, storage classes, and the SQLite affinity system

This is where SQLite diverges most sharply from server engines, and understanding the gap saves real debugging time.

### SQLite: five affinities, not rigid column types

SQLite does not enforce that a value stored in a column matches the column's declared type. Instead, it maps type names to one of five *affinities* and uses that affinity only as a *hint* about how to coerce ambiguous values. The five affinities are:

| Affinity  | What SQLite does with a value |
|-----------|-------------------------------|
| TEXT      | Stores strings; numbers coerced to TEXT |
| NUMERIC   | Prefers storing integers or reals; TEXT coerced if it looks like a number |
| INTEGER   | Coerces to integer if lossless; otherwise stores as REAL or TEXT |
| REAL      | Always stores as an 8-byte IEEE float |
| BLOB      | Stores without any conversion (raw bytes, or anything) |

The underlying *storage classes* are: `NULL`, `INTEGER`, `REAL`, `TEXT`, and `BLOB`. The storage class of a value is determined at the time the value is inserted, not by the column definition. You can legally insert the string `'hello'` into an `INTEGER` column — SQLite will store it as TEXT and not complain.

This is intentional: SQLite was designed to be permissive and embeddable. For a local prototype it is convenient. For a multi-user service where bad data must be caught at the database layer, it is a footgun.

### Server engines: types are enforced at write time

PostgreSQL, MySQL, and SQL Server all enforce column types strictly. If you declare a column `INT` and attempt to insert `'hello'`, the server rejects the write with a type error. There is no affinity system — the column type is a hard contract.

Side-by-side comparison for our shop schema:

| Concept       | SQLite (affinity)         | PostgreSQL (strict)          | MySQL (strict)              |
|---------------|---------------------------|------------------------------|-----------------------------|
| Auto-increment primary key | `INTEGER PRIMARY KEY` (implicit rowid alias) | `SERIAL PRIMARY KEY` or `GENERATED ALWAYS AS IDENTITY` | `INT AUTO_INCREMENT PRIMARY KEY` |
| Short string  | `TEXT`                    | `VARCHAR(n)` or `TEXT`       | `VARCHAR(n)` or `TEXT`      |
| Integer price | `INTEGER` or `NUMERIC`    | `INT` or `BIGINT`            | `INT`                       |
| Decimal price | `REAL` or `NUMERIC`       | `NUMERIC(10,2)`              | `DECIMAL(10,2)`             |
| Timestamp     | `TEXT` (ISO-8601 string) or `NUMERIC` (Unix epoch) | `TIMESTAMPTZ` (timezone-aware) | `DATETIME` or `TIMESTAMP`   |
| Binary blob   | `BLOB`                    | `BYTEA`                      | `BLOB`                      |

The practical advice: design your types as if the server enforces them (because in production it will), even when you are learning on SQLite. Pick the most specific type that fits the data — `INT` for counts, `NUMERIC(10,2)` for money, `TIMESTAMPTZ` for event times — so the schema communicates intent and server engines enforce it.

---

## Table constraints: PRIMARY KEY and FOREIGN KEY

Constraints are promises the database enforces on your behalf. Table constraints apply to one or more columns together.

### PRIMARY KEY

Every table should have a primary key — a column (or combination of columns) whose value uniquely identifies each row and is never null. The database builds an index on the primary key automatically.

```sql
-- Single-column primary key (most common):
CREATE TABLE customers (
    id   SERIAL PRIMARY KEY,
    name VARCHAR(120) NOT NULL
    -- ...
);

-- Composite primary key (useful for pure junction tables):
CREATE TABLE order_tags (
    order_id INT REFERENCES orders(id),
    tag      VARCHAR(50),
    PRIMARY KEY (order_id, tag)
);
```

In SQLite, declaring a column `INTEGER PRIMARY KEY` makes it an alias for the internal `rowid`, which auto-increments. For everything else, use `AUTOINCREMENT` explicitly if you need gaps to never be reused — but be aware server engines have their own idioms (`SERIAL`, `IDENTITY`) and the keyword `AUTOINCREMENT` does not exist in PostgreSQL.

### FOREIGN KEY … REFERENCES

A foreign key tells the database that the values in one column must match values that exist in another table's primary (or unique) key. It is the mechanism by which rows in different tables relate to each other.

```sql
CREATE TABLE orders (
    id          SERIAL PRIMARY KEY,
    customer_id INT NOT NULL REFERENCES customers(id),
    product_id  INT NOT NULL REFERENCES products(id),
    qty         INT NOT NULL,
    status      VARCHAR(20) NOT NULL DEFAULT 'pending',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

With this definition in place, an `INSERT` into `orders` that supplies a `customer_id` that does not exist in `customers` will be rejected. This is referential integrity — you cannot have an order that points to a ghost customer.

**SQLite caveat.** Foreign key enforcement is *off by default* in SQLite. You must run `PRAGMA foreign_keys = ON;` at the start of each connection for the constraints to be checked. Server engines enforce foreign keys by default.

```bash
# Postgres: verify referential integrity is live by trying a bad insert
docker exec -it mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "INSERT INTO orders (customer_id, product_id, qty) VALUES (9999, 1, 1);"'
# Expected: ERROR: insert or update on table "orders" violates foreign key constraint
```

---

## Column constraints: NOT NULL, UNIQUE, CHECK, DEFAULT

Column constraints narrow what values a single column may hold.

### NOT NULL

Declares that the column must always carry a value — `NULL` (the absence of a value) is not permitted. Apply it to any column where "unknown" would be a data quality bug rather than a valid state.

```sql
-- email must always be supplied; we cannot have a customer with no email
email VARCHAR(255) NOT NULL
```

Without `NOT NULL`, the column is implicitly nullable. A nullable column is a legitimate choice when absence of a value is meaningful (e.g., `cancelled_at TIMESTAMPTZ` — null means "not yet cancelled").

### UNIQUE

Guarantees no two rows hold the same value in this column (or combination of columns). The database creates a unique index to enforce this efficiently.

```sql
-- No two customers may share an email address
email VARCHAR(255) NOT NULL UNIQUE
```

A primary key is implicitly unique and not null. `UNIQUE` without `NOT NULL` allows multiple nulls in most engines (null is not equal to null by SQL's three-valued logic).

### CHECK

Allows you to express an arbitrary boolean condition that every row must satisfy. Useful for domain rules that are tighter than the column type alone.

```sql
-- Price can never be negative
price_cents INT NOT NULL CHECK (price_cents >= 0),

-- Quantity on an order must be at least one
qty INT NOT NULL CHECK (qty > 0),

-- Status must be one of a small set of strings
status VARCHAR(20) NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'paid', 'shipped', 'cancelled'))
```

`CHECK` constraints run at insert and update time. If the condition evaluates to false, the write is rejected. If it evaluates to null (because one of its operands is null), most engines silently allow the row — another reason to combine `CHECK` with `NOT NULL` for critical columns.

### DEFAULT

Sets the value the column receives when an `INSERT` omits it. Without a `DEFAULT`, omitting a nullable column stores `NULL`; omitting a `NOT NULL` column without a default is an error.

```sql
-- stock starts at zero if not specified
stock INT NOT NULL DEFAULT 0,

-- created_at is set to the current time if not specified
created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
```

`DEFAULT CURRENT_TIMESTAMP` is the SQL standard form; `DEFAULT NOW()` is a Postgres alias that also works. In SQLite, `DEFAULT CURRENT_TIMESTAMP` produces a UTC string in `'YYYY-MM-DD HH:MM:SS'` format — a TEXT value, not a typed timestamp.

---

## ALTER TABLE — evolving a schema after the fact

Schemas rarely come out perfect on the first attempt, and real systems change over time. `ALTER TABLE` lets you modify an existing table without recreating it (and losing data).

### Rename the table itself

```sql
-- You shipped with a typo; fix it without touching the data
ALTER TABLE custommers RENAME TO customers;
```

### Add a column

New columns are appended at the end. Existing rows receive the column's `DEFAULT` value (or `NULL` if there is no default).

```sql
-- Track whether a customer has confirmed their email
ALTER TABLE customers ADD COLUMN email_verified BOOLEAN NOT NULL DEFAULT FALSE;

-- Add a soft-delete timestamp (nullable = not yet deleted)
ALTER TABLE customers ADD COLUMN deleted_at TIMESTAMPTZ;
```

### Rename a column

```sql
-- price_cents was confusing; rename it for clarity
ALTER TABLE products RENAME COLUMN price_cents TO unit_price_cents;
```

### Drop a column

```sql
-- Remove a column that is no longer needed
ALTER TABLE products DROP COLUMN discontinued_flag;
```

**SQLite limitation.** SQLite added `RENAME COLUMN` in version 3.25 (2018) and `DROP COLUMN` in version 3.35 (2021). Older SQLite installations still require the workaround of creating a new table with the desired schema, copying data, dropping the old table, and renaming the new one. Server engines have supported the full `ALTER TABLE` syntax for much longer.

---

## Normalization and many-to-many via junction tables

Normalization is the practice of organizing a schema so that each fact is stored exactly once. When the same piece of data lives in multiple places, updates must touch every copy — and when they don't, the database contains contradictions.

### The redundancy test

Suppose you tried to store the shop in a single flat table:

```text
flat_orders(order_id, customer_name, customer_email, product_name, product_price_cents, qty, status)
```

If customer Alice changes her email, you must update every row where `customer_name = 'Alice'`. Miss one and you have inconsistent data. The fix is to split the table so Alice's email lives in exactly one row of a `customers` table, and every order row just references Alice by her `id`. This is the core idea behind normalization: **move repeating facts into their own tables and replace the fact with a key**.

The three-table shop schema already applies this:

- Customer details live in `customers`; orders carry only `customer_id`
- Product details live in `products`; orders carry only `product_id`
- `orders` stores only the facts that are unique to each purchase event

### Many-to-many relationships

The `orders` table as written records one product per order. A real shop order usually contains multiple products. This is a many-to-many relationship: one order has many products, and one product appears in many orders.

A direct link between two tables cannot model many-to-many — a single foreign key column can hold only one value. The standard solution is a **junction table** (also called an associative table or bridge table) that sits between the two entities and holds one row per pair.

```sql
-- Rename the existing orders table to represent the order header
ALTER TABLE orders RENAME TO order_headers;

-- The junction table: one row per (order, product) line item
CREATE TABLE order_items (
    order_id    INT NOT NULL REFERENCES order_headers(id),
    product_id  INT NOT NULL REFERENCES products(id),
    qty         INT NOT NULL CHECK (qty > 0),
    unit_price_cents INT NOT NULL CHECK (unit_price_cents >= 0),
    PRIMARY KEY (order_id, product_id)
);
```

Now `order_headers` records who ordered and when; `order_items` records what was ordered and how many of each. A query that needs the full picture joins all three tables:

```sql
SELECT
    oh.id          AS order_id,
    c.name         AS customer,
    p.name         AS product,
    oi.qty,
    oi.unit_price_cents
FROM order_headers oh
JOIN customers   c  ON c.id = oh.customer_id
JOIN order_items oi ON oi.order_id = oh.id
JOIN products    p  ON p.id = oi.product_id
ORDER BY oh.id, p.name;
```

```bash
# Run it against the running Postgres container:
docker exec -it mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "SELECT oh.id AS order_id, c.name AS customer, p.name AS product,
             oi.qty, oi.unit_price_cents
      FROM order_headers oh
      JOIN customers   c  ON c.id = oh.customer_id
      JOIN order_items oi ON oi.order_id = oh.id
      JOIN products    p  ON p.id = oi.product_id
      ORDER BY oh.id, p.name;"'
```

The junction table pattern generalizes: any time you find yourself wanting to put a comma-separated list of IDs in a single column, that is the signal to create a junction table instead.

---

## CS50 specifics

CS50's Lecture 2 teaches all of this using **SQLite** and the **Boston MBTA subway** dataset — stations, lines, and the stops that connect them. The many-to-many between lines and stations (a line has many stations; a station can be on many lines) is the lecture's running example of a junction table.

In the CS50 environment you open a `.db` file with:

```bash
sqlite3 mbta.db
```

and inspect the schema with:

```text
.schema
```

`.schema` prints the `CREATE TABLE` statements for every table in the file. The Postgres equivalent is `\d` (list all relations) or `\d tablename` (describe one table):

```bash
docker exec -it mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "\d customers"'
```

### Type affinity recap

In CS50's SQLite examples you will see type names like `INTEGER`, `TEXT`, `REAL`, and `NUMERIC` used loosely — the lecture often writes `INTEGER` for an auto-increment PK and `TEXT` for everything else. That works in SQLite because the affinity system is forgiving. When you move the same `CREATE TABLE` to Postgres:

- Replace `INTEGER PRIMARY KEY AUTOINCREMENT` with `SERIAL PRIMARY KEY` (or `BIGSERIAL` for large tables)
- Replace bare `TEXT` with `VARCHAR(n)` where a max length is appropriate, or keep `TEXT` (Postgres `TEXT` is a legitimate unbounded string type)
- Replace `REAL` with `NUMERIC(p,s)` for money to avoid floating-point rounding
- Replace SQLite date strings with `TIMESTAMPTZ` for proper timezone-aware timestamps

---

## Maps to your wiki

The DDL concepts here (creating tables, adding constraints, altering structure) map directly to the first section of each engine's CRUD guide:

- [postgres/01-crud](../postgres/01-crud.md) — `CREATE TABLE`, `INSERT`, `SELECT`, `UPDATE`, `DELETE` in Postgres
- [mysql/01-crud](../mysql/01-crud.md) — the same in MySQL/MariaDB, including `AUTO_INCREMENT` and MySQL type names

Those guides also show how to set up a scratch `learn_cli` database so you can run destructive DDL without touching real data.

---

## Key takeaways

- **Design before you code.** Identify entities, list their properties, decide what can be null, what must be unique, and how tables relate before writing DDL.
- **Normalization removes redundancy** by ensuring each fact lives in exactly one place and is referenced everywhere else by a key.
- **SQLite's type affinity is flexible; server engines are strict.** Both accept the same SQL keywords, but only server engines reject bad types at write time. Design for strictness even when prototyping.
- **Constraints are documentation the database enforces.** `NOT NULL`, `UNIQUE`, `CHECK`, `DEFAULT`, `FOREIGN KEY` — each one expresses a rule that would otherwise need application-layer code and is enforced reliably by the database regardless of which client writes to it.
- **`ALTER TABLE` is how schemas evolve.** Add columns with safe defaults, rename before deleting, and be aware that SQLite's `ALTER TABLE` support is more limited than server engines.
- **Many-to-many means junction table.** Never store comma-separated IDs. Create a bridge table with foreign keys to both sides and a composite primary key.

---

> **Source & license.** Original study notes following *CS50's Introduction to Databases with SQL*, Lecture 2 — Designing (<https://cs50.harvard.edu/sql/notes/2/>). Course materials © President and Fellows of Harvard College, licensed [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/). These notes are an original summary in our own words; see the source for the canonical lecture.
