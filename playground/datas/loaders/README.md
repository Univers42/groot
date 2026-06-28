# loaders — inject a dataset into any engine (Docker-only)

Scripts that take a CSV directory (or a SQLite `.db`) and load it into one of our database engines.
Every loader is **Docker-only** (no host clients), reads engine credentials from each container's own
environment at runtime, loads into a **throwaway scratch namespace** so real data is never touched,
and is **safe to re-run**. All ten were verified live against the shop-sample data (counts 8 / 6 / 15).

## The loaders

| Script | Engine | Scratch namespace | How it loads |
|--------|--------|-------------------|--------------|
| `load-postgres.sh [csv-dir]` | PostgreSQL 16 | db `learn_shop` | `psql \copy FROM STDIN` |
| `load-mysql.sh [csv-dir]` | MariaDB 11.4 | db `learn_shop` | generated `INSERT`s piped to `mariadb` |
| `load-mssql.sh [csv-dir]` | SQL Server 2022 | db `learn_shop` | generated `INSERT`s + `GO` to `sqlcmd` |
| `load-cockroach.sh [csv-dir]` | CockroachDB v24.3 | db `learn_shop` | generated `INSERT`s to `cockroach sql` |
| `load-mongo.sh [csv-dir]` | MongoDB 7 | db `learn_shop` | `mongoimport` (via `mongo:7` sidecar) |
| `load-redis.sh [csv-dir]` | Redis | DB **15**, `shop:` prefix | `redis-cli --pipe` (rows → hashes) |
| `load-dynamodb.sh [csv-dir]` | DynamoDB Local | tables `learn_shop_*` | `batch-write-item` (via `amazon/aws-cli` sidecar) |
| `load-minio.sh [csv-dir]` | MinIO | bucket `learn-shop` | `mc cp` (via `minio/mc` sidecar) |
| `sqlite-to-csv.sh <db> <out>` | — | — | dumps every table of a SQLite `.db` → CSVs (via `alpine`+`sqlite3`) |
| `load-cs50-postgres.sh <db> [target]` | PostgreSQL 16 | db `learn_<name>` | whole `.db` schema+data via `pgloader` sidecar |

`[csv-dir]` defaults to `../shop-sample`. The CSV loaders expect `customers.csv`, `products.csv`,
`orders.csv` (load order respects the foreign keys). Each prints a row-count summary when it finishes.

## Use it

```bash
cd playground/datas

# 1) Load the bundled sample into an engine:
bash loaders/load-postgres.sh                 # defaults to ./shop-sample
bash loaders/load-mongo.sh    shop-sample
bash loaders/load-redis.sh    shop-sample

# 2) Then connect and practice (full connect guides: ../../wiki/database-cli/<engine>/00-connect.md):
docker exec -it mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_shop'
docker exec -it mini-baas-mariadb  sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_shop'
docker exec -it mini-baas-mssql    sh -lc 'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_shop'
docker exec -it mini-baas-cockroach cockroach sql --insecure -d learn_shop
docker exec -it mini-baas-mongo    sh -lc 'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin learn_shop'
docker exec -it mini-baas-redis    redis-cli -n 15        # keys: shop:customer:1 …
```

## Using a CS50 dataset

CS50's data is SQLite. Two paths into our engines:

```bash
# A) Fetch, then push the WHOLE sqlite db into Postgres with schema intact (pgloader):
bash cs50/fetch.sh
bash loaders/load-cs50-postgres.sh cs50/downloads/pset1-relating/packages/packages.db
#   → creates Postgres db "learn_packages"

# B) Or convert the sqlite db to CSVs, then use any CSV loader above:
bash loaders/sqlite-to-csv.sh cs50/downloads/pset1-relating/packages/packages.db /tmp/packages-csv
#   (CS50 schemas differ from the shop schema — adapt the CSV loader's table DDL to match,
#    or use path A which derives the schema automatically.)
```

> **`load-cs50-postgres.sh` — verified end-to-end.** It migrates schema, data, primary keys and
> indexes in one shot (e.g. an 8/6/15-row SQLite db lands complete in Postgres). The only cost is
> that the first run pulls the `dimitri/pgloader` image (~500 MB); on a constrained/offline box that
> pull is slow, so pre-pull it (`docker pull dimitri/pgloader`) or use the `sqlite-to-csv.sh` path.

## Notes

- **Idempotent:** each loader clears its own scratch namespace first, so re-running gives the same
  result (verified). It does **not** touch any other database/keyspace/bucket.
- **Cleanup:** drop what a loader created with the engine's normal command — e.g.
  `DROP DATABASE learn_shop;` (SQL/Mongo), `redis-cli -n 15 FLUSHDB`, `delete-table learn_shop_*`,
  `mc rb --force baas/learn-shop`.
- **Secrets** are read from each container's env at runtime; none are written into these scripts.
- The shop CSVs have no embedded commas/quotes, so the CSV parsing is intentionally simple. For
  arbitrary CSVs, prefer the engine's native bulk-import (see each engine's guide) or pgloader.

---

*Loaders operate only on `learn_shop` / `learn-shop` / Redis DB 15 scratch namespaces. The
`shop-sample` data is original to this repo; CS50 datasets are fetched from
<https://cs50.harvard.edu/sql/> (CC BY-NC-SA 4.0) and never committed here.*
