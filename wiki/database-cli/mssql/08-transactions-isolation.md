# 08 — Transactions and Isolation Levels

SQL Server has the richest isolation-level set in the relational-database world, including
two optimistic modes (Snapshot and RCSI) that are unique to SQL Server and essential to
understanding its concurrency model.

## BEGIN / COMMIT / ROLLBACK TRANSACTION

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SET QUOTED_IDENTIFIER ON;
BEGIN TRANSACTION;
  UPDATE products SET stock = stock - 1 WHERE id = 1;
  UPDATE orders   SET status = '"'"'shipped'"'"' WHERE id = 1;
COMMIT TRANSACTION;
SELECT stock FROM products WHERE id = 1"'
```

Either both updates commit or neither does. Expected:

```
stock
-----
   43   (decremented by 1)
```

Rollback discards all changes made since `BEGIN TRANSACTION`:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
BEGIN TRANSACTION;
  UPDATE products SET stock = 999 WHERE id = 1;
  SELECT stock FROM products WHERE id = 1;  -- shows 999 in this session
ROLLBACK TRANSACTION;
SELECT stock FROM products WHERE id = 1"'  -- back to 43
```

Expected output shows 999 mid-transaction, then 43 after rollback.

## SAVE TRANSACTION — partial rollback

A savepoint lets you roll back to a named point without abandoning the whole transaction:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SET QUOTED_IDENTIFIER ON;
BEGIN TRANSACTION outer_tx;
  UPDATE products SET stock = stock + 100 WHERE id = 2;
  SAVE TRANSACTION before_risky_op;
  UPDATE products SET stock = 0 WHERE id = 2;
  SELECT stock FROM products WHERE id = 2;   -- 0
  ROLLBACK TRANSACTION before_risky_op;
  SELECT stock FROM products WHERE id = 2;   -- 220 (the +100 is preserved)
COMMIT TRANSACTION"'
```

`ROLLBACK TRANSACTION savepoint_name` does not end the transaction — it rolls back only
to the named point. The outer transaction is still open and must be committed or rolled back.

## SET XACT_ABORT ON

By default, a T-SQL error inside a transaction does NOT automatically roll back the
transaction. Subsequent statements continue, and you may end up with partial writes.

`SET XACT_ABORT ON` changes this: any error that causes a statement to fail immediately
rolls back the entire transaction and halts execution.

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT ON;
BEGIN TRANSACTION;
  UPDATE products SET stock = stock - 1 WHERE id = 1;
  -- The next line would fail (referencing a non-existent product id = 9999)
  -- With XACT_ABORT ON, the whole transaction rolls back automatically
  UPDATE orders SET status = '"'"'shipped'"'"' WHERE product_id = 9999;
COMMIT TRANSACTION"'
```

Use `SET XACT_ABORT ON` in all production T-SQL blocks. It is the safe default.

## Isolation levels

Isolation controls what data a transaction can see from concurrent transactions.
SQL Server supports six isolation levels:

| Level | Dirty reads | Non-repeatable reads | Phantom reads | Notes |
|-------|-------------|---------------------|---------------|-------|
| `READ UNCOMMITTED` | Yes | Yes | Yes | Lowest isolation; fastest; dangerous |
| `READ COMMITTED` | No | Yes | Yes | Default in SQL Server |
| `REPEATABLE READ` | No | No | Yes | |
| `SERIALIZABLE` | No | No | No | Highest locking isolation |
| `SNAPSHOT` | No | No | No | Optimistic; requires `ALLOW_SNAPSHOT_ISOLATION ON` |
| `READ COMMITTED SNAPSHOT` (RCSI) | No | Yes | Yes | Optimistic read-committed; SQL Server-specific |

Set isolation for the current session:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SELECT stock FROM products WHERE id = 1"'
```

## SNAPSHOT and READ COMMITTED SNAPSHOT (RCSI)

These two SQL Server-specific modes use row versioning instead of reader locks. Writers
store old row versions in `tempdb`, allowing readers to see a consistent snapshot without
blocking.

- **SNAPSHOT**: readers see the database state as of when their transaction started.
  Readers never block writers; writers never block readers.
- **RCSI (Read Committed Snapshot Isolation)**: readers see the last committed version of
  each row. Replaces the default `READ COMMITTED` locking behaviour with an optimistic one.
  This is the most impactful change — it eliminates read-write blocking without changing
  application code.

Enable them at the database level (requires no active connections at the time):

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
ALTER DATABASE learn_cli SET ALLOW_SNAPSHOT_ISOLATION ON;
ALTER DATABASE learn_cli SET READ_COMMITTED_SNAPSHOT ON WITH NO_WAIT"'
```

Verify:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
SELECT name,
       is_read_committed_snapshot_on AS rcsi,
       snapshot_isolation_state_desc AS snapshot
FROM   sys.databases
WHERE  name = '"'"'learn_cli'"'"'"'
```

Expected:

```
name       rcsi  snapshot
---------- ----- --------
learn_cli     1  ON
```

Use SNAPSHOT isolation explicitly in a session:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
BEGIN TRANSACTION;
  SELECT name, stock FROM products;
  -- other session can update products here without blocking this read
COMMIT TRANSACTION"'
```

