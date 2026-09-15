# Lesson 5 — Optimizing (CS50 SQL)

Queries that scan every row of a table are fine when the table holds a few hundred records.
Once the row-count climbs into the millions — orders piling up, customers accumulating — those
full scans become the bottleneck that grinds a feature to a halt.

This lesson is about giving the database engine a shortcut so it can find the rows you need
without reading the ones you don't. The two big tools are **indexes** (speed up lookups) and
**transactions** (keep concurrent writers from stepping on each other). Both topics are
surface-level here in CS50's SQLite world; the engine guides in this wiki go deeper for
production Postgres.

---

## What you'll learn

- What an index is and how to create or drop one
- How to measure whether a query actually improved
- The B-tree data structure that powers most indexes
- Indexes that span join conditions across tables
- Covering indexes — answering a query purely from the index itself
- The write-overhead and storage cost of indexing
- Partial indexes — indexing a carefully chosen slice of rows
- `VACUUM` — recovering disk space after deletes
- Transactions (`BEGIN` / `COMMIT` / `ROLLBACK`) and the ACID guarantees they encode
- Race conditions in concurrent workloads and the lock states that prevent them

---

## Indexes

Every query the database runs eventually becomes a *row search*. Without any additional
structure, the engine starts at row 1, checks the predicate, and repeats through to the last
row — a full table scan. An **index** is a separate, automatically-maintained lookup structure
that the engine builds alongside a table column (or set of columns). When you filter or join on
an indexed column, the engine consults the index first — like checking a book's index before
flipping through every page — and jumps straight to the relevant rows.

### Creating an index

```sql
-- Our shop gets many queries like: "what orders belong to this customer?"
-- Without an index, each lookup scans the entire orders table.
CREATE INDEX idx_orders_customer ON orders(customer_id);

-- Index the product catalogue by name for search autocomplete
CREATE INDEX idx_products_name ON products(name);
```

Naming convention used here: `idx_<table>_<column(s)>`. This is just a convention — the engine
doesn't care about the name, but humans do.

### Dropping an index

```sql
-- Drop when the index no longer pulls its weight (verified with EXPLAIN)
DROP INDEX idx_products_name;
```

Dropping is instantaneous; rebuilding is not. Drop only after you've confirmed the index is
unused, or before a large bulk-load operation.

---

## Measuring the impact

An index you *think* will help sometimes isn't used at all. The engine has a query planner that
chooses execution strategies, and it may decide a sequential scan is cheaper for a small table.
The only way to know for sure is to ask it.

### SQLite: `EXPLAIN QUERY PLAN` and `.timer on`

```sql
.timer on                          -- print wall-clock time after each statement
EXPLAIN QUERY PLAN
  SELECT * FROM orders WHERE customer_id = 42;
```

Before the index exists the plan reads something like `SCAN orders` — every row, no shortcut.
After `CREATE INDEX idx_orders_customer ON orders(customer_id)` the plan changes to
`SEARCH orders USING INDEX idx_orders_customer (customer_id=?)` — the engine is now using the
index.

### Postgres: `EXPLAIN ANALYZE` and `\timing`

```bash
docker exec -it mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

```sql
\timing on                        -- show elapsed time for every statement

EXPLAIN ANALYZE
  SELECT * FROM orders WHERE customer_id = 42;
```

`EXPLAIN ANALYZE` actually executes the query and reports the real time spent at each node of
the plan tree, along with the *estimated* vs *actual* row counts. Look for `Seq Scan` (no index)
versus `Index Scan` or `Bitmap Index Scan` (index used). The `Buffers` lines tell you how many
disk blocks were read.

---

## B-tree: the structure behind most indexes

Indexes need to be searched quickly themselves, otherwise they'd just be another thing to scan.
The standard solution is a **balanced tree** (B-tree). Picture a hierarchy of *internal nodes*,
each holding a sorted list of key values and pointers to child nodes. At the bottom, *leaf nodes*
hold the actual indexed values paired with pointers back to the table rows that contain them.

Because the tree is balanced — all leaf nodes sit at the same depth — the engine always reaches
any single key value in O(log n) steps, regardless of table size. Doubling the number of rows
barely increases the number of comparisons needed.

The "B" in B-tree stands for "balanced," not "binary" — a single node can hold many keys, which
is important for keeping the tree shallow and minimising disk I/O.

Postgres (and most server databases) also support **hash indexes**, which beat B-trees on
pure equality lookups but can't handle range queries (`<`, `>`, `BETWEEN`). SQLite exposes only
B-tree indexes to the user. When in doubt, a B-tree is the safe default.

---

## Indexes across multiple tables (speeding up JOINs)

A join between `orders` and `customers` works like a nested lookup: for each order, find the
matching customer. If neither join column is indexed, that inner lookup is a scan.

```sql
-- A typical JOIN: customer name on every order
SELECT c.name, o.status, o.created_at
  FROM orders o
  JOIN customers c ON c.id = o.customer_id
 WHERE o.status = 'shipped';

