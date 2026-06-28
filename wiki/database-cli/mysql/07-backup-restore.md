# Backup and Restore

`mariadb-dump` (and its alias `mysqldump`) produces a plain-SQL dump file that can be piped straight back into `mariadb` to restore. Everything runs inside the container via `docker exec`; use `docker cp` to move files between the container filesystem and the host.

## Tools available

| Container | Dump binary | Notes |
|---|---|---|
| `mini-baas-mariadb` | `mariadb-dump` (preferred), `mysqldump` (deprecated alias) | Both produce identical output |
| `mini-baas-mysql` | `mysqldump` | `mariadb-dump` not installed |

`mysqldump` in `mini-baas-mariadb` prints: `Deprecated program name. It will be removed in a future release, use '/usr/bin/mariadb-dump' instead`. The output is otherwise identical.

## Prerequisites

This file assumes the `learn_cli` database exists with shop data from [01-crud.md](01-crud.md).

## Dump a whole database

```bash
docker exec mini-baas-mariadb sh -lc \
  'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction learn_cli \
   > /tmp/learn_cli_full.sql'
```

`--single-transaction`: wraps the dump in a `BEGIN` so InnoDB tables are read in a consistent snapshot without taking locks. Essential for live databases — without it, concurrent writes may produce an inconsistent dump.

Verify the dump was written:

```bash
docker exec mini-baas-mariadb sh -lc 'wc -l /tmp/learn_cli_full.sql && head -5 /tmp/learn_cli_full.sql'
```

```
161 /tmp/learn_cli_full.sql
/*M!999999\- enable the sandbox mode */
-- MariaDB dump 10.19-11.4.12-MariaDB, for Linux (x86_64)
-- Host: localhost    Database: learn_cli
```

The `/*M!999999\- enable the sandbox mode */` header is a MariaDB sandbox directive — harmless and ignored by older MySQL clients.

## Copy the dump to the host

```bash
docker cp mini-baas-mariadb:/tmp/learn_cli_full.sql ./learn_cli_full.sql
```

Confirm:

```bash
ls -lh ./learn_cli_full.sql
```

## Dump a single table

```bash
docker exec mini-baas-mariadb sh -lc \
  'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction \
   learn_cli customers > /tmp/customers_only.sql'
```

The table name follows the database name — no flag needed.

## Schema-only dump (no data)

```bash
docker exec mini-baas-mariadb sh -lc \
  'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --no-data learn_cli \
   > /tmp/learn_cli_schema.sql'
```

`--no-data` (or `-d`) omits all `INSERT` statements. Useful for version-controlling schema or spinning up an empty clone.

## Data-only dump (no DDL)

```bash
docker exec mini-baas-mariadb sh -lc \
  'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --no-create-info learn_cli \
   > /tmp/learn_cli_data.sql'
```

`--no-create-info` omits `CREATE TABLE` statements. Use when the target already has the schema.

## Dump with compressed output

```bash
docker exec mini-baas-mariadb sh -lc \
  'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction learn_cli | gzip \
   > /tmp/learn_cli.sql.gz'
```

## Restore — full database

```bash
# Step 1: create the target database (if it doesn't exist)
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
  CREATE DATABASE IF NOT EXISTS learn_cli_restore
    CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
"'

# Step 2: copy the dump into the container
docker cp ./learn_cli_full.sql mini-baas-mariadb:/tmp/learn_cli_restore.sql

# Step 3: restore
docker exec mini-baas-mariadb sh -lc \
  'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli_restore < /tmp/learn_cli_restore.sql'

# Step 4: verify
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli_restore -e "
  SHOW TABLES;
  SELECT COUNT(*) AS customers FROM customers;
  SELECT COUNT(*) AS orders    FROM orders;
"'
```

```
Tables_in_learn_cli_restore
customers
order_summary
orders
products

customers
3
orders
3
```

The view (`order_summary`) is included in the dump automatically.

## Restore a gzip-compressed dump

