# 00 — Connecting to CockroachDB

The `cockroach` binary lives inside the container. Every session is a `docker exec` call — nothing runs on the host.

## Interactive shell

```bash
docker exec -it mini-baas-cockroach cockroach sql --insecure
```

You land at a prompt like `root@:26257/defaultdb>`. The `-it` flags are mandatory for an interactive shell (allocates a TTY).

Connect directly to a specific database:

```bash
docker exec -it mini-baas-cockroach cockroach sql --insecure --database=learn_cli
# prompt changes to: root@:26257/learn_cli>
```

## One-shot queries with `-e`

Run a single statement and return to the host shell:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "SELECT version();"
```

Expected output:

```
version
CockroachDB CCL v24.3.5 (x86_64-pc-linux-gnu, built 2025/02/03 17:28:15, ...)
```

Combine `--database` and `-e` for scoped one-shots:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli \
  -e "SELECT name, email FROM customers LIMIT 5;"
```

## Running a `.sql` file with `-f`

There is no shared filesystem between host and container, so copy the file in first:

```bash
# 1. Copy the script into the container
docker cp ./schema.sql mini-baas-cockroach:/tmp/schema.sql

# 2. Execute it
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli \
  -f /tmp/schema.sql
```

Note: `-f` and `--watch` are incompatible with interactive mode (`-it`).

## Useful shell meta-commands

These work inside the interactive shell and also via `-e` (CockroachDB passes them through the PG wire):

```sql
-- List all databases (PG-style)
\l

-- List tables in the current database
\dt

-- Describe a table (columns, indexes, FK references)
\d customers

-- Exit the shell
\q
```

All of the above also have SQL equivalents that are often cleaner in scripts:

```sql
SHOW DATABASES;
SHOW TABLES;
SHOW CREATE TABLE customers;
```

## Listing databases and tables

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "SHOW DATABASES;"
```

```
database_name  owner  primary_region  secondary_region  regions  survival_goal
defaultdb      root   NULL            NULL              {}       NULL
learn_cli      root   NULL            NULL              {}       NULL
postgres       root   NULL            NULL              {}       NULL
system         node   NULL            NULL              {}       NULL
```

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli \
  -e "SHOW TABLES;"
```

```
schema_name  table_name  type   owner  estimated_row_count  locality
public       customers   table  root   3                    NULL
public       orders      table  root   1                    NULL
public       products    table  root   3                    NULL
```

## Checking shell settings (`\set`)

Inside the interactive shell, `\set` lists all display options and their current values:

```sql
\set
```

Useful toggles:

```sql
\set display_format table   -- render output as aligned table (default is tsv)
\set show_times on          -- show query execution time after every statement
```

## Creating the scratch database

All exercises in this guide use `learn_cli`. Create it once and drop it when done:

```bash
# Create
docker exec mini-baas-cockroach cockroach sql --insecure \
  -e "CREATE DATABASE IF NOT EXISTS learn_cli;"

# Cleanup when finished
docker exec mini-baas-cockroach cockroach sql --insecure \
  -e "DROP DATABASE learn_cli CASCADE;"
```

## DB Console (web UI)

The CockroachDB admin UI is mapped to host port `28080`. Open it in a browser at:

```
http://localhost:28080
```

It shows cluster health, statement statistics, slow queries, and range distribution. No login is required in insecure mode.

## Gotchas / Docker notes

- **No `-it` for scripts.** Omit `-it` when piping or scripting; including it with non-TTY input causes a "input device is not a TTY" error.
- **`cockroach dump` is removed.** In v24.3.5 the `dump` subcommand no longer exists. Use `BACKUP`/`EXPORT` instead (see [07-backup-restore.md](07-backup-restore.md)).
- **PG wire also works.** `psql` from another container (e.g., `mini-baas-postgres`) can connect: `psql -h mini-baas-cockroach -p 26257 -U root`. Useful for tools that speak PG but not the `cockroach` binary.
- **Port 26257** is the SQL port; **8080** inside the container (28080 on the host) is the HTTP admin UI.

---

[README](README.md) | [01-crud.md](01-crud.md) →
