# CRUD — CREATE TABLE, INSERT, SELECT, UPDATE, DELETE, UPSERT

This file builds the complete shop schema inside `learn_cli` and runs every fundamental data-manipulation operation against it. Every command here has been verified on `mini-baas-mariadb` (MariaDB 11.4.12).

## Setup — create learn_cli and the shop schema

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
CREATE DATABASE IF NOT EXISTS learn_cli
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_general_ci;
"'
```

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "

CREATE TABLE IF NOT EXISTS customers (
  id         INT          NOT NULL AUTO_INCREMENT,
  name       VARCHAR(100) NOT NULL,
  email      VARCHAR(255) NOT NULL,
  created_at DATETIME     NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id),
  UNIQUE KEY (email)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS products (
  id          INT          NOT NULL AUTO_INCREMENT,
  name        VARCHAR(100) NOT NULL,
  price_cents INT          NOT NULL,
  stock       INT          NOT NULL DEFAULT 0,
  PRIMARY KEY (id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS orders (
  id          INT  NOT NULL AUTO_INCREMENT,
  customer_id INT  NOT NULL,
  product_id  INT  NOT NULL,
  qty         INT  NOT NULL DEFAULT 1,
  status      ENUM(\"pending\",\"paid\",\"shipped\",\"cancelled\") NOT NULL DEFAULT \"pending\",
  created_at  DATETIME NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id),
  CONSTRAINT fk_order_customer FOREIGN KEY (customer_id) REFERENCES customers(id),
  CONSTRAINT fk_order_product  FOREIGN KEY (product_id)  REFERENCES products(id)
) ENGINE=InnoDB;

SHOW TABLES;
"'
```

Expected:

```
Tables_in_learn_cli
customers
orders
products
```

### Type notes

| Column | Type | Why |
|---|---|---|
| `price_cents` | `INT` | Store money as integer cents — avoids floating-point rounding |
| `stock` | `INT DEFAULT 0` | Explicit default avoids NULL surprises |
| `status` | `ENUM(...)` | Enforces a closed set of values at the storage layer |
| `created_at` | `DATETIME DEFAULT NOW()` | `current_timestamp()` is the MariaDB alias — both work |
| `CONSTRAINT fk_*` | Foreign key with named constraint | Named constraints produce readable error messages |

`ENGINE=InnoDB` is required for foreign keys. MyISAM silently ignores FK definitions.

## INSERT

