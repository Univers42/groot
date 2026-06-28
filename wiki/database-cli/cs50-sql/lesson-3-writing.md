# Lesson 3 — Writing (CS50 SQL)

So far the course has focused on reading data — running `SELECT` in various combinations to ask
questions of an existing database. Lecture 3 flips the perspective: now we put data *in*. Writing
means more than just inserting rows; it covers correcting mistakes (`UPDATE`), removing records
(`DELETE`), loading bulk data from flat files, and building automatic reactions to data changes
through triggers. It also introduces a habit that separates cautious engineers from the ones who
write frantic Slack messages at 2 a.m.: the soft-deletion pattern.

Every technique in this lesson operates on a live database, so think before you type. A missing
`WHERE` clause on a `DELETE` is not an interesting puzzle — it is just lost data.

---

## What you'll learn

- Add rows with `INSERT INTO … VALUES`, both column-by-column and in bulk
- Understand how database constraints defend your schema at write time
- Remove rows safely with `DELETE FROM … WHERE`, and understand what cascades mean for related tables
- Correct existing data with `UPDATE … SET … WHERE`
- Load a CSV file into SQLite with `.import --csv`, and know the rough server-side equivalents
- Write triggers that fire automatically before or after a data-change event
- Implement soft deletion so records can be "removed" without being destroyed

---

## INSERT INTO … VALUES

The most fundamental write operation adds a new row to a table. The two-part form makes the
contract explicit: first list the columns you are filling, then provide the corresponding values in
the same order.

```sql
-- Add a single customer
INSERT INTO customers (name, email, created_at)
VALUES ('Nadia Okonkwo', 'nadia@example.com', NOW());
```

Because `id` is defined as an auto-incrementing primary key, the database generates it — we skip
it in the column list and the engine fills it in. If you omit the column list entirely, you must
supply a value for every column in declaration order, including the key. Listing columns explicitly
is almost always the right choice: it protects you when the table schema evolves and a new column
lands between existing ones.

Column names and values form a pair. If you list three column names and supply two values, the
database rejects the statement with a column mismatch error rather than guessing which column you
forgot.

```bash
# Open Postgres to try these examples
docker exec -it mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

Once inside `psql`, you can run any of the SQL blocks below directly. For a clean practice space,
work against a scratch database rather than the production one (see the wiki README).

---

## Constraints in action

A constraint is a rule the database enforces at the storage layer. It does not matter how careful
the application code is — if a row violates a constraint, the `INSERT` is rejected and the
database explains why. Lecture 3 demonstrates two of the most common constraints in the context of
writes.

**NOT NULL** ensures a column always has a value. Attempt to insert a product with no name and
the engine refuses:

```sql
-- This will fail if products.name has a NOT NULL constraint
INSERT INTO products (name, price_cents, stock)
VALUES (NULL, 1500, 100);
-- ERROR: null value in column "name" violates not-null constraint
```

**UNIQUE** prevents two rows from sharing the same value in a column (or combination of columns).
Our `customers` table should have one row per email address:

```sql
-- First insert succeeds
INSERT INTO customers (name, email, created_at)
VALUES ('Jin Park', 'jin@example.com', NOW());

-- Second insert with the same email fails
INSERT INTO customers (name, email, created_at)
VALUES ('Jin Park (duplicate)', 'jin@example.com', NOW());
-- ERROR: duplicate key value violates unique constraint "customers_email_key"
```

### Primary-key auto-increment

Both SQLite and server engines generate primary-key values automatically, but they do it
differently.

In **SQLite**, a column declared `INTEGER PRIMARY KEY` becomes an alias for the internal `rowid`
— the engine assigns the next available integer without any extra keyword. Adding `AUTOINCREMENT`
(note: one word, all caps) makes SQLite guarantee the value is strictly increasing and never
reuses a deleted key. For most tables the bare `INTEGER PRIMARY KEY` form is sufficient; the
`AUTOINCREMENT` guarantee only matters when you need proof that a key value was never reused.

In **Postgres**, the idiomatic approach uses `SERIAL` (a shorthand that creates an integer column
and a sequence object) or the SQL-standard `GENERATED ALWAYS AS IDENTITY`. Either way, the engine
handles the counter; you do not insert a value for that column.

```sql
-- Postgres: show the generated id after inserting
INSERT INTO products (name, price_cents, stock)
VALUES ('Mechanical Keyboard', 8900, 42)
RETURNING id;
```

`RETURNING` is a Postgres extension (not available in standard SQLite) that lets you see
generated values immediately — useful when you need the new primary key to link a related row.

---

## Inserting multiple rows at once

`INSERT` accepts a comma-separated list of value tuples, so you can populate several rows in a
single statement rather than issuing one statement per row. Fewer round-trips to the database
mean faster bulk loads.

```sql
INSERT INTO products (name, price_cents, stock)
VALUES
    ('USB-C Hub',        3499,  200),
    ('Webcam HD',        5999,   85),
    ('Standing Desk Mat',1999,  300),
    ('Monitor Light',    2499,  120);
