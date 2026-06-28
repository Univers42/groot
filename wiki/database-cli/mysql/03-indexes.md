# Indexes

An index is a B-Tree (or other) data structure maintained alongside table data. It speeds up lookups at the cost of additional storage and slower writes. Understanding when to add indexes — and when not to — is one of the highest-leverage skills in MariaDB tuning.

## Prerequisites

This file assumes the `learn_cli` shop schema from [01-crud.md](01-crud.md) is populated.

## CREATE INDEX

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
CREATE INDEX idx_order_status ON orders(status);
"'
```

The default index type is BTREE. For InnoDB, MariaDB automatically creates a clustered index on the PRIMARY KEY; secondary indexes store the primary key value as the row pointer.

### UNIQUE index

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
-- customers.email is already UNIQUE from CREATE TABLE; this shows the explicit syntax:
CREATE UNIQUE INDEX idx_product_name_unique ON products(name);
"'
```

A UNIQUE index enforces the constraint and speeds up lookups on that column simultaneously.

### Composite index (multi-column)

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
CREATE INDEX idx_order_status_created ON orders(status, created_at);
"'
```

This index can serve queries that filter on `status` alone (leftmost prefix) or on `(status, created_at)` together. It cannot serve a query that filters only on `created_at` — see the leftmost-prefix rule below.

### Prefix index (on long strings)

Index only the first N characters of a VARCHAR or TEXT column to reduce index size:

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
CREATE INDEX idx_customer_email_prefix ON customers(email(20));
"'
```

Useful when indexing large VARCHAR/TEXT columns. The downside: MariaDB may need to read the full row to resolve queries where the first 20 characters are not selective enough.

### FULLTEXT index

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
CREATE FULLTEXT INDEX idx_product_ft ON products(name);

-- Use MATCH ... AGAINST for fulltext queries:
SELECT id, name FROM products
WHERE  MATCH(name) AGAINST(\"keyboard\" IN BOOLEAN MODE);
"'
```

```
id  name
1   Keyboard
```

FULLTEXT indexes in InnoDB use the stopword list and minimum word length (`ft_min_word_len`). Very short words (< 4 chars by default) are ignored. Boolean mode (`IN BOOLEAN MODE`) supports operators: `+keyboard` (must include), `-mouse` (must exclude), `key*` (prefix wildcard).

## SHOW INDEX FROM

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
SHOW INDEX FROM orders\G
"'
```

```
*************************** 1. row ***************************
        Table: orders
   Non_unique: 0
     Key_name: PRIMARY
 Seq_in_index: 1
  Column_name: id
    Collation: A
  Cardinality: 3
     Sub_part: NULL
       Packed: NULL
         Null:
   Index_type: BTREE

*************************** 3. row ***************************
     Key_name: idx_order_status_created
 Seq_in_index: 1
  Column_name: status
...
*************************** 4. row ***************************
     Key_name: idx_order_status_created
 Seq_in_index: 2
  Column_name: created_at
```

Key columns: `Non_unique` (0 = unique), `Seq_in_index` (position in composite index), `Cardinality` (estimated distinct values — higher is more selective), `Sub_part` (prefix length, NULL if full column).

## EXPLAIN — verify index usage

Always check `EXPLAIN` to confirm an index is actually being used:

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
EXPLAIN SELECT id, status FROM orders WHERE status = \"pending\"\G
"'
```

```
*************************** 1. row ***************************
           id: 1
  select_type: SIMPLE
        table: orders
         type: ref
possible_keys: idx_order_status,idx_order_status_created
          key: idx_order_status_created
      key_len: 1
          ref: const
         rows: 1
        Extra:
```

Key EXPLAIN fields:

| Field | What it means |
|---|---|
| `type` | `const`/`eq_ref`/`ref` = index used; `ALL` = full table scan |
| `possible_keys` | Indexes MariaDB considered |
| `key` | Index actually chosen |
| `key_len` | Bytes of the index used (shorter = fewer columns used from composite) |
| `rows` | Estimated rows scanned — lower is better |
| `Extra` | `Using index` = index-only scan (very fast); `Using filesort` = avoidable sort |

## DROP INDEX

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
DROP INDEX idx_customer_email_prefix ON customers;
DROP INDEX idx_product_name_unique ON products;
"'
```

`DROP INDEX` requires the table name. You cannot drop a PRIMARY KEY with `DROP INDEX` — use `ALTER TABLE t DROP PRIMARY KEY` instead.

## The leftmost-prefix rule

For a composite index `(A, B, C)`:

| Query filter | Index used? |
|---|---|
| `WHERE A = ?` | Yes — leftmost prefix |
| `WHERE A = ? AND B = ?` | Yes — first two columns |
| `WHERE A = ? AND B = ? AND C = ?` | Yes — full index |
| `WHERE B = ?` | No — B is not the leftmost column |
| `WHERE A = ? AND C = ?` | Partially — only A used; C skipped over B |
| `ORDER BY A, B` | Yes — can satisfy sort without filesort |

For `idx_order_status_created(status, created_at)`: a query `WHERE created_at > ?` cannot use this index efficiently because `status` (the leftmost column) is not constrained.

## Scenario: diagnosing a slow order query

The warehouse manager runs a report: "all shipped orders in the last 7 days". Without an index, this scans the full `orders` table:

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
EXPLAIN SELECT * FROM orders
WHERE  status = \"shipped\"
AND    created_at >= NOW() - INTERVAL 7 DAY\G
"'
```

With `idx_order_status_created(status, created_at)` in place, EXPLAIN shows `key: idx_order_status_created` and `type: range` — the composite index covers both conditions.

## When NOT to index

- **Low-cardinality columns**: a column with only 2–3 distinct values (like a boolean or small ENUM) used in isolation. The index scan plus row fetch often costs more than a full table scan.
- **Very small tables** (< ~1000 rows): the table fits in one or two data pages; a full scan is faster than index traversal.
- **Write-heavy tables**: every INSERT, UPDATE, or DELETE must also update all indexes on the table. Over-indexing multiplies write amplification.
- **Columns that are only used in aggregates without WHERE**: `SELECT COUNT(*)` on the whole table doesn't benefit from a non-covering secondary index.

## Cleanup

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "
DROP INDEX idx_order_status ON orders;
DROP INDEX idx_order_status_created ON orders;
DROP INDEX idx_product_ft ON products;
"'
```

## Gotchas / Docker notes

- **InnoDB auto-creates secondary indexes for FK constraints.** When you define `FOREIGN KEY (customer_id) REFERENCES customers(id)`, MariaDB silently creates an index on `customer_id` if one doesn't exist. `SHOW INDEX FROM orders` will show it as `Key_name: fk_order_customer`.
- **`ALTER TABLE` is the alternative DDL syntax**: `ALTER TABLE orders ADD INDEX idx_status (status)` is equivalent to `CREATE INDEX idx_status ON orders(status)`. Both work; `CREATE INDEX` is cleaner for standalone index management.
- **FULLTEXT on InnoDB** requires MariaDB 10.0+ (it does). On MyISAM it has always worked. In this stack we use InnoDB everywhere.
- **Index rebuilds are table-level locks** on older storage engines. InnoDB in MariaDB 11.x uses online DDL for most index operations — adding or dropping a secondary index does not lock the table for reads.

---

Previous: [02-views.md](02-views.md) | Next: [04-users.md](04-users.md)
