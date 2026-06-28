# CS50 SQL — Study Notes (Lessons 0–6)

Original study notes that follow the curriculum of **CS50's *Introduction to Databases with
SQL*** (Harvard), rewritten in our own words and adapted to run on **this project's Docker
database stack** — so every concept links back to the engine guides in [`../`](../README.md)
and uses our shop schema instead of the course's datasets.

> **Attribution & license.** These are **original** notes summarizing the *topics* of CS50's
> *Introduction to Databases with SQL*. They are **not** a copy of CS50's lecture notes — for
> the canonical text, watch/read the originals at **<https://cs50.harvard.edu/sql/>**. CS50's
> course and materials are © President and Fellows of Harvard College and licensed
> [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) (Attribution ·
> NonCommercial · ShareAlike). This wiki is a personal, non-commercial study aid.

---

## The course vs. our stack

CS50 teaches with **SQLite** — a single-file, embedded database opened in DB Browser or VS Code.
Our stack runs **server** engines in Docker (PostgreSQL, MySQL/MariaDB, SQL Server, …) reached
only via `docker exec`. The *SQL concepts are identical*; the differences are mostly syntax and
how you connect. Each lesson flags the SQLite-vs-server gaps (e.g. `AUTOINCREMENT` → `SERIAL`/
`IDENTITY`, type *affinity* → strict typed columns, opening a `.db` file → `docker exec ... psql`)
and points at the matching engine guide.

When an example here is engine-agnostic, run it in Postgres:

```bash
docker exec -it mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

Want to mirror CS50 exactly with real SQLite (it isn't part of the mini-baas stack)? Spin up a
throwaway container:

```bash
docker run --rm -it alpine sh -lc 'apk add --no-cache sqlite && sqlite3 learn.db'
```

---

## The seven lessons

| # | Lesson | You learn | Maps to your engine guides |
|---|--------|-----------|----------------------------|
| 0 | [Querying](lesson-0-querying.md) | `SELECT`, `WHERE`, `LIKE`, ranges, `ORDER BY`, `LIMIT`, aggregates, `DISTINCT` | [postgres/01-crud](../postgres/01-crud.md) · [00-connect](../postgres/00-connect.md) |
| 1 | [Relating](lesson-1-relating.md) | keys, ER diagrams, subqueries, `IN`, `JOIN` types, sets, `GROUP BY`/`HAVING` | [postgres/01-crud](../postgres/01-crud.md) · [mongodb/03-aggregation-views](../mongodb/03-aggregation-views.md) |
| 2 | [Designing](lesson-2-designing.md) | schema design, normalization, `CREATE TABLE`, types, constraints, `ALTER TABLE` | [postgres/01-crud](../postgres/01-crud.md) · [mysql/01-crud](../mysql/01-crud.md) |
| 3 | [Writing](lesson-3-writing.md) | `INSERT`/`UPDATE`/`DELETE`, CSV import, triggers, soft deletes, cascades | [postgres/01-crud](../postgres/01-crud.md) |
| 4 | [Viewing](lesson-4-viewing.md) | `CREATE VIEW`, CTEs (`WITH`), partitioning, securing data, `INSTEAD OF` triggers | [postgres/02-views](../postgres/02-views.md) · [mssql/02-views](../mssql/02-views.md) · [mongodb/03-aggregation-views](../mongodb/03-aggregation-views.md) |
| 5 | [Optimizing](lesson-5-optimizing.md) | indexes, B-trees, covering/partial indexes, `EXPLAIN`, `VACUUM`, transactions, ACID, locks, race conditions | [postgres/03-indexes](../postgres/03-indexes.md) · [postgres/08-transactions-isolation](../postgres/08-transactions-isolation.md) |
| 6 | [Scaling](lesson-6-scaling.md) | MySQL & PostgreSQL servers, stored procedures, access control (`GRANT`), SQL injection & prepared statements, replication & sharding | [mysql/](../mysql/README.md) · [postgres/05-permissions-grants](../postgres/05-permissions-grants.md) · [mysql/06-security](../mysql/06-security.md) |

---

## How to practice

Use the same Docker scratch-database convention as the engine guides — do all practice inside a
throwaway `learn_cli` database, never against real data (see [../README.md](../README.md#practice-safely-these-are-live-backend-databases)).
Most examples here use our shop schema:

```text
customers(id, name, email, created_at)
products (id, name, price_cents, stock)
orders   (id, customer_id → customers, product_id → products, qty, status, created_at)
```

---

*Original notes following CS50's *Introduction to Databases with SQL*. Course © Harvard,
CC BY-NC-SA 4.0 — canonical materials at <https://cs50.harvard.edu/sql/>.*
