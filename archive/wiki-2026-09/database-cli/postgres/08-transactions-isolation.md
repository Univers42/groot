# Transactions and Isolation

After this file you can group statements into atomic units, roll back to mid-transaction
checkpoints with SAVEPOINTs, choose the right isolation level for concurrent workloads,
and use `SELECT ... FOR UPDATE` to prevent lost updates.

## Prerequisite

`learn_cli` must exist with the shop schema and data (see [01-crud.md](01-crud.md)).

## What a transaction guarantees

A transaction is the unit of ACID:

| Property | Meaning |
|----------|---------|
| **Atomicity** | All statements commit together or none do |
| **Consistency** | Constraints are enforced at commit |
| **Isolation** | Concurrent transactions see a consistent snapshot |
| **Durability** | Committed data survives crashes |

## BEGIN / COMMIT / ROLLBACK

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
BEGIN;
UPDATE products SET stock = stock - 2 WHERE id = 1;
INSERT INTO orders (customer_id, product_id, qty, status)
  VALUES (2, 1, 2, '"'"'pending'"'"') RETURNING id;
COMMIT;"'
```

Expected:
```
BEGIN
UPDATE 1
 id
----
  5
(1 row)

INSERT 0 1
COMMIT
```

Everything between `BEGIN` and `COMMIT` is atomic. If the connection drops before `COMMIT`,
PostgreSQL rolls back automatically.

### ROLLBACK — abort the whole transaction

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
BEGIN;
DELETE FROM orders WHERE customer_id = 1;
SELECT COUNT(*) FROM orders;   -- shows 0 (within the transaction)
ROLLBACK;
SELECT COUNT(*) FROM orders;   -- back to original count"'
```

```
BEGIN
DELETE 2
 count
-------
     3
(1 row)

ROLLBACK
 count
-------
     5
(1 row)
```

## SAVEPOINT — partial rollback

`SAVEPOINT` marks a named checkpoint within a transaction. `ROLLBACK TO SAVEPOINT` undoes
everything since the savepoint without aborting the whole transaction.

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
BEGIN;
UPDATE products SET stock = stock - 2 WHERE id = 1;
SAVEPOINT after_destock;

INSERT INTO orders (customer_id, product_id, qty, status)
  VALUES (99, 1, 2, '"'"'pending'"'"');   -- customer 99 does not exist → FK error expected

ROLLBACK TO SAVEPOINT after_destock;   -- undo just the bad INSERT

SELECT stock FROM products WHERE id = 1;   -- destock still applied

COMMIT;"'
```

Expected:
```
BEGIN
UPDATE 1
SAVEPOINT
ERROR:  insert or update on table "orders" violates foreign key constraint ...
ROLLBACK
 stock
-------
    46
(1 row)

COMMIT
```

`ROLLBACK TO SAVEPOINT` lets you recover from an individual statement error without losing
the work done before the savepoint.

### RELEASE SAVEPOINT — discard a no-longer-needed savepoint

```bash
# pattern (unverified here — no active transaction in one-shot mode)
-- RELEASE SAVEPOINT after_destock;
```

Releasing frees the memory used to track the savepoint. It does not commit.

## The four isolation levels

PostgreSQL implements four levels of transaction isolation, each preventing a different
class of concurrency anomaly:

| Level | Dirty Read | Non-repeatable Read | Phantom Read |
|-------|-----------|---------------------|--------------|
| READ UNCOMMITTED | prevented (PG never allows) | possible | possible |
| READ COMMITTED (default) | prevented | possible | possible |
| REPEATABLE READ | prevented | prevented | prevented (PG) |
| SERIALIZABLE | prevented | prevented | prevented |

PostgreSQL never allows dirty reads regardless of the isolation level you set.

### SET TRANSACTION ISOLATION LEVEL

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT id, stock FROM products WHERE id = 1;
-- any concurrent UPDATE to products will NOT be visible in this snapshot
COMMIT;"'
```

```
BEGIN
SET
 id | stock
----+-------
  1 |    46
(1 row)

COMMIT
```

### Default: READ COMMITTED

The default is `READ COMMITTED`: each statement inside the transaction sees the most recently
committed rows at the time that statement starts. Two SELECT statements in the same
transaction may see different data if a concurrent transaction commits between them.

### When to use each level

| Level | Use when |
|-------|---------|
| READ COMMITTED | Most OLTP workloads — the default is fine |
| REPEATABLE READ | One transaction reads the same table multiple times and needs a stable snapshot; report generation |
| SERIALIZABLE | Financial transfers, inventory deductions — where read-then-write correctness is mandatory |

## SELECT ... FOR UPDATE — row-level locking

`FOR UPDATE` acquires a row-level exclusive lock. Other transactions trying to update or
lock the same rows will wait.

