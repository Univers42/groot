# 02 — Views in SQL Server

A view is a named, stored SELECT query that behaves like a virtual table. SQL Server views
range from simple read aliases to indexed (materialized) views backed by physical storage.

## CREATE VIEW

`CREATE VIEW` must be the **first and only** statement in its batch. In one-shot (`-Q`) mode
you can send it directly; in a multi-statement file use `GO` on either side.

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
CREATE VIEW dbo.order_summary AS
SELECT o.id          AS order_id,
       c.name        AS customer,
       p.name        AS product,
       o.qty,
       o.qty * p.price_cents AS total_cents,
       o.status,
       o.created_at
FROM   dbo.orders    o
JOIN   dbo.customers c ON c.id = o.customer_id
JOIN   dbo.products  p ON p.id = o.product_id"'
```

Query it exactly like a table:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli \
   -Q "SELECT * FROM order_summary ORDER BY total_cents DESC"'
```

## WITH SCHEMABINDING

`WITH SCHEMABINDING` locks the view's definition to the referenced tables — column drops or
type changes that would break the view are blocked until the view is altered or dropped first.
It also enables indexed views (see below).

Requirements for `WITH SCHEMABINDING`:
- All referenced objects must use two-part names (`dbo.tablename`, not just `tablename`).
- No `SELECT *` — columns must be named explicitly.
- Cannot reference other databases or servers.

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
CREATE VIEW dbo.product_prices
WITH SCHEMABINDING AS
SELECT id, name, price_cents
FROM   dbo.products"'
```

Check whether a view is schema-bound (the column `is_schema_bound` does not exist in
`sys.views` — use `OBJECTPROPERTY` instead):

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SELECT name,
       OBJECTPROPERTY(object_id, '"'"'IsSchemaBound'"'"') AS is_schema_bound
FROM   sys.views
WHERE  is_ms_shipped = 0"'
```

## Indexed views — the SQL Server materialized-view equivalent

An indexed view persists its result set on disk. SQL Server calls this an **indexed view**
(other databases call it a materialized view). The query optimizer can use it automatically
even without explicit reference in your queries (Enterprise/Developer edition).

Requirements (strict — all must be met):
1. The view must have `WITH SCHEMABINDING`.
2. The first index must be `UNIQUE CLUSTERED`.
3. The session that creates both the view AND the index must have
   `QUOTED_IDENTIFIER ON` and `ANSI_NULLS ON` (among others).
4. Certain constructs are disallowed in the view body: `DISTINCT`, `TOP`, `UNION`,
   outer joins, subqueries, `MIN`/`MAX` without `GROUP BY`, non-deterministic functions.

Because `CREATE VIEW` must be the first statement in its batch, use the `-i` file approach
to sequence `SET QUOTED_IDENTIFIER ON` → `GO` → `CREATE VIEW` → `GO` → `CREATE INDEX`:

```bash
cat > /tmp/indexed_view.sql << 'EOF'
SET QUOTED_IDENTIFIER ON;
GO
DROP VIEW IF EXISTS dbo.product_inventory;
GO
CREATE VIEW dbo.product_inventory
WITH SCHEMABINDING AS
SELECT id, name, price_cents, stock
FROM   dbo.products;
GO
CREATE UNIQUE CLUSTERED INDEX uix_product_inventory_id
  ON dbo.product_inventory (id);
GO
SELECT v.name,
       OBJECTPROPERTY(v.object_id, 'IsSchemaBound') AS is_schema_bound,
       i.name  AS index_name,
       i.type_desc
FROM   sys.views  v
LEFT   JOIN sys.indexes i ON i.object_id = v.object_id
WHERE  v.name = 'product_inventory';
GO
EOF
docker cp /tmp/indexed_view.sql mini-baas-mssql:/tmp/indexed_view.sql
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli \
   -i /tmp/indexed_view.sql'
```

Expected output:

```
name               is_schema_bound  index_name                 type_desc
------------------ ---------------  -------------------------- ---------
product_inventory                1  uix_product_inventory_id   CLUSTERED
```

