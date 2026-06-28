# 08 — Transactions and Isolation

Transactions in CockroachDB behave like Postgres at the SQL level but with one critical difference: the default isolation level is **SERIALIZABLE** (the strongest level), and in a distributed setting conflicts can surface as transient errors that the **client** must handle. Understanding this is fundamental to writing correct CockroachDB application code.

## Setup

```bash
docker exec mini-baas-cockroach cockroach sql --insecure \
  -e "CREATE DATABASE IF NOT EXISTS learn_cli;"
```

Create and populate the shop schema from [01-crud.md](01-crud.md).

## Basic transaction: BEGIN / COMMIT / ROLLBACK

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
BEGIN;
UPDATE products SET stock = stock - 2 WHERE name = 'Widget A';
INSERT INTO orders (customer_id, product_id, qty, status)
SELECT c.id, p.id, 2, 'pending'
FROM   customers c, products p
WHERE  c.email = 'bob@example.com' AND p.name = 'Widget A';
COMMIT;
"
```

Both statements succeed or both roll back — atomicity guaranteed.

```bash
# Verify
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli \
  -e "SELECT stock FROM products WHERE name = 'Widget A';"
```

```
stock
98
```

ROLLBACK aborts the transaction; no changes are visible:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
BEGIN;
UPDATE products SET stock = 0 WHERE name = 'Widget A';
ROLLBACK;
"
```

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli \
  -e "SELECT stock FROM products WHERE name = 'Widget A';"
# still 98 — ROLLBACK worked
```

## SAVEPOINT

A savepoint marks a point within a transaction you can roll back to without aborting the whole transaction:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
BEGIN;
SAVEPOINT sp1;
UPDATE products SET stock = 50 WHERE name = 'Widget A';
-- Change of mind: undo just this UPDATE
ROLLBACK TO SAVEPOINT sp1;
-- Other work can continue here
COMMIT;
"
```

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli \
  -e "SELECT stock FROM products WHERE name = 'Widget A';"
# 98 — savepoint rollback discarded the stock = 50 update
```

## SERIALIZABLE isolation: the default

Check the isolation level:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
SHOW TRANSACTION ISOLATION LEVEL;
"
```

```
transaction_isolation
serializable
```

SERIALIZABLE means CockroachDB guarantees that concurrent transactions produce results equivalent to some serial (one-after-another) execution. This eliminates phantoms, non-repeatable reads, and dirty reads — problems that plague READ COMMITTED databases.

The trade-off: when two SERIALIZABLE transactions conflict (both read and write the same rows), CockroachDB cannot complete both. One succeeds; the other is **aborted** with a `40001` error code (`restart transaction`).

In a single-node Postgres with READ COMMITTED, many of these conflicts simply don't arise (they result in subtle data anomalies instead). In CockroachDB at SERIALIZABLE, conflicts are surfaced as errors that the client must handle.

## The client-side retry loop — the signature CockroachDB pattern

When a transaction fails with `SQLSTATE 40001` (`restart transaction`), the correct response is to retry the entire transaction from scratch. CockroachDB provides a protocol for this using a special savepoint:

**The protocol:**

1. Begin a transaction.
2. Create `SAVEPOINT cockroach_restart`.
3. Execute the transaction body.
4. On success: `RELEASE SAVEPOINT cockroach_restart`, then `COMMIT`.
5. On `40001` error: `ROLLBACK TO SAVEPOINT cockroach_restart`, then go back to step 3.
6. On any other error: `ROLLBACK`.

The `RELEASE SAVEPOINT cockroach_restart` step is what actually commits the work (the `COMMIT` after is a no-op if release succeeded). This is different from normal savepoints.

**Verify the protocol structure works:**

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
BEGIN;
SAVEPOINT cockroach_restart;
SELECT 1 AS probe;
RELEASE SAVEPOINT cockroach_restart;
COMMIT;
"
```

```
BEGIN
SAVEPOINT
probe
1
COMMIT
COMMIT
```

The second `COMMIT` is a no-op (the `RELEASE` already committed).

**Pseudocode for application retry loop:**

```
MAX_RETRIES = 5
for attempt in range(MAX_RETRIES):
    conn.execute("BEGIN")
    conn.execute("SAVEPOINT cockroach_restart")
    try:
        # --- your transaction body ---
        conn.execute("UPDATE products SET stock = stock - $qty WHERE id = $id")
        conn.execute("INSERT INTO orders ...")
        # --- end transaction body ---
        conn.execute("RELEASE SAVEPOINT cockroach_restart")
        conn.execute("COMMIT")
        break  # success
    except SqlError as e:
        if e.sqlstate == "40001":
            conn.execute("ROLLBACK TO SAVEPOINT cockroach_restart")
            # loop → retry
        else:
            conn.execute("ROLLBACK")
            raise  # non-retryable error