Pattern: read the current stock, then deduct — without a gap where another transaction could
read the same stock:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
BEGIN;
SELECT id, stock FROM products WHERE id = 1 FOR UPDATE;
-- no other transaction can modify this row until we commit or rollback
UPDATE products SET stock = stock - 1 WHERE id = 1;
COMMIT;"'
```

```
BEGIN
 id | stock
----+-------
  1 |    46
(1 row)

UPDATE 1
COMMIT
```

### FOR UPDATE SKIP LOCKED — non-blocking queue

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
BEGIN;
SELECT id, customer_id, status
FROM orders
WHERE status = '"'"'pending'"'"'
LIMIT 1
FOR UPDATE SKIP LOCKED;
-- processes this order; another worker picks the next unlocked row
ROLLBACK;"'
```

`SKIP LOCKED` is the building block of a simple job queue: each worker locks and processes
one row; rows locked by other workers are skipped rather than waited on.

## Deadlocks

A deadlock occurs when transaction A holds a lock that transaction B wants, and B holds a
lock that A wants. PostgreSQL detects this automatically and aborts one transaction with:

```
ERROR:  deadlock detected
DETAIL:  Process N waits for ShareLock on transaction M; blocked by process K.
```

### How to avoid deadlocks

1. **Consistent lock ordering**: always acquire locks on the same tables/rows in the same
   order across all transactions.
2. **Keep transactions short**: the longer a transaction holds locks, the more likely a
   conflict.
3. **Use `FOR UPDATE` early**: lock rows at the start of the transaction, not after reading.

## Scenario: safe inventory deduction

```bash
# Scenario: two customers try to buy the last Notebook simultaneously.
# Use FOR UPDATE to serialize the deductions.

docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
BEGIN;

-- 1. Lock the product row
SELECT id, stock FROM products WHERE id = 1 FOR UPDATE;

-- 2. Check stock
-- In a real app you would branch here; in psql we just proceed
UPDATE products
SET stock = stock - 1
WHERE id = 1 AND stock >= 1
RETURNING id, stock;

-- 3. Record the order
INSERT INTO orders (customer_id, product_id, qty, status)
VALUES (3, 1, 1, '"'"'paid'"'"') RETURNING id;

COMMIT;"'
```

```
BEGIN
 id | stock
----+-------
  1 |    45
(1 row)

 id | stock
----+-------
  1 |    44
(1 row)

UPDATE 1
 id
----
  6
(1 row)

INSERT 0 1
COMMIT
```

A second concurrent session running the same block would wait at `FOR UPDATE` until the first
commits, then see the updated stock — preventing overselling.

## Autocommit and implicit transactions

When you run a single SQL statement outside any `BEGIN` block, PostgreSQL wraps it in an
implicit transaction and commits immediately. This is called **autocommit mode**.

```bash
# Each -c statement below is its own implicit transaction
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
UPDATE orders SET status = '"'"'shipped'"'"' WHERE id = 5;"'
# ↑ commits immediately — there is no way to roll this back
```

To make a multi-statement sequence safe, always use explicit `BEGIN` / `COMMIT`.

## Gotchas / Docker notes

- **`SET TRANSACTION ISOLATION LEVEL` must come right after `BEGIN`**, before any data
  statement. Setting it later in the transaction raises an error.
- **A transaction in error state cannot run further SQL** until you `ROLLBACK` (or
  `ROLLBACK TO SAVEPOINT`). Attempting SQL after an error produces
  `ERROR: current transaction is aborted, commands ignored until end of transaction block`.
- **`FOR UPDATE` locks the selected rows**, not the table. Other transactions can still
  insert new rows or read/update rows that are not locked.
- **`SERIALIZABLE` has overhead**: it tracks read/write conflicts and may abort transactions
  with `ERROR: could not serialize access due to concurrent update`. Your application must
  retry on this error.
- **Psql `-c` batches in a single session** but each statement after a `BEGIN` must be part
  of the same `-c` string to stay in the same transaction. Separate `-c` flags start separate
  implicit transactions.
- **Long-running transactions block autovacuum**, which can cause table bloat. Always commit
  promptly; avoid leaving transactions open over idle connection pools.

## Cleanup

After completing all exercises, drop the scratch databases. Each `DROP DATABASE` must be its
own `-c` flag — PostgreSQL does not allow `DROP DATABASE` inside a multi-statement batch
(it would produce `ERROR: DROP DATABASE cannot run inside a transaction block`):

```bash
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DROP DATABASE IF EXISTS learn_cli;"'

docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DROP DATABASE IF EXISTS learn_restore;"'
```

---

Previous: [07-backup-restore.md](07-backup-restore.md) | Back to start: [README.md](README.md)