```bash
docker cp ./learn_cli.sql.gz mini-baas-mariadb:/tmp/learn_cli.sql.gz
docker exec mini-baas-mariadb sh -lc \
  'gunzip -c /tmp/learn_cli.sql.gz | mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli_restore'
```

## Scenario: daily backup script

A shell script that creates a timestamped dump on the host:

```bash
#!/usr/bin/env bash
# backup-mariadb.sh — run from the host, requires docker in PATH
set -euo pipefail

CONTAINER="mini-baas-mariadb"
DATABASE="learn_cli"
DEST="./backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DUMPFILE="${DEST}/${DATABASE}_${TIMESTAMP}.sql.gz"

mkdir -p "$DEST"

docker exec "$CONTAINER" sh -lc \
  "mariadb-dump -uroot -p\"\$MARIADB_ROOT_PASSWORD\" --single-transaction $DATABASE | gzip" \
  > "$DUMPFILE"

echo "Backup written to $DUMPFILE ($(du -sh "$DUMPFILE" | cut -f1))"
```

The key detail: the `\$MARIADB_ROOT_PASSWORD` is intentionally escaped so the shell does NOT expand it on the host — it is passed verbatim to `sh -lc` inside the container, where the variable IS defined.

## Useful dump flags reference

| Flag | Meaning |
|---|---|
| `--single-transaction` | Consistent InnoDB snapshot — **always use for live databases** |
| `--no-data` / `-d` | Schema only, no INSERT statements |
| `--no-create-info` | Data only, no CREATE TABLE |
| `--no-create-db` | Omit `CREATE DATABASE` + `USE` statements (useful when restoring into existing DB) |
| `--add-drop-table` | Prepend `DROP TABLE IF EXISTS` before each `CREATE TABLE` (default: on) |
| `--skip-add-drop-table` | Do not drop tables before recreating — fails if tables exist |
| `--routines` | Include stored procedures and functions |
| `--triggers` | Include triggers (default: on) |
| `--events` | Include scheduled events |
| `--where="status='pending'"` | Dump only rows matching a WHERE clause |
| `-t tablename` | Dump a specific table (positional: db table) |
| `--all-databases` | Dump every database including `mysql` system database |

## Cleanup

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
  DROP DATABASE IF EXISTS learn_cli_restore;
"'
docker exec mini-baas-mariadb sh -lc 'rm -f /tmp/learn_cli_full.sql /tmp/learn_cli_schema.sql /tmp/learn_cli_data.sql /tmp/learn_cli.sql.gz /tmp/learn_cli_restore.sql'
rm -f ./learn_cli_full.sql ./learn_cli.sql.gz 2>/dev/null || true
```

## Gotchas / Docker notes

- **`--single-transaction` only works for InnoDB**: MyISAM tables are flushed with a lock. Since we use `ENGINE=InnoDB` everywhere, this is fine. The dump header includes a `LOCK TABLES` / `UNLOCK TABLES` around each MyISAM table if mixed.
- **Password in dump output**: the dump does NOT include user passwords unless you dump the `mysql` system database with `--all-databases`. A schema dump is safe to commit to version control (no secrets).
- **Sandbox mode header `/*M!999999\-`**: this is a MariaDB-specific conditional comment. MySQL clients interpret it as a comment (the `!999999` version number is impossibly high). If you restore a MariaDB dump into Oracle MySQL, this line is silently ignored.
- **`docker cp` direction**: `docker cp container:/path/inside ./path/host` copies out; `docker cp ./path/host container:/path/inside` copies in. Reversing them silently overwrites the wrong location.
- **Views in dumps**: `mariadb-dump` dumps views as `CREATE TABLE` temporary stubs first (to allow self-referencing views), then `DROP TABLE` + `CREATE VIEW`. The resulting SQL is safe to restore but looks confusing mid-file.

---

Previous: [06-security.md](06-security.md) | Next: [08-transactions-isolation.md](08-transactions-isolation.md)