-- The engine will look up customers.id for each order row.
-- customers.id is already the primary key (indexed automatically).
-- The missing index is on orders.customer_id — the FK side of the join.
CREATE INDEX idx_orders_customer ON orders(customer_id);
```

After creating that index the plan for the join changes from two scans to an index lookup on the
FK column plus a fast primary-key lookup on the referenced table.

A rule of thumb: **foreign key columns are strong index candidates** because they appear in join
conditions in almost every multi-table query.

---

## Covering index

A regular index guides the engine to the right rows, but the engine must then go back to the
table to read any columns not in the index. A **covering index** includes all the columns a
specific query needs, so the engine never touches the main table at all.

```sql
-- Query: list every open order's ID and creation date for a given customer.
SELECT id, created_at
  FROM orders
 WHERE customer_id = 42 AND status = 'open';

-- A covering index bundles all three touched columns into one structure:
CREATE INDEX idx_orders_customer_open_covering
    ON orders(customer_id, status, id, created_at);
```

In the Postgres plan you'll see `Index Only Scan` instead of `Index Scan` — the "(only)" flag
means no heap fetch was needed. The query was answered entirely from the index pages.

Use covering indexes sparingly: each additional column in the index makes it wider and costlier
to maintain on every write. A covering index is most justified for a high-frequency, latency-
sensitive read path with a stable shape.

---

## Space and time trade-offs

Indexes are not free.

**Storage cost.** Each index is an independent on-disk data structure, typically 10–30 % the
size of the data it indexes (more for wide covering indexes). A table with five indexes
effectively has six copies of its key columns on disk.

**Write overhead.** Every `INSERT`, `UPDATE`, and `DELETE` must update every index on the
affected columns. A table with many indexes writes slowly. Bulk loads — like restoring from
a dump or running a large migration — are often faster if you drop indexes first, load the
data, and then rebuild the indexes with `CREATE INDEX` in one pass (the sort is more efficient
in bulk than row-by-row).

The discipline is: **add an index when a measured query is slow, not as a precaution**. Over-
indexing is a real problem that shows up as slow writes and ballooning disk usage.

---

## Partial index

A standard index covers every row in a table. A **partial index** (Postgres) or **filtered
index** (SQL Server) covers only the rows matching a `WHERE` clause baked into the index
definition. The result is a smaller, faster index that exactly targets the rows you actually
query.

```sql
-- Our shop's "open orders" dashboard only ever filters on status = 'open'.
-- Shipped, cancelled, and refunded orders are queried rarely and don't need
-- to burden this index.
CREATE INDEX idx_orders_open
    ON orders(customer_id, created_at)
 WHERE status = 'open';
```

This index may be ten times smaller than a full index on the same columns if most orders are
fulfilled and archived. For a query that includes `WHERE status = 'open'`, the engine can use
this partial index; for queries that omit the status filter it cannot, so the trade-off is
conscious: you're optimising a known, high-value access pattern.

SQLite supports partial indexes with the same syntax (the `WHERE` clause on `CREATE INDEX`).

---

## VACUUM

When you delete or update rows, the database doesn't immediately reclaim the disk space those
rows occupied. In SQLite, deleted rows leave behind *dead pages* that the engine skips over but
keeps around. Over time a write-heavy table can become physically fragmented.

`VACUUM` rebuilds the database file (or a single table in Postgres), reclaims the freed space,
and, as a side effect, rewrites data contiguously so sequential scans run faster.

```sql
-- SQLite: rebuilds the entire file, rewrites all live data compactly
VACUUM;

