# 03 — Indexes in SQL Server

An index speeds up row lookups at the cost of write overhead and storage. SQL Server's central
concept — the **clustered index** — is unlike anything in PostgreSQL or MySQL: it defines
the physical storage order of the table itself.

## Clustered vs nonclustered

### Clustered index

- There can be **only one** per table.
- The table's rows are stored on disk in clustered-index key order.
- In other words: the clustered index **is the table**. There is no separate heap.
- A `PRIMARY KEY` constraint automatically creates a clustered index by default.
- When you access a row by its clustered key, SQL Server reads directly to the data page.
  No second lookup needed.

### Nonclustered index

- Up to 999 per table.
- Stored separately from the table data as a B-tree of (key columns → clustered-key pointer).
- A nonclustered lookup first finds the key in the index, then does a **key lookup** (bookmark
  lookup) to the clustered index to fetch any columns not in the nonclustered index.
  Adding `INCLUDE` columns avoids that second trip for covered queries.

Check what indexes exist on a table:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SELECT i.name,
       i.type_desc,
       i.is_unique,
       i.is_primary_key,
       i.filter_definition
FROM   sys.indexes i
WHERE  i.object_id = OBJECT_ID('"'"'dbo.orders'"'"')
ORDER  BY i.index_id"'
```

Expected (PK is the clustered index):

```
name                              type_desc     is_unique  is_primary_key
--------------------------------- ------------- ---------- --------------
PK__orders__3213E83F...           CLUSTERED             1              1
```

## CREATE INDEX

### Basic nonclustered

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
CREATE NONCLUSTERED INDEX ix_orders_customer_id
  ON dbo.orders (customer_id)"'
```

### Unique index

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
CREATE UNIQUE NONCLUSTERED INDEX uix_customers_email
  ON dbo.customers (email)"'
```

### Composite index

Column order matters: place the most selective (highest cardinality) or most commonly
filtered column first. Queries can use the index if the leading column(s) appear in the
WHERE clause.

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
CREATE NONCLUSTERED INDEX ix_orders_customer_status
  ON dbo.orders (customer_id, status)"'
```

### INCLUDE columns — avoid key lookups

`INCLUDE` adds columns to the leaf level of the index without making them part of the
key. A query that only reads key + include columns never needs to visit the clustered
index (covering index):

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
CREATE NONCLUSTERED INDEX ix_products_price_covering
  ON dbo.products (price_cents)
  INCLUDE (name, stock)"'
```

A `SELECT name, price_cents, stock FROM products WHERE price_cents < 5000` query now
touches only this index — no clustered-index lookup needed.

### Filtered index

A filtered index indexes only rows that satisfy a WHERE condition. Much smaller and more
selective than a full-table index for sparse conditions (e.g., only pending orders):

```bash
# Filtered indexes require QUOTED_IDENTIFIER ON — use SET in the same session
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SET QUOTED_IDENTIFIER ON;
CREATE NONCLUSTERED INDEX ix_orders_pending
  ON dbo.orders (customer_id, created_at)
  WHERE status = '"'"'pending'"'"'"'
```

Verify the filter is stored:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SELECT name, filter_definition
FROM   sys.indexes
WHERE  filter_definition IS NOT NULL"'
```

## DROP INDEX

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
IF EXISTS (
  SELECT 1 FROM sys.indexes
  WHERE name = '"'"'ix_orders_customer_id'"'"'
    AND object_id = OBJECT_ID('"'"'dbo.orders'"'"'))
  DROP INDEX ix_orders_customer_id ON dbo.orders"'
```

Note: `DROP INDEX` syntax is `DROP INDEX index_name ON table_name` — the index name alone
is not enough because the same name could appear on different tables.

## SET STATISTICS IO ON

Measure logical reads (how many 8 KB pages were read) to evaluate index effectiveness.
A high logical-read count on a small table suggests a missing or unused index.

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SET STATISTICS IO ON;
SELECT * FROM orders WHERE status = '"'"'pending'"'"';
SET STATISTICS IO OFF"'
```

Expected (with the filtered index present):

```
Table 'orders'. Scan count 1, logical reads 2, ...
```

For execution plans, `SET SHOWPLAN_TEXT ON` must be the only statement in its batch —
it cannot share a `-Q` string with the query you want to analyse. Use the `-i` file pattern
with `GO` separators:

```bash
cat > /tmp/showplan.sql << 'EOF'
SET SHOWPLAN_TEXT ON;
GO
SELECT * FROM orders WHERE customer_id = 1;
GO
SET SHOWPLAN_TEXT OFF;
GO
EOF
docker cp /tmp/showplan.sql mini-baas-mssql:/tmp/showplan.sql
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli \
   -i /tmp/showplan.sql'
```

Expected (partial — shows the access method chosen, e.g. Clustered Index Seek vs Scan):

```
StmtText
------------------------------------------------------------------
  |--Clustered Index Seek(OBJECT:([learn_cli].[dbo].[orders]...))
```

## Scenario — optimizing the order list query

The shop admin page runs: `SELECT ... FROM orders WHERE customer_id = ? AND status = 'pending'`.
Without an index this scans the full orders table. Add a composite filtered index:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SET STATISTICS IO ON;
SELECT id, qty, created_at FROM orders WHERE customer_id = 1 AND status = '"'"'pending'"'"';
SET STATISTICS IO OFF"'

# Then add the covering filtered index
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SET QUOTED_IDENTIFIER ON;
CREATE NONCLUSTERED INDEX ix_orders_cust_pending
  ON dbo.orders (customer_id)
  INCLUDE (qty, created_at)
  WHERE status = '"'"'pending'"'"'"'

# Measure again — logical reads should drop
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SET STATISTICS IO ON;
SELECT id, qty, created_at FROM orders WHERE customer_id = 1 AND status = '"'"'pending'"'"';
SET STATISTICS IO OFF"'
```

## Listing all user indexes

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SELECT OBJECT_NAME(i.object_id)  AS table_name,
       i.name                    AS index_name,
       i.type_desc,
       i.is_unique,
       i.is_primary_key,
       i.filter_definition
FROM   sys.indexes i
WHERE  i.object_id > 100
  AND  i.name IS NOT NULL
ORDER  BY table_name, i.index_id"'
```

## Gotchas / Docker notes

- **Filtered indexes require `SET QUOTED_IDENTIFIER ON`** in the creating session. Passing
  `SET QUOTED_IDENTIFIER ON;` in the same `-Q` string works. Alternatively, use the
  `docker cp` + `sqlcmd -i` pattern with a `GO` after the SET.
- Any DML (INSERT/UPDATE/DELETE) on a table that has a filtered index also requires
  `QUOTED_IDENTIFIER ON`. This means `-Q` one-shots that update `orders` while the
  filtered index exists will fail unless you prepend `SET QUOTED_IDENTIFIER ON;`.
- The PRIMARY KEY clustered index cannot be dropped with `DROP INDEX` — you must
  `ALTER TABLE ... DROP CONSTRAINT pk_name` instead.
- `DROP INDEX` for a constraint-backed index (`UNIQUE`, `PRIMARY KEY`) requires
  `ALTER TABLE ... DROP CONSTRAINT`, not `DROP INDEX`.
- Nonclustered indexes on a heap (table with no clustered index) store a row identifier
  (RID) instead of a clustered-key pointer. Avoid heaps in production; add a clustered index.

---

Previous: [02-views.md](02-views.md) | Next: [04-logins-users.md](04-logins-users.md)
