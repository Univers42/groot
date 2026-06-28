# Database CLIs over Docker

Hands-on notes for driving **every database engine in the grobase backend from the command line — without installing a single client on the host.** This project is Docker-first: there is no host `psql`/`mysql`/`mongosh`/`redis-cli`. Each engine's client lives **inside its container**, and the two that ship without a CLI (DynamoDB, MinIO) are driven from a throwaway **sidecar client container** on the backend's Docker network.

Every command in these notes was **run against the live containers and verified** before being written down — including the version-specific gotchas each engine throws at you.

---

## The golden rule: `docker exec` in, secrets stay in

You reach a database two ways:

```bash
# 1. The client lives in the engine container → exec into it:
docker exec -it <container> <client> ...

# 2. The engine has no client (DynamoDB, MinIO) → run a sidecar on its network:
docker run --rm -it --network mini-baas_mini-baas <client-image> ...
```

**Never paste a password into a command or a file.** Every engine here holds its own
credentials in its environment; resolve them *inside* the container at runtime with
`sh -lc '... "$ENV_VAR"'` so the secret never lands in your shell history or these docs:

```bash
# good — the shell that expands $POSTGRES_USER runs INSIDE the container:
docker exec -it mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

These containers are the **grobase** backend (Docker Compose project `mini-baas`). If they
aren't running, start them with `make backend-up` from the repo root (see the root
`CLAUDE.md`). They are **not** part of the root frontend compose project.

---

## The engines (verified connection matrix)

| Engine | Container | Version | Client (where) | Open a shell |
|--------|-----------|---------|----------------|--------------|
| **PostgreSQL** | `mini-baas-postgres` | 16.14 | `psql` (in container) | `docker exec -it mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'` |
| **MySQL / MariaDB** | `mini-baas-mariadb`¹ | MariaDB 11.4 | `mariadb` (in container) | `docker exec -it mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'` |
| **SQL Server** | `mini-baas-mssql` | 2022 (16.0) | `sqlcmd` (in container) | `docker exec -it mini-baas-mssql sh -lc 'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C'` |
| **CockroachDB** | `mini-baas-cockroach` | v24.3.5 | `cockroach` (in container) | `docker exec -it mini-baas-cockroach cockroach sql --insecure` |
| **MongoDB** | `mini-baas-mongo` | 7.0.37 | `mongosh` (in container) | `docker exec -it mini-baas-mongo sh -lc 'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'` |
| **Redis** | `mini-baas-redis` | 7.2.11 | `redis-cli` (in container) | `docker exec -it mini-baas-redis redis-cli` |
| **DynamoDB Local** | `mini-baas-dynamodb-local` | local (`:8000`→host `:8500`) | `aws` (**sidecar**) | `docker run --rm -it --network mini-baas_mini-baas -e AWS_ACCESS_KEY_ID=local -e AWS_SECRET_ACCESS_KEY=local -e AWS_DEFAULT_REGION=us-east-1 amazon/aws-cli dynamodb list-tables --endpoint-url http://mini-baas-dynamodb-local:8000` |
| **MinIO** | `mini-baas-minio` | server (`:9000` API / `:9001` console) | `mc` (**sidecar**) | see [`minio/00-connect.md`](minio/00-connect.md) (fetch creds → `MC_HOST_*`) |

¹ A second MariaDB 11.4 container, `mini-baas-mysql`, also runs (root password env `MYSQL_ROOT_PASSWORD`); both are interchangeable for practice. The `mysql` command is a compatibility symlink to `mariadb`.

> **Quick reference:** one-shot (non-interactive) forms swap the interactive flag for the
> engine's "run this and exit" flag — `psql -c`, `mariadb -e`, `sqlcmd -Q`, `cockroach sql -e`,
> `mongosh --eval`, `redis-cli <cmd>`. Each engine's `00-connect.md` shows both.

---

## How to use these notes

Each engine folder is a short course. Start at its `00-connect.md`, then walk the numbered
files in order — they build on one shared dataset so the concepts compound.

### Relational SQL — PostgreSQL · MySQL/MariaDB · SQL Server · CockroachDB
Same nine-step path per engine (filenames vary slightly where the engine's model differs):

- **[postgres/](postgres/README.md)** — the reference SQL engine; includes Row-Level Security.
- **[mysql/](mysql/README.md)** — MariaDB under the hood; the `user@host` model and roles.
- **[mssql/](mssql/README.md)** — T-SQL; server *logins* vs database *users*, clustered indexes.
- **[cockroachdb/](cockroachdb/README.md)** — distributed, Postgres-compatible; serializable txns + retry loops.

Concepts covered (each engine): `00` connect · `01` CRUD · `02` views · `03` indexes ·
`04` users/roles (MSSQL: logins+users) · `05` permissions & grants · `06` security
(Postgres: RLS) · `07` backup & restore · `08` transactions & isolation.

### Document / key-value / object
- **[mongodb/](mongodb/README.md)** — documents & collections: CRUD · indexes · aggregation & views · users/roles · security · backup.
- **[redis/](redis/README.md)** — in-memory data structures: connect · data-type CRUD · keys & TTL · pub/sub & streams · ACL users · security & persistence.
- **[dynamodb/](dynamodb/README.md)** — NoSQL key design: connect · tables & indexes (GSI/LSI) · item CRUD · query vs scan · IAM security.
- **[minio/](minio/README.md)** — S3-compatible object storage: connect · buckets & objects · users & policies · security.

---

## Shared sample domain

The SQL guides build one tiny **shop** so views/indexes/permissions all operate on the same
data (the document/object guides adapt it naturally):

```text
customers(id, name, email, created_at)
products (id, name, price_cents, stock)
orders   (id, customer_id → customers, product_id → products, qty, status, created_at)
```

---

## Practice safely (these are live backend databases)

The engine containers hold real grobase/demo data. **Do your learning in a throwaway
namespace and never touch existing objects:**

| Engine(s) | Scratch namespace | Cleanup |
|-----------|-------------------|---------|
| Postgres · MariaDB · SQL Server · Cockroach · Mongo | a `learn_cli` database | `DROP DATABASE learn_cli;` (Mongo: `use learn_cli; db.dropDatabase()`) |
| Redis | logical DB **15** (`redis-cli -n 15`) + `learn:` key prefix | `redis-cli -n 15 FLUSHDB` — **never** `FLUSHALL` |
| DynamoDB · MinIO | tables/buckets prefixed `learn_` / `learn-` | `delete-table` / `mc rb --force` |

> Move files in and out of any container with `docker cp` — that's how the backup/restore
> guides shuttle dump files without host tooling.

---

*Generated and verified against the running `mini-baas` stack. If an engine is upgraded,
re-verify the version-specific notes (clustered-index syntax, isolation defaults, auth
plugins, removed commands like Cockroach's `dump`).*
