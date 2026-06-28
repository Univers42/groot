# Views

A view is a named, stored SELECT query that can be queried like a table. It adds no storage for data, but simplifies complex joins, enforces column-level visibility, and (when updatable) can act as a write interface to the underlying table.

> MariaDB has no materialized views — see the workaround section at the bottom.

## Prerequisites

This file assumes the `learn_cli` shop schema from [01-crud.md](01-crud.md) is populated.

## CREATE [OR REPLACE] VIEW

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
CREATE OR REPLACE VIEW order_summary AS
  SELECT
    o.id                          AS order_id,
    c.name                        AS customer,
    p.name                        AS product,
    o.qty,
    (o.qty * p.price_cents)       AS total_cents,
    o.status,
    o.created_at
  FROM orders o
  JOIN customers c ON c.id = o.customer_id
  JOIN products  p ON p.id = o.product_id;
"'
```

`OR REPLACE` makes the statement idempotent — it drops and recreates the view if it already exists. Without it, you get `ERROR 1050: Table 'order_summary' already exists`.

### Query the view

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
SELECT * FROM order_summary ORDER BY order_id;
"'
```

```
order_id  customer      product   qty  total_cents  status   created_at
1         Alice Dupont  Keyboard  1    7999         paid     2026-06-28 10:26:32
2         Bob Martin    Monitor   2    59998        pending  2026-06-28 10:26:32
3         Alice Dupont  Mouse     1    2999         shipped  2026-06-28 10:26:32
```

## Updatable views

A view is updatable when it:
- References exactly one base table
- Does not use DISTINCT, aggregates, GROUP BY, HAVING, UNION, or subqueries in the SELECT list

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
CREATE OR REPLACE VIEW pending_orders AS
  SELECT id, customer_id, product_id, qty, status, created_at
  FROM   orders
  WHERE  status = \"pending\";

-- Update through the view (updates the underlying orders table)
UPDATE pending_orders SET qty = 3 WHERE id = 2;

-- Verify
SELECT id, qty, status FROM orders WHERE id = 2;
"'
```

```
id  qty  status
2   3    pending
```

## WITH CHECK OPTION

Prevents writing rows through the view that would not be visible by the view's own WHERE clause.

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
CREATE OR REPLACE VIEW pending_orders AS
  SELECT id, customer_id, product_id, qty, status, created_at
  FROM   orders
  WHERE  status = \"pending\"
  WITH CHECK OPTION;
"'
```

Now try to insert a non-pending row through the view:

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
INSERT INTO pending_orders (customer_id, product_id, qty, status)
  VALUES (1, 1, 1, \"paid\");
"' 2>&1
```

```
ERROR 1369 (44000): CHECK OPTION failed `learn_cli`.`pending_orders`
```

The engine rejected the insert because the resulting row (status=paid) would not be returned by `WHERE status = \"pending\"`.

## SHOW CREATE VIEW

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
SHOW CREATE VIEW order_summary\G
"'
```

```
View: order_summary
Create View: CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost`
             SQL SECURITY DEFINER VIEW `order_summary` AS
             select `o`.`id` AS `order_id`, ...
character_set_client: utf8mb3
collation_connection: utf8mb3_general_ci
```

Note `DEFINER=root@localhost` — the view runs with the privileges of the user who created it (SQL SECURITY DEFINER). To run with the caller's privileges, specify `SQL SECURITY INVOKER` at creation time.

## information_schema.VIEWS

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
SELECT TABLE_NAME, IS_UPDATABLE, SECURITY_TYPE, CHECK_OPTION
FROM   information_schema.VIEWS
WHERE  TABLE_SCHEMA = \"learn_cli\";
"'
```

```
TABLE_NAME      IS_UPDATABLE  SECURITY_TYPE  CHECK_OPTION
order_summary   NO            DEFINER        NONE
pending_orders  YES           DEFINER        LOCAL
```

`IS_UPDATABLE=NO` for `order_summary` because it joins multiple tables.

## DROP VIEW

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
DROP VIEW IF EXISTS pending_orders;
"'
```

`IF EXISTS` prevents an error when the view does not exist — useful in idempotent migration scripts.

## No materialized views — the workaround

MariaDB (like Oracle MySQL) has no materialized view support. The standard workaround is a **snapshot table + scheduled event**:

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
-- 1. Create the snapshot table manually (once)
CREATE TABLE IF NOT EXISTS order_summary_snap AS
  SELECT * FROM order_summary LIMIT 0;

-- 2. Schedule a refresh every 10 minutes (requires event_scheduler=ON)
CREATE EVENT IF NOT EXISTS refresh_order_summary_snap
  ON SCHEDULE EVERY 10 MINUTE
  DO
    BEGIN
      TRUNCATE TABLE order_summary_snap;
      INSERT INTO order_summary_snap SELECT * FROM order_summary;
    END;
"'
```

To check whether the event scheduler is running:

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "SHOW VARIABLES LIKE \"event_scheduler\";"'
```

If it returns `OFF`, queries against `order_summary_snap` will be stale until a manual refresh. The scheduler is often disabled in container deployments — check your `my.cnf` or set it with `SET GLOBAL event_scheduler = ON;`.

## Scenario: order_summary for the finance team

The finance team needs total revenue per customer, without access to raw `orders` rows. Build a summary view, then grant them SELECT only on it (see [05-permissions-grants.md](05-permissions-grants.md)):

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
CREATE OR REPLACE VIEW customer_revenue AS
  SELECT
    c.id              AS customer_id,
    c.name            AS customer,
    COUNT(o.id)       AS order_count,
    SUM(o.qty * p.price_cents) AS total_cents
  FROM   customers c
  LEFT   JOIN orders   o ON o.customer_id = c.id
  LEFT   JOIN products p ON p.id = o.product_id
  GROUP  BY c.id, c.name;

SELECT * FROM customer_revenue ORDER BY total_cents DESC;
"'
```

```
customer_id  customer      order_count  total_cents
1            Alice Dupont  2            10998
2            Bob Martin    1            59998
```

## Cleanup

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
DROP VIEW IF EXISTS order_summary, pending_orders, customer_revenue;
DROP TABLE IF EXISTS order_summary_snap;
DROP EVENT IF EXISTS refresh_order_summary_snap;
"'
```

## Gotchas / Docker notes

- **`ALGORITHM=UNDEFINED`** (the default) lets MariaDB choose between MERGE and TEMPTABLE. MERGE is more efficient (pushes conditions into the base query); TEMPTABLE materializes the view result into a temp table per query. MariaDB chooses TEMPTABLE whenever the view is not mergeable (e.g., contains aggregates).
- **`DEFINER` vs `INVOKER` security**: DEFINER (default) means all users who can SELECT the view run it with the creator's permissions — powerful but dangerous if the creator has broad grants. INVOKER restricts the effective grants to those of the calling user.
- **View columns inherit names from expressions**: `(o.qty * p.price_cents)` produces an anonymous column unless aliased. Always alias computed expressions in views.
- **`SHOW TABLES` includes views**: distinguish with `SHOW FULL TABLES WHERE Table_type = 'VIEW'`.

---

Previous: [01-crud.md](01-crud.md) | Next: [03-indexes.md](03-indexes.md)