-- Postgres: reclaims dead row versions (tuples) and updates planner statistics.
-- FULL rewrites the table into a new file (locks the table; use sparingly).
VACUUM;          -- routine, runs concurrently, no lock
VACUUM FULL;     -- reclaims the most space but takes an exclusive lock
ANALYZE;         -- update the statistics the query planner uses for cost estimates
VACUUM ANALYZE;  -- combine both in one pass (common after a large bulk load)
```

Run `VACUUM` after large bulk deletes or imports. In Postgres, `autovacuum` handles routine
cleanup automatically; manual `VACUUM` is mainly needed after exceptional write events or to
prepare for index rebuilds.

---

## Concurrency: transactions and ACID

So far every query we've written has been a solo operation. Real applications have many clients
talking to the database simultaneously. Without any coordination, two writers editing the same
row at the same time can corrupt data.

A **transaction** is a named unit of work: a sequence of statements that the database treats as
a single, all-or-nothing operation.

```sql
-- Transfer a credit from one customer's balance to another (simplified).
-- Using the shop schema: move store credit between two customer rows.

BEGIN TRANSACTION;

  UPDATE customers SET credit_cents = credit_cents - 500 WHERE id = 1;
  UPDATE customers SET credit_cents = credit_cents + 500 WHERE id = 2;

COMMIT;
```

If the process crashes between the two `UPDATE` statements, the partial change is rolled back
automatically — as if neither statement ever ran.

To undo a transaction deliberately:

```sql
BEGIN TRANSACTION;

  DELETE FROM orders WHERE status = 'cancelled' AND created_at < '2024-01-01';

ROLLBACK;   -- nothing was deleted; we were just checking the row count
```

### ACID

The four guarantees that transactions provide:

| Letter | Guarantee | What it means in practice |
|--------|-----------|--------------------------|
| **A**tomicity | All or nothing | If the process dies mid-transaction, no partial change survives |
| **C**onsistency | Valid state before and after | Constraints (FK, CHECK, NOT NULL) are never left violated |
| **I**solation | Transactions don't see each other's in-progress work | Other sessions read the committed state, not your unfinished writes |
| **D**urability | Committed changes survive crashes | The WAL / journal file is flushed before `COMMIT` returns |

---

## Race conditions and locks

Imagine two warehouse workers both check the stock for product #7 at the same moment: both see
`stock = 1`. Both approve an order. Both decrement: `stock = stock - 1`. The final stock is `0`,
but two orders were placed — one item is oversold.

```sql
-- This read-then-write pattern is the classic race condition:
-- Thread A                        Thread B
-- SELECT stock FROM products      SELECT stock FROM products
--   WHERE id = 7;  → 1              WHERE id = 7;  → 1
-- UPDATE products                 UPDATE products
--   SET stock = stock - 1           SET stock = stock - 1
--   WHERE id = 7;                   WHERE id = 7;
-- stock is now 0                  stock is now 0 (lost update)
```

Transactions alone don't prevent this unless you also acquire the right **lock**.

### SQLite lock states

SQLite implements a **file-level locking** model. A connection moves through these states:

| Lock state | What it allows |
|------------|----------------|
| `UNLOCKED` | No access; the default when not in a transaction |
| `SHARED` | Reads only; many readers can hold this simultaneously |
| `RESERVED` | One writer has *announced intent* to write but hasn't locked yet; readers still allowed |
| `PENDING` | The writer is waiting for existing readers to finish; new readers are blocked |
| `EXCLUSIVE` | The writer owns the file; no other connection may read or write |

The strongest guard in SQLite is `BEGIN EXCLUSIVE TRANSACTION`, which jumps straight to the
`EXCLUSIVE` state:

```sql
BEGIN EXCLUSIVE TRANSACTION;

  SELECT stock FROM products WHERE id = 7;
  -- stock = 1, and we are the only connection that can modify the file right now
  UPDATE products SET stock = stock - 1 WHERE id = 7;

COMMIT;
```

Only one connection at a time can hold `EXCLUSIVE`, so the race condition cannot occur — the
second worker is blocked until the first commits.

The trade-off is throughput: `EXCLUSIVE` serialises all writers (and readers) for the duration.
For lightly-concurrent SQLite apps this is usually fine; for high-concurrency server workloads,
it's why you switch to Postgres.

### Postgres: MVCC and row-level locks

Postgres does not use file-level locks. Instead, it uses **Multi-Version Concurrency Control
(MVCC)**: each transaction sees a snapshot of the data as it existed at the start of the
transaction, and concurrent writers do not block readers.

To prevent the lost-update race condition in Postgres, you either:

1. Use `SELECT ... FOR UPDATE` to lock the specific rows you are about to modify, or
2. Rely on the `REPEATABLE READ` or `SERIALIZABLE` isolation level.

```sql
-- Postgres: lock the product row before reading stock, then update atomically
BEGIN;

  SELECT stock FROM products WHERE id = 7 FOR UPDATE;
  -- No other transaction can modify product 7 until we COMMIT or ROLLBACK
  UPDATE products SET stock = stock - 1 WHERE id = 7;