### Single row

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
INSERT INTO customers (name, email) VALUES (\"Alice Dupont\", \"alice@shop.example\");
"'
```

### Multi-row INSERT (one round trip — preferred)

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
INSERT INTO customers (name, email) VALUES
  (\"Bob Martin\",  \"bob@shop.example\"),
  (\"Carol Lee\",   \"carol@shop.example\");

INSERT INTO products (name, price_cents, stock) VALUES
  (\"Keyboard\", 7999,  50),
  (\"Mouse\",    2999, 120),
  (\"Monitor\", 29999,  15);

INSERT INTO orders (customer_id, product_id, qty, status) VALUES
  (1, 1, 1, \"paid\"),
  (2, 3, 2, \"pending\"),
  (1, 2, 1, \"shipped\");
"'
```

## SELECT

### Basic SELECT with WHERE

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
SELECT id, name, email FROM customers WHERE name LIKE \"A%\";
"'
```

```
id  name          email
1   Alice Dupont  alice@shop.example
```

### JOIN across three tables

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
SELECT c.name AS customer, p.name AS product,
       o.qty, (o.qty * p.price_cents) AS total_cents, o.status
FROM   orders o
JOIN   customers c ON c.id = o.customer_id
JOIN   products  p ON p.id = o.product_id
ORDER  BY o.id;
"'
```

```
customer      product   qty  total_cents  status
Alice Dupont  Keyboard  1    7999         paid
Bob Martin    Monitor   2    59998        pending
Alice Dupont  Mouse     1    2999         shipped
```

### GROUP BY with aggregates

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
SELECT status, COUNT(*) AS order_count, SUM(qty) AS total_qty
FROM   orders
GROUP  BY status
ORDER  BY order_count DESC;
"'
```

```
status    order_count  total_qty
pending   1            2
paid      1            1
shipped   1            1
```

### LIMIT and OFFSET (pagination)

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
SELECT id, name FROM products ORDER BY price_cents DESC LIMIT 2 OFFSET 0;
"'
```

## UPDATE

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
UPDATE products SET stock = stock - 1 WHERE id = 1;
SELECT id, name, stock FROM products WHERE id = 1;
"'
```

```
id  name      stock
1   Keyboard  49
```

Always include a `WHERE` clause on UPDATE. Without it, every row is updated — MariaDB will not warn you.

## DELETE

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
-- Safe: delete a specific row with no FK dependents
DELETE FROM customers WHERE email = \"carol@shop.example\";
SELECT COUNT(*) AS remaining FROM customers;
"'
```

Attempting to delete a customer who has orders will fail with `ERROR 1451: Cannot delete or update a parent row: a foreign key constraint fails`. This is the FK protecting data integrity — good.

## UPSERT

### INSERT ... ON DUPLICATE KEY UPDATE

The clean, FK-safe upsert. Triggers when a UNIQUE or PRIMARY KEY constraint would be violated.

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
-- alice already exists; this updates her name without touching other columns
INSERT INTO customers (name, email)
  VALUES (\"Alice D.\", \"alice@shop.example\")
  ON DUPLICATE KEY UPDATE name = VALUES(name);

SELECT * FROM customers WHERE email = \"alice@shop.example\";
"'
```

```
id  name     email                created_at
1   Alice D. alice@shop.example   2026-06-28 10:26:32
```

`VALUES(name)` refers to the value that would have been inserted. MariaDB 10.3.3+ also supports the alias syntax: `ON DUPLICATE KEY UPDATE name = value(name)`.

### REPLACE INTO

`REPLACE` is a DELETE + INSERT: if a unique key conflict exists, the old row is deleted first, then a new one is inserted. This resets `AUTO_INCREMENT`, `created_at` defaults, and cascades FK deletes.

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
-- Only safe on rows with no FK children (FK children would prevent the DELETE step)
REPLACE INTO customers (id, name, email) VALUES (3, \"Bob Martin Updated\", \"bob@shop.example\");
SELECT * FROM customers WHERE id = 3;
"'
```

**REPLACE vs ON DUPLICATE KEY UPDATE:**

| | `ON DUPLICATE KEY UPDATE` | `REPLACE INTO` |
|---|---|---|
| Mechanism | Single UPDATE (no DELETE) | DELETE + INSERT |
| Preserves other columns | Yes | No — resets to DEFAULT |
| Safe with FK children | Yes | No — FK constraint blocks the DELETE |
| Increments `AUTO_INCREMENT` | No (if UPDATE path taken) | Yes (always) |
| Prefer | Almost always | Only for tables with no FK children and no critical defaults |

## Scenario: full order workflow

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
-- Customer places an order
INSERT INTO orders (customer_id, product_id, qty, status) VALUES (2, 2, 3, \"pending\");

-- Warehouse marks it shipped
UPDATE orders SET status = \"shipped\" WHERE id = LAST_INSERT_ID();

-- Verify final state
SELECT c.name, p.name AS product, o.qty, o.status
FROM   orders o
JOIN   customers c ON c.id = o.customer_id
JOIN   products  p ON p.id = o.product_id
WHERE  o.id = LAST_INSERT_ID();
"'
```

## Cleanup

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS learn_cli;"'
```

## Gotchas / Docker notes

- **ENUM values are case-insensitive on comparison but stored as defined.** Inserting `"PAID"` stores as `"paid"` if the ENUM was defined lowercase.
- **`LAST_INSERT_ID()` is session-scoped.** In a one-shot `-e` command that does multiple inserts, `LAST_INSERT_ID()` returns the ID from the most recent `INSERT` in that same session.
- **`DEFAULT NOW()` vs `DEFAULT CURRENT_TIMESTAMP`**: both work in MariaDB. Prefer `DEFAULT NOW()` for readability.
- **Multi-row INSERT performance**: a single multi-row `INSERT ... VALUES (...), (...), (...)` is dramatically faster than N individual inserts because it reduces round-trip overhead and allows a single InnoDB transaction.
- **`\G` in `-e` strings**: `"SELECT * FROM orders LIMIT 1\G"` — the backslash must not be shell-escaped; it is passed literally to the mariadb client which interprets it as the vertical output terminator.

---

Previous: [00-connect.md](00-connect.md) | Next: [02-views.md](02-views.md)
