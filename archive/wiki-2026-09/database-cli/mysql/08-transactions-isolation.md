# Transactions and Isolation Levels

InnoDB (the default storage engine in MariaDB) provides full ACID transactions. Understanding how to demarcate transaction boundaries, use savepoints for partial rollback, and choose the right isolation level prevents the most common data-consistency bugs in concurrent applications.

## Prerequisites

This file assumes the `learn_cli` database with shop data from [01-crud.md](01-crud.md).

## Basic transaction: START TRANSACTION / COMMIT / ROLLBACK

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
-- Atomic order placement: decrement stock AND create order together
START TRANSACTION;
  UPDATE products SET stock = stock - 2 WHERE id = 3;
  INSERT INTO orders (customer_id, product_id, qty, status)
    VALUES (1, 3, 2, \"paid\");
COMMIT;

-- Verify both changes landed
SELECT stock FROM products WHERE id = 3;
SELECT id, status FROM orders ORDER BY id DESC LIMIT 1;
"'
```

```
stock
13

id  status
4   paid
```

Both the stock decrement and the new order are either fully committed or fully rolled back as a unit.

### ROLLBACK — undo everything

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
-- Simulate an error: start a transaction, then roll it back
START TRANSACTION;
  UPDATE products SET stock = stock - 100 WHERE id = 1;
  SELECT stock FROM products WHERE id = 1;  -- sees the in-transaction value
ROLLBACK;

SELECT stock FROM products WHERE id = 1;  -- back to original
"'
```

```
stock
-51   ← visible only inside the transaction

stock
49    ← restored after rollback
```

## SAVEPOINT — partial rollback

A savepoint marks a point within a transaction you can roll back to without aborting the whole transaction.

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
START TRANSACTION;
  -- Step 1: decrement stock (before savepoint)
  UPDATE products SET stock = stock - 1 WHERE id = 1;
  SAVEPOINT after_stock_update;

  -- Step 2: insert an order (after savepoint)
  INSERT INTO orders (customer_id, product_id, qty, status)
    VALUES (2, 1, 1, \"pending\");

  -- Pretend we detected a problem with the order — roll back to savepoint
  ROLLBACK TO SAVEPOINT after_stock_update;

  -- Stock update is still pending; the INSERT was rolled back
  SELECT stock FROM products WHERE id = 1;

COMMIT;  -- commits only the stock update

SELECT stock FROM products WHERE id = 1;  -- stock is decremented
SELECT COUNT(*) AS orders_for_product1 FROM orders WHERE product_id = 1;
"'
```

```
stock
48    ← inside transaction: update kept, insert rolled back

stock
48    ← committed value

orders_for_product1
1     ← the INSERT from the savepoint rollback did not land
```

`RELEASE SAVEPOINT name` removes the savepoint without rolling back (frees memory in long transactions with many savepoints).

## Autocommit

By default, every statement outside an explicit `START TRANSACTION` is auto-committed:

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
SHOW VARIABLES LIKE \"autocommit\";
"'
```

```
Variable_name  Value
autocommit     ON
```

To run a batch of statements without committing between each:

```sql
SET autocommit = 0;
UPDATE products SET stock = stock + 10 WHERE id = 1;
UPDATE products SET stock = stock + 10 WHERE id = 2;
COMMIT;
SET autocommit = 1;
```

Prefer explicit `START TRANSACTION` over disabling autocommit — it is clearer and does not require resetting the session.

## Isolation levels

The isolation level controls what concurrent transactions can see of each other's uncommitted data.

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
SELECT @@global.tx_isolation AS global_level, @@session.tx_isolation AS session_level;
"'
```

```
global_level    session_level
REPEATABLE-READ REPEATABLE-READ
```

REPEATABLE READ is the MariaDB (and MySQL) default — a good default for most OLTP workloads.

### Change isolation for the current session

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
SELECT @@session.tx_isolation;
-- Reset to default
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
"'
```

```
@@session.tx_isolation
READ-COMMITTED
```

### Change for the next transaction only

```sql
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
START TRANSACTION;
  -- this transaction runs at SERIALIZABLE level
COMMIT;
-- subsequent transactions return to the session default
```

### Isolation level reference

| Level | Dirty reads | Non-repeatable reads | Phantom reads | Notes |
|---|---|---|---|---|
| `READ UNCOMMITTED` | Possible | Possible | Possible | Never use — can read uncommitted garbage |
| `READ COMMITTED` | Prevented | Possible | Possible | Useful for reporting queries; Oracle default |
| `REPEATABLE READ` | Prevented | Prevented | Prevented* | **MariaDB/MySQL default**; InnoDB uses MVCC to prevent phantoms too* |
| `SERIALIZABLE` | Prevented | Prevented | Prevented | All reads become `SELECT ... LOCK IN SHARE MODE`; highest contention |

*InnoDB's MVCC (multi-version concurrency control) prevents phantom reads at REPEATABLE READ in practice — stricter than the SQL standard requires.

In Oracle MySQL 8.0, the variable is `@@transaction_isolation` (not `@@tx_isolation`). MariaDB keeps the older `@@tx_isolation` name.

## SELECT ... FOR UPDATE — exclusive row lock

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
START TRANSACTION;
  -- Lock product row 1 for update — no other transaction can modify it until COMMIT
  SELECT id, stock FROM products WHERE id = 1 FOR UPDATE;
  -- ... application checks stock, then updates:
  UPDATE products SET stock = stock - 1 WHERE id = 1;
COMMIT;
"'
```

`FOR UPDATE` is the "pessimistic lock" pattern — use it when the read and write are separated by application logic that must not be interrupted by a concurrent transaction.

## SELECT ... LOCK IN SHARE MODE — shared row lock

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
START TRANSACTION;
  -- Allow other readers, but block writers
  SELECT id, stock FROM products WHERE id = 2 LOCK IN SHARE MODE;
COMMIT;
"'
```

`LOCK IN SHARE MODE`: other transactions can also acquire a shared lock and read the rows, but no transaction can acquire an exclusive lock or modify the rows until all shared locks are released. Use when you need to read a consistent value and ensure no write can change it before your dependent INSERT.

## Deadlocks

A deadlock occurs when two transactions each hold a lock the other needs. InnoDB detects the cycle automatically and kills the transaction with less work done (the "victim").

```
Transaction A                    Transaction B
--------------                   --------------
START TRANSACTION;               START TRANSACTION;
UPDATE orders SET ...            UPDATE products SET ...
  WHERE id = 1;      ←lock        WHERE id = 1;    ←lock
UPDATE products SET ...  ←WAIT   UPDATE orders SET ...  ←WAIT
  WHERE id = 1;                    WHERE id = 1;
                     DEADLOCK DETECTED
                     ERROR 1213: Deadlock found...
```

The victim transaction receives `ERROR 1213 (40001): Deadlock found when trying to get lock; try restarting transaction`. The application should catch this error and retry the transaction.

**Prevention strategies:**
- Always acquire locks in the same order across transactions (alphabetical table order is a common convention)
- Keep transactions short — do minimal work between lock acquisition and COMMIT
- Use `FOR UPDATE` only when necessary; prefer optimistic updates with version columns for low-conflict workloads

## Scenario: safe stock reservation

A customer buys a product — stock must be reserved atomically to prevent oversell:

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
START TRANSACTION;

  -- Lock the product row to prevent concurrent reservation
  SELECT id, stock FROM products WHERE id = 2 FOR UPDATE;

  -- Only proceed if stock >= qty requested
  UPDATE products
    SET stock = stock - 1
    WHERE id = 2 AND stock >= 1;

  -- Check whether the UPDATE actually ran (affected_rows = 0 means out of stock)
  SELECT ROW_COUNT() AS rows_updated;

  -- If rows_updated = 1, insert the order; otherwise ROLLBACK in application code
  INSERT INTO orders (customer_id, product_id, qty, status)
    VALUES (3, 2, 1, \"pending\");

COMMIT;

-- Verify
SELECT id, stock FROM products WHERE id = 2;
"'
```

```
id  stock
2   119
```

## Cleanup

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS learn_cli;"'
```

## Gotchas / Docker notes

- **One-shot `-e` commands run in a single session**: a `START TRANSACTION` in `-e "..."` that spans one string is fully atomic. But if you split the transaction across two separate `docker exec` calls, you get two independent connections — the second `docker exec` will not see the open transaction from the first.
- **`ROLLBACK TO SAVEPOINT` does not end the transaction**: the transaction remains open after rolling back to a savepoint. You must still COMMIT or ROLLBACK the outer transaction.
- **`tx_isolation` vs `transaction_isolation`**: MariaDB 11.4 uses `@@tx_isolation` (the classic name). Oracle MySQL 8.0+ renamed it to `@@transaction_isolation`. If you write tooling that queries both engines, check both variable names.
- **InnoDB gap locks at REPEATABLE READ**: InnoDB uses gap locks (next-key locks) to prevent phantom reads at the REPEATABLE READ level. This means a `SELECT ... WHERE status = \"pending\" FOR UPDATE` also locks the gaps between existing pending rows, which can cause unexpected lock contention. Switch to READ COMMITTED to disable gap locking (at the cost of phantom reads).
- **`SELECT ROW_COUNT()`**: returns the number of rows affected by the previous DML statement, within the same session. Use it after an UPDATE to verify the update found and changed the expected rows.
- **DDL implicitly commits**: `CREATE TABLE`, `ALTER TABLE`, `DROP TABLE`, and most other DDL statements issue an implicit COMMIT before and after executing. You cannot roll back DDL inside a `START TRANSACTION`.

---

Previous: [07-backup-restore.md](07-backup-restore.md) | Back to [README.md](README.md)