```

The database treats the entire statement as one unit: either all four rows land or none of them
do (assuming a transaction or if any row hits a constraint). This all-or-nothing behaviour is a
preview of transactional guarantees covered in Lesson 5.

---

## DELETE FROM … WHERE

Removing rows is straightforward to write and irreversible to undo. The pattern is:

```sql
DELETE FROM orders
WHERE status = 'cancelled'
  AND created_at < NOW() - INTERVAL '90 days';
```

The `WHERE` clause is what makes this safe. Without it, every row in the table disappears:

```sql
-- DO NOT run this in a live database — deletes every order
DELETE FROM orders;
```

A useful habit before running any destructive `DELETE` is to run the equivalent `SELECT` first to
confirm the row count and the rows themselves:

```sql
-- Verify scope before deleting
SELECT id, customer_id, status, created_at
FROM orders
WHERE status = 'cancelled'
  AND created_at < NOW() - INTERVAL '90 days';
```

If that `SELECT` returns what you expect, swap `SELECT … FROM` for `DELETE FROM` and run it.

### Foreign keys and ON DELETE CASCADE

When tables are related, deleting a parent row can leave orphaned child rows — orders that point
to a customer who no longer exists. Relational databases handle this through foreign-key
constraints combined with a deletion rule.

`ON DELETE CASCADE` tells the engine: if the parent row is deleted, automatically delete every
child row that references it. The cascade travels down the dependency chain.

```sql
-- Schema fragment showing the cascade relationship
CREATE TABLE customers (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL,
    email      TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE orders (
    id          SERIAL PRIMARY KEY,
    customer_id INT NOT NULL REFERENCES customers (id) ON DELETE CASCADE,
    product_id  INT NOT NULL REFERENCES products (id),
    qty         INT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'pending',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

With this schema in place, deleting a customer automatically removes all of that customer's orders.
No manual cleanup, no orphans. The trade-off is that the deletion is invisible unless you look at
the child table afterward — which is one reason soft deletion (covered below) is often preferred
when data must remain auditable.

Alternatives to `CASCADE`:
- `ON DELETE RESTRICT` (or the default `NO ACTION`) blocks the parent deletion if children exist.
- `ON DELETE SET NULL` nullifies the foreign-key column in child rows rather than deleting them.

---

## UPDATE … SET … WHERE

`UPDATE` changes the values of specific columns in rows that match a condition. The structure maps
directly to what you would say in plain language: "in this table, change these columns to these
values, but only for rows where this is true."

```sql
-- Restock a product after a shipment arrives
UPDATE products
SET stock = stock + 150
WHERE name = 'Webcam HD';
```

You can set multiple columns in one statement by separating them with commas in the `SET` clause:

```sql
-- Mark an order as shipped and log the transition
UPDATE orders
SET status     = 'shipped',
    created_at = NOW()
WHERE id = 7;
```

The same `WHERE`-first discipline applies here. `UPDATE products SET stock = 0` zeros out every
product's stock — no confirmation prompt, no undo. Always write the `WHERE` clause first, then the
`SET`, as a mental forcing function.

---

## Importing data from CSV

Real-world data rarely arrives through hand-typed `INSERT` statements. More often it comes as a
CSV export from a spreadsheet, an old system, or a data team pipeline. Loading that file
efficiently requires a different approach than row-by-row inserts.

### SQLite: `.import --csv`

In SQLite's interactive shell, the `.import` dot-command loads a delimited file directly into a
table. The `--csv` flag tells the parser to interpret commas and quoted fields according to the
CSV standard rather than treating the whole line as a single value.

```
-- Inside sqlite3 shell (not SQL — these are dot-commands)
.mode csv
.import /path/to/new_customers.csv customers
```

The `--csv` form (available in SQLite 3.32+) is cleaner:

```
.import --csv --skip 1 /path/to/new_customers.csv customers
```

`--skip 1` discards the header row so column names do not land in your data. The file's column
order must match the table's column order exactly, unless you use a staging table and then
`INSERT … SELECT` to remap columns.

### Server engines: a brief map

Server databases move the import work to the engine process rather than the client shell, which
makes large files far faster. They also enforce constraints row-by-row as data arrives.

- **Postgres `\copy` (psql client-side):** reads the file on the *client* machine and streams it
  over the connection. Works without superuser privileges.

  ```sql
  \copy customers (name, email, created_at)
    FROM '/local/path/new_customers.csv'
    WITH (FORMAT csv, HEADER true);
  ```

- **Postgres `COPY` (server-side):** reads the file on the *server* machine. Requires superuser
  or `pg_read_server_files` role. Much faster for very large files because no network round-trip.

  ```sql
  COPY customers (name, email, created_at)
    FROM '/docker-internal/path/new_customers.csv'
    WITH (FORMAT csv, HEADER true);
  ```

- **MySQL `LOAD DATA INFILE`:** similar server-side bulk loader with its own privilege (`FILE`).

For full runbooks on backup and CSV-style data movement in our stack, see the engine-specific
guides linked in the "Maps to your wiki" section below.

---

## Triggers

A trigger is a named action stored inside the database that fires automatically when a specific
event occurs on a specific table. You write the trigger once; the engine runs it every time the
event happens, without the application needing to remember to call anything.

Triggers have three moving parts:

1. **Timing** — does the action run `BEFORE` or `AFTER` the event?
2. **Event** — `INSERT`, `UPDATE`, or `DELETE`.
3. **Body** — a `BEGIN … END` block of SQL (or a function call in Postgres).

Inside the body, two virtual rows are available:
- `NEW` — the row as it will look after the operation (available in `INSERT` and `UPDATE`).
- `OLD` — the row as it looked before the operation (available in `UPDATE` and `DELETE`).

### SQLite trigger example

Track every time an order's status changes — write an audit row automatically:

```sql
-- SQLite syntax
CREATE TABLE order_audit (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id   INTEGER NOT NULL,
    old_status TEXT,
    new_status TEXT NOT NULL,
    changed_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TRIGGER log_order_status_change
AFTER UPDATE OF status ON orders
FOR EACH ROW
WHEN OLD.status != NEW.status
BEGIN
    INSERT INTO order_audit (order_id, old_status, new_status)
    VALUES (OLD.id, OLD.status, NEW.status);
END;
```

`FOR EACH ROW` means the trigger fires once per affected row. SQLite does not support statement-
level triggers (which would fire once per statement regardless of how many rows changed).

The `WHEN` clause acts as an extra filter: the `BEGIN … END` block runs only when the condition
is true. Here we skip no-op updates where the status did not actually change.

### Postgres trigger example

Postgres separates the trigger from its logic. The body lives in a function that returns
`TRIGGER`, and the `CREATE TRIGGER` statement wires that function to an event:

```sql
-- Postgres: function first, then the trigger
CREATE OR REPLACE FUNCTION fn_log_order_status()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO order_audit (order_id, old_status, new_status)
        VALUES (OLD.id, OLD.status, NEW.status);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_order_status_change
AFTER UPDATE OF status ON orders
FOR EACH ROW
EXECUTE FUNCTION fn_log_order_status();
```

`RETURN NEW` from the function is required for row-level `AFTER` triggers even though the return
value is ignored for `AFTER` events (for `BEFORE` triggers it controls what actually gets written).

### BEFORE vs AFTER

`BEFORE` triggers run before the row is written. They can modify `NEW` to change what gets stored
(useful for normalising data or computing a derived column), or they can raise an exception to
abort the operation entirely.

`AFTER` triggers run after the row is already written and visible in the current transaction. They
are the right choice for side-effects like audit logging, notifying another table, or cascading a
business rule — because the primary change is committed first.

---

## Soft deletions

Physically deleting a row is permanent unless you have a backup. In many systems — audit trails,
billing, support escalations — you need to be able to ask "what happened to that order?" after
a customer cancels. Destroying the row makes that question unanswerable.

Soft deletion sidesteps the problem by never actually removing the row. Instead, a flag column
marks the record as logically gone:

```sql
-- Add a soft-delete column to orders
ALTER TABLE orders ADD COLUMN deleted_at TIMESTAMPTZ;
```

"Deleting" an order now means setting that timestamp:

```sql
UPDATE orders
SET deleted_at = NOW()
WHERE id = 42;
```

The row stays in the table. Your application queries filter it out of normal results:

```sql
-- Normal view: only live orders
SELECT * FROM orders
WHERE deleted_at IS NULL;

-- Audit view: everything, including deleted
SELECT * FROM orders;

-- Recovery: un-delete if needed
UPDATE orders
SET deleted_at = NULL
WHERE id = 42;
```

Some teams use a boolean `is_deleted` column instead of a timestamp. The timestamp carries more
information (when it happened) without costing much extra, so it is usually the better choice.

### The trade-off

Soft deletion keeps data safe and reversible, but it adds complexity everywhere. Every query that
should show "active" records must include `WHERE deleted_at IS NULL`. Miss that clause once and
deleted records bleed into a report. A common mitigation is to create a view that bakes the filter
in:

```sql
CREATE VIEW active_orders AS
SELECT * FROM orders WHERE deleted_at IS NULL;
```

Application code queries `active_orders` instead of `orders`. Only administrative queries go
directly to the base table. Views are covered in detail in Lesson 4.

---

## CS50 specifics

The course uses **SQLite** as its teaching engine — a single `.db` file opened in the `sqlite3`
CLI (or in a VS Code extension). There is no server, no network connection, no credentials. You
open a file, write SQL, close it. This makes the setup frictionless for learning.

For Lecture 3, the course works with a museum collection dataset from the **Boston Museum of Fine
Arts** — tables covering `collections`, `artists`, `created` (the join table linking artists to
works), and `transactions` (acquisition and sale records for artworks). The writing exercises load
new acquisitions, update provenance records, and delete de-accessioned works. The data is rich
enough that constraint violations and cascade scenarios arise naturally from real-world
messiness in the records.

The `.import --csv` dot-command is demonstrated by loading a CSV of new acquisitions into the
`collections` table — the same operation we mapped above to `\copy` in Postgres.

If you want to follow along in SQLite without installing anything on the host:

```bash
docker run --rm -it alpine sh -lc 'apk add --no-cache sqlite && sqlite3 /tmp/museum.db'
```

SQLite syntax notes that differ from what you will use in our Postgres stack:

| Concept | SQLite | Postgres |
|---|---|---|
| Auto-increment key | `INTEGER PRIMARY KEY` or `INTEGER PRIMARY KEY AUTOINCREMENT` | `SERIAL` / `GENERATED ALWAYS AS IDENTITY` |
| Current timestamp | `datetime('now')` | `NOW()` / `CURRENT_TIMESTAMP` |
| Trigger function | Inline `BEGIN … END` inside `CREATE TRIGGER` | Separate `CREATE FUNCTION … RETURNS TRIGGER` |
| `RETURNING` clause | Not available (use `last_insert_rowid()`) | Available natively |
| CSV load | `.import --csv` dot-command | `\copy` (client) or `COPY` (server) |

---

## Maps to your wiki

The write operations in this lesson map directly to the CRUD guide for each engine:

- **[postgres/01-crud](../postgres/01-crud.md)** — `INSERT`, `UPDATE`, `DELETE`, and `UPSERT`
  (`INSERT … ON CONFLICT`) with Postgres-specific syntax, `RETURNING`, and copy-pasteable
  examples against our shop schema.

- **[postgres/07-backup-restore](../postgres/07-backup-restore.md)** — covers `pg_dump`,
  `pg_restore`, and `\copy` for moving data in and out of Postgres, which is the server-side
  counterpart to SQLite's `.import --csv` explored in this lesson.

For MySQL and SQL Server equivalents (`LOAD DATA INFILE`, `BULK INSERT`, `MERGE`), see the
corresponding engine guides under `../mysql/` and `../mssql/`.

---

## Key takeaways

- Always list target columns explicitly in `INSERT` statements — it protects against schema drift
  and makes intent clear.
- Constraints (`NOT NULL`, `UNIQUE`, foreign keys) enforce correctness at the storage layer, not
  the application layer; they are your last line of defence.
- Write the `WHERE` clause *before* you write the rest of a `DELETE` or `UPDATE`. Confirm scope
  with a `SELECT` first when in doubt.
- `ON DELETE CASCADE` keeps referential integrity automatically but silently destroys data — know
  which parent deletions carry children before you define the cascade.
- Triggers automate reactions to data changes; keep their logic simple and auditable — a trigger
  body that calls three other triggers becomes very hard to debug.
- Soft deletion trades storage space for safety and reversibility. Use a `deleted_at` timestamp
  over a boolean flag to capture *when*, not just *whether*.
- SQLite and server engines share the same SQL writing concepts; the differences are syntax
  (trigger form, auto-increment keyword) and tooling (`.import --csv` vs `\copy`/`COPY`).

---

> **Source & license.** Original study notes following *CS50's Introduction to Databases with SQL*, Lecture 3 — Writing (<https://cs50.harvard.edu/sql/notes/3/>). Course materials © President and Fellows of Harvard College, licensed [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/). These notes are an original summary in our own words; see the source for the canonical lecture.