COMMIT;
```

See [postgres/08-transactions-isolation](../postgres/08-transactions-isolation.md) for the full
Postgres isolation levels, advisory locks, and deadlock detection.

---

## CS50 specifics

CS50's tooling for this lecture is **SQLite**, accessed through the `sqlite3` command-line shell
or DB Browser for SQLite. Key SQLite-specific details:

| Feature | SQLite | Postgres (our stack) |
|---------|--------|----------------------|
| Inspect query plan | `EXPLAIN QUERY PLAN <stmt>;` | `EXPLAIN ANALYZE <stmt>;` |
| Time a query | `.timer on` (shell meta-command) | `\timing` (psql meta-command) |
| Reclaim space | `VACUUM;` (rewrites the file) | `VACUUM;` / `VACUUM FULL;` |
| Exclusive lock | `BEGIN EXCLUSIVE TRANSACTION;` | `SELECT ... FOR UPDATE;` + MVCC |
| Partial index | `CREATE INDEX ... WHERE <expr>;` | same syntax |
| Covering index | index includes extra columns | `CREATE INDEX ... INCLUDE (col);` (Postgres 11+) or list in key |

**Datasets used in the lecture.** CS50 Lecture 5 works with `movies.db` (IMDb titles, ratings,
and directors) and `bank.db` (account balances and transfers). Neither lives in this repo — spin
up a throwaway SQLite container and follow along:

```bash
docker run --rm -it alpine sh -lc 'apk add --no-cache sqlite && sqlite3 movies.db'
```

---

## Maps to your wiki

The two topics this lesson introduces map directly to dedicated engine guides:

- **[postgres/03-indexes](../postgres/03-indexes.md)** — creating, introspecting, and dropping
  indexes in Postgres; `EXPLAIN ANALYZE` output explained; B-tree, hash, GIN, and GiST index
  types; `REINDEX`; monitoring unused indexes via `pg_stat_user_indexes`.

- **[postgres/08-transactions-isolation](../postgres/08-transactions-isolation.md)** — full ACID
  semantics in Postgres; isolation levels (`READ COMMITTED`, `REPEATABLE READ`, `SERIALIZABLE`);
  `SELECT ... FOR UPDATE` / `FOR SHARE`; deadlock detection; the difference between SQLite's
  file locks and Postgres's MVCC approach.

---

## Key takeaways

- An index is a sorted lookup structure that lets the engine skip irrelevant rows. Create one
  with `CREATE INDEX`; verify it's used with `EXPLAIN QUERY PLAN` (SQLite) or `EXPLAIN ANALYZE`
  (Postgres).
- B-trees balance depth so that any key is reachable in O(log n) comparisons, making indexes
  scale gracefully as tables grow.
- Foreign key columns on the "many" side of a join are the first place to look when a join is
  slow.
- A covering index bundles all the columns a query touches into one structure, enabling an
  index-only scan with no table access.
- Every index costs storage and slows writes — add indexes in response to measured slowness, not
  as a precaution.
- A partial index targets a subset of rows (`WHERE status = 'open'`), making it smaller and
  faster than a full-table index for queries with a stable filter.
- `VACUUM` reclaims disk space left by deletes; in Postgres, `autovacuum` handles this
  automatically during normal operation.
- A transaction wraps a group of statements into an atomic, consistent, isolated, and durable
  unit. Use `BEGIN` / `COMMIT` / `ROLLBACK`.
- Race conditions arise when two concurrent transactions read then write the same data without
  coordination. SQLite prevents this with file-level lock states (escalating to `EXCLUSIVE`);
  Postgres prevents it with `SELECT ... FOR UPDATE` and MVCC isolation levels.

---

> **Source & license.** Original study notes following *CS50's Introduction to Databases with SQL*, Lecture 5 — Optimizing (<https://cs50.harvard.edu/sql/notes/5/>). Course materials © President and Fellows of Harvard College, licensed [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/). These notes are an original summary in our own words; see the source for the canonical lecture.