```

Most CockroachDB client libraries (e.g., `pgx` for Go, `psycopg2` for Python) provide a transaction wrapper that handles this loop automatically. Always use the library's managed transaction helper rather than rolling your own.

## SELECT FOR UPDATE

`SELECT FOR UPDATE` acquires a write lock on the selected rows, preventing other transactions from modifying them until the current transaction commits or rolls back. Useful for read-modify-write patterns where you want to reserve stock before decrementing it:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
BEGIN;
SELECT id, stock FROM products WHERE name = 'Widget A' FOR UPDATE;
-- Now safe to update: no other transaction can modify this row until COMMIT
UPDATE products SET stock = stock - 1 WHERE name = 'Widget A';
COMMIT;
"
```

```
BEGIN
id                                    stock
7bee9711-bab4-4782-aa05-7674b774fbaf  98
UPDATE 1
COMMIT
```

Without `FOR UPDATE`, two concurrent transactions could both read `stock = 98`, both compute `98 - 1 = 97`, and both write `97` — losing one decrement. `FOR UPDATE` serialises the access.

## Contrast with single-node databases

| Behaviour | Single-node Postgres (READ COMMITTED) | CockroachDB (SERIALIZABLE) |
|---|---|---|
| Default isolation | READ COMMITTED | SERIALIZABLE |
| Dirty reads | Prevented | Prevented |
| Non-repeatable reads | Possible | Prevented |
| Phantom reads | Possible | Prevented |
| Conflict on concurrent write | Last write wins | One transaction aborts with 40001 |
| Client retry needed? | Rarely | Yes — build it in |
| Anomalies possible | Yes (write skew, lost update) | No |

## Scenario: safe stock decrement

```bash
# Simulate the full retry-safe pattern as a manual walkthrough

# Step 1: check stock before
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli \
  -e "SELECT name, stock FROM products WHERE name = 'Gadget B';"

# Step 2: run a protected decrement
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
BEGIN;
SAVEPOINT cockroach_restart;
SELECT stock FROM products WHERE name = 'Gadget B' FOR UPDATE;
UPDATE products SET stock = stock - 1 WHERE name = 'Gadget B' AND stock > 0;
INSERT INTO orders (customer_id, product_id, qty, status)
SELECT c.id, p.id, 1, 'pending'
FROM   customers c, products p
WHERE  c.email = 'alice@example.com' AND p.name = 'Gadget B';
RELEASE SAVEPOINT cockroach_restart;
COMMIT;
"

# Step 3: confirm
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli \
  -e "SELECT name, stock FROM products WHERE name = 'Gadget B';"
```

## Cleanup

```bash
docker exec mini-baas-cockroach cockroach sql --insecure \
  -e "DROP DATABASE learn_cli CASCADE;"
```

## Gotchas / Docker notes

- **40001 is not a bug.** It is CockroachDB telling you: "someone else touched these rows at the same time; please retry." It is how SERIALIZABLE correctness is preserved in a distributed system.
- **`RELEASE SAVEPOINT cockroach_restart` is the real commit.** The `COMMIT` that follows is cosmetic — it succeeds but does nothing if the release already committed.
- **Never swallow 40001 silently.** Applications that catch the error and continue without retrying will silently lose their transaction's writes.
- **`BEGIN ISOLATION LEVEL READ COMMITTED` is accepted** in v24.3.5 but results in stronger-than-requested isolation (SERIALIZABLE). CockroachDB will not downgrade; it upgrades silently.
- **`SAVEPOINT` names are arbitrary** except for `cockroach_restart`, which is the magic name the cluster recognises for the restart protocol. Ordinary savepoints (e.g., `SAVEPOINT sp1`) do not trigger the retry mechanism.
- **Interactive shell multi-statement `-e`** executes statements sequentially in one connection. In application code, the retry loop must use the same connection throughout a transaction.

---

← [07-backup-restore.md](07-backup-restore.md) | [README](README.md) →