## ALTER VIEW

`ALTER VIEW` replaces a view definition in place (permissions are preserved, unlike
`DROP` + `CREATE`). It also must be the first statement in its batch:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
ALTER VIEW dbo.order_summary AS
SELECT o.id          AS order_id,
       c.name        AS customer,
       p.name        AS product,
       o.qty,
       o.qty * p.price_cents AS total_cents,
       o.status,
       o.created_at
FROM   dbo.orders    o
JOIN   dbo.customers c ON c.id = o.customer_id
JOIN   dbo.products  p ON p.id = o.product_id"'
```

To add `WITH SCHEMABINDING` to an existing view, use `ALTER VIEW ... WITH SCHEMABINDING AS ...`.

## Updatable views

A view is updatable if:
- It references only one base table in its `FROM` clause.
- It contains no `DISTINCT`, `GROUP BY`, `HAVING`, `UNION`, or aggregates.
- The columns being updated are not computed.

```sql
-- This view is updatable because it references one table
CREATE VIEW dbo.customer_contacts AS
SELECT id, name, email FROM dbo.customers;

-- This UPDATE targets the base table through the view
UPDATE dbo.customer_contacts SET email = 'new@example.com' WHERE id = 1;
```

`WITH CHECK OPTION` prevents updates through the view that would cause a row to disappear
from the view's result set (i.e., the updated row would no longer satisfy the view's WHERE):

```sql
CREATE VIEW dbo.pending_orders AS
SELECT * FROM dbo.orders WHERE status = 'pending'
WITH CHECK OPTION;
-- UPDATE ... SET status = 'shipped' would be rejected here
```

## Listing views

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SELECT name,
       OBJECTPROPERTY(object_id, '"'"'IsSchemaBound'"'"')   AS schema_bound,
       with_check_option
FROM   sys.views
WHERE  is_ms_shipped = 0
ORDER  BY name"'
```

## DROP VIEW

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
DROP VIEW IF EXISTS dbo.product_inventory"'
```

`IF EXISTS` prevents an error when the view does not exist (available since SQL Server 2016).
You can drop multiple views in one statement: `DROP VIEW IF EXISTS v1, v2, v3`.

## Scenario — `order_summary` view for reporting

A reporting query needs to join three tables repeatedly. Encapsulate it in a view so
consumers write a simple SELECT:

```bash
# Create the view
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
CREATE VIEW dbo.order_summary AS
SELECT o.id          AS order_id,
       c.name        AS customer,
       p.name        AS product,
       o.qty,
       o.qty * p.price_cents AS total_cents,
       o.status,
       o.created_at
FROM   dbo.orders    o
JOIN   dbo.customers c ON c.id = o.customer_id
JOIN   dbo.products  p ON p.id = o.product_id"'

# Report: top customers by spend
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SELECT customer,
       COUNT(*)       AS orders,
       SUM(total_cents) AS lifetime_cents
FROM   order_summary
GROUP  BY customer
ORDER  BY lifetime_cents DESC"'
```

## Gotchas / Docker notes

- `CREATE VIEW`, `ALTER VIEW`, `CREATE SCHEMA` and similar DDL must be the **sole** statement
  in their batch. Pairing them with other statements in a `-Q` one-liner raises syntax error
  `Msg 111: 'CREATE VIEW' must be the first statement in a query batch`.
- Indexed views require `SET QUOTED_IDENTIFIER ON` both when creating the view *and* when
  creating the index. If you create a schemabinding view without it, the subsequent
  `CREATE UNIQUE CLUSTERED INDEX` raises `Msg 1935: Object was created with the following
  SET options off: 'QUOTED_IDENTIFIER'`. Use the `-i` pattern to set options across batches.
- `sys.views` has no `is_schema_bound` column — use `OBJECTPROPERTY(object_id, 'IsSchemaBound')`.
- Dropping a table referenced by a schemabinding view fails with a dependency error.
  Drop or alter the view first.

---

Previous: [01-crud.md](01-crud.md) | Next: [03-indexes.md](03-indexes.md)
