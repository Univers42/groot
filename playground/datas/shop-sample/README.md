# shop-sample — original cross-engine practice dataset

A tiny, **original** dataset (no licensing strings attached) you can push into *any* of our engines
to practice the [CS50 SQL lessons](../../../wiki/database-cli/cs50-sql/README.md) and the
[engine CLI guides](../../../wiki/database-cli/README.md). It's the same shop schema used throughout
those notes, so examples there work verbatim here.

## Contents

| File | Rows | Shape |
|------|------|-------|
| `customers.csv` | 8 | `id, name, email, created_at` |
| `products.csv` | 6 | `id, name, price_cents, stock` |
| `orders.csv` | 15 | `id, customer_id, product_id, qty, status, created_at` |
| `schema.sql` | — | canonical table definitions (PostgreSQL dialect; loaders adapt per engine) |

`orders` is the junction relating `customers` ⇄ `products` (many-to-many), and `status` is one of
`pending / paid / shipped / cancelled` — handy for `GROUP BY`, `CHECK` constraints, joins, and views.

## Load it into an engine

```bash
# CSV directory → engine (creates schema + imports), into the learn_shop scratch DB:
bash ../loaders/load-postgres.sh   .
bash ../loaders/load-mysql.sh      .
bash ../loaders/load-mssql.sh      .
bash ../loaders/load-cockroach.sh  .
bash ../loaders/load-mongo.sh      .     # → collections
bash ../loaders/load-redis.sh      .     # → hashes keyed by id
bash ../loaders/load-dynamodb.sh   .     # → items
bash ../loaders/load-minio.sh      .     # → objects in a bucket
```

See [`../loaders/README.md`](../loaders/README.md) for what each loader does and how to verify.

## Quick practice prompts

Once loaded (e.g. into Postgres `learn_shop`):

1. Top 3 most expensive products. *(`ORDER BY`, `LIMIT`)*
2. Each customer's total number of shipped orders. *(`JOIN`, `GROUP BY`, `WHERE`/`HAVING`)*
3. Revenue per product = `SUM(qty * price_cents)`. *(`JOIN`, aggregate, `AS`)*
4. Customers with no orders. *(`LEFT JOIN ... IS NULL` or `NOT IN`)*
5. A view `order_summary(order_id, customer, product, qty, cents)`. *(`CREATE VIEW`)*
6. Index `orders(customer_id)` and compare `EXPLAIN` before/after.

---

*Original content — free to use, modify, and commit. Unlike the `../cs50/` datasets, this one is
ours.*