## WITH (NOLOCK) — the dangerous shortcut

`WITH (NOLOCK)` is a table hint that reads data without acquiring any shared lock.
It is equivalent to `READ UNCOMMITTED` on that table only.

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SELECT id, name, stock FROM products WITH (NOLOCK)"'
```

The caveat: `WITH (NOLOCK)` can return **dirty reads** (data from rolled-back transactions),
**duplicate rows**, or **missing rows** during index operations. It is commonly misused as
a performance fix. Use RCSI instead — it gives you non-blocking reads without dirty-read risk.

## UPDLOCK and HOLDLOCK hints

`WITH (UPDLOCK)` acquires an update lock on rows during a SELECT — preventing another
transaction from acquiring an update lock on the same rows. Use it for the
"select then update" pattern to avoid lost updates:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SET QUOTED_IDENTIFIER ON;
BEGIN TRANSACTION;
  -- Lock the row we intend to update before another session can change it
  SELECT stock FROM products WITH (UPDLOCK) WHERE id = 1;
  UPDATE products SET stock = stock - 1 WHERE id = 1 AND stock > 0;
COMMIT TRANSACTION;
SELECT stock FROM products WHERE id = 1"'
```

`WITH (HOLDLOCK)` is equivalent to `SERIALIZABLE` for that statement — it holds shared
locks until the end of the transaction, preventing phantom reads.

## Deadlocks

A deadlock occurs when two sessions each hold a lock the other needs. SQL Server detects
deadlocks within about 5 seconds and kills the "victim" transaction (the one with the
cheapest rollback cost), raising error 1205.

Best practices to avoid deadlocks:
- Access tables in a consistent order across all transactions.
- Keep transactions short — commit as fast as possible.
- Use RCSI or SNAPSHOT to eliminate most reader-writer deadlocks.
- Index well — a full table scan locks more rows than a narrow index seek.

Inspect recent deadlocks via the system health extended event session:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
SELECT xdr.value('"'"'(@timestamp)[1]'"'"','"'"'datetime2'"'"') AS deadlock_time,
       xdr.query('"'"'.'"'"') AS deadlock_graph
FROM (
  SELECT CAST(target_data AS XML) AS target_data
  FROM   sys.dm_xe_session_targets t
  JOIN   sys.dm_xe_sessions        s ON s.address = t.event_session_address
  WHERE  s.name = '"'"'system_health'"'"'
    AND  t.target_name = '"'"'ring_buffer'"'"'
) AS data
CROSS APPLY target_data.nodes('"'"'//RingBufferTarget/event[@name=\"xml_deadlock_report\"]'"'"') AS xdr_tbl(xdr)"'
```

## Scenario — safe order placement with XACT_ABORT

A customer places an order. Stock must decrease and the order must be inserted atomically.
If either fails, neither persists:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT ON;
BEGIN TRANSACTION;
  -- Lock the product row before reading stock
  DECLARE @current_stock INT;
  SELECT @current_stock = stock FROM products WITH (UPDLOCK) WHERE id = 2;
  IF @current_stock < 1
    THROW 50001, '"'"'Out of stock'"'"', 1;
  UPDATE products SET stock = stock - 1 WHERE id = 2;
  INSERT INTO orders (customer_id, product_id, qty, status)
  VALUES (1, 2, 1, '"'"'confirmed'"'"');
COMMIT TRANSACTION;
SELECT stock FROM products WHERE id = 2;
SELECT TOP 1 id, status FROM orders ORDER BY id DESC"'
```

## Gotchas / Docker notes

- **`SET QUOTED_IDENTIFIER ON` is required** for any DML on a table that has a filtered index.
  If `orders` has a filtered index, updating `orders` inside a `-Q` one-shot fails with
  `Msg 1934: UPDATE failed because the following SET options have incorrect settings:
  QUOTED_IDENTIFIER`. Prefix every `-Q` block with `SET QUOTED_IDENTIFIER ON;` when touching
  those tables, or use a `.sql` file.
- `XACT_ABORT` does not help with `THROW` — `THROW` re-raises and the engine rolls back
  even without `XACT_ABORT`. The combination is still best practice because it catches
  constraint violations and other non-THROW errors too.
- `SAVE TRANSACTION` does NOT decrement `@@TRANCOUNT`. Only `COMMIT` and full `ROLLBACK`
  change `@@TRANCOUNT`. Nested `BEGIN TRANSACTION` increments it, but only the outermost
  `COMMIT` actually commits.
- RCSI incurs a write overhead (old row versions stored in `tempdb`). On a high-write workload
  monitor `tempdb` space. In this dev container, the default `tempdb` size is sufficient.
- `WITH (NOLOCK)` is not a performance silver bullet — it can return incorrect results.
  Enabling RCSI on the database is nearly always the correct fix for blocking reads.

---

Previous: [07-backup-restore.md](07-backup-restore.md) | Back to: [README.md](README.md)
