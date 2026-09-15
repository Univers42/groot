# 07 — Backup and Restore

CockroachDB's native `BACKUP`/`RESTORE` are SQL statements that run as cluster jobs. For flat-file exchange, `EXPORT`/`IMPORT INTO` use CSV. Both run entirely through `docker exec`.

## Setup

```bash
docker exec mini-baas-cockroach cockroach sql --insecure \
  -e "CREATE DATABASE IF NOT EXISTS learn_cli;"
```

Create and populate the shop schema from [01-crud.md](01-crud.md) before running backup commands.

## BACKUP DATABASE

`nodelocal://1/...` refers to the `extern/` directory inside the container's data path (`/cockroach/cockroach-data/extern/`). It is the simplest storage backend available without external cloud credentials.

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "
BACKUP DATABASE learn_cli INTO 'nodelocal://1/learn_cli_backup';
"
```

Output:

```
job_id              status     fraction_completed  rows  index_entries  bytes
1188076860122005505  succeeded  1                   9     10             1005
```

The backup lands in a timestamped subdirectory inside the collection path. `BACKUP INTO` (not `BACKUP TO`) is the current syntax and creates a collection that can hold incremental backups.

## Listing backups in a collection

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "
SHOW BACKUPS IN 'nodelocal://1/learn_cli_backup';
"
```

```
path
/2026/06/28-103123.95
```

## Inspecting a backup

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "
SHOW BACKUP FROM '/2026/06/28-103123.95' IN 'nodelocal://1/learn_cli_backup';
"
```

This lists every object (database, schema, table) captured and its row/byte count.

## RESTORE — pattern (unverified here)

Restore requires that the target database does not exist yet (or use `WITH new_db_name`):

```sql
-- pattern (unverified here — would drop and recreate learn_cli)
RESTORE DATABASE learn_cli
FROM '/2026/06/28-103123.95'
IN 'nodelocal://1/learn_cli_backup';
```

To restore into a differently named database:

```sql
-- pattern (unverified here)
RESTORE DATABASE learn_cli
FROM '/2026/06/28-103123.95'
IN 'nodelocal://1/learn_cli_backup'
WITH new_db_name = 'learn_cli_restored';
```

Monitor progress:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "SHOW JOBS;"
```

## Copying a backup out of the container

`nodelocal://` writes files to the container filesystem. Use `docker cp` to retrieve them:

```bash
# Copy the entire backup collection to the host
docker cp mini-baas-cockroach:/cockroach/cockroach-data/extern/learn_cli_backup \
  ./local-backups/learn_cli_backup
```

And to restore from the host back to a fresh container, copy in reverse:

```bash
docker cp ./local-backups/learn_cli_backup \
  mini-baas-cockroach:/cockroach/cockroach-data/extern/learn_cli_backup
```

## EXPORT to CSV

`EXPORT` writes query results as CSV files to `nodelocal://` storage. Useful for transferring subsets of data to other systems.

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
EXPORT INTO CSV 'nodelocal://1/learn_cli_export/customers'
FROM SELECT id, name, email, created_at FROM customers;
"
```

Output:

```
filename                                        rows  bytes
export...n1188076839792279553.0.csv             3     290
```

Note: CockroachDB prints a `NOTICE` that `EXPORT` may be deprecated in favour of changefeeds for ongoing data movement. For a one-time extract it still works cleanly.

Check the exported file:

```bash
docker exec mini-baas-cockroach \
  ls /cockroach/cockroach-data/extern/learn_cli_export/customers/
```

Copy CSV to host:

```bash
docker cp mini-baas-cockroach:/cockroach/cockroach-data/extern/learn_cli_export \
  ./learn_cli_export
```

## IMPORT INTO CSV

To load CSV data into an existing table, `IMPORT INTO` reads from `nodelocal://` storage:

```bash
# First, create the target table (must match the CSV columns)
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
CREATE TABLE IF NOT EXISTS customers_import (
  id         UUID,
  name       STRING,
  email      STRING,
  created_at TIMESTAMPTZ
);
"

# Import the CSV (skip=1 if the file has a header row)
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
IMPORT INTO customers_import (id, name, email, created_at)
CSV DATA ('nodelocal://1/learn_cli_export/customers/<filename>.csv')
WITH skip = '1';
"
```

Replace `<filename>.csv` with the actual generated name from the EXPORT step.

## Quick SQL export via redirect (no nodelocal)

For a lightweight export without `nodelocal://`, redirect `-e` output on the host:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli \
  -e "SELECT id, name, email FROM customers;" \
  > ./customers_export.tsv
```

The output is tab-separated (default `display_format = tsv`). Add `--format=csv` for CSV:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli \
  --format=csv \
  -e "SELECT id, name, email FROM customers;" \
  > ./customers_export.csv
```

This works for small tables. For large tables, use `EXPORT INTO CSV` to avoid buffering everything through the shell.

## cockroach dump — removed in v24.3.5

`cockroach dump` was a legacy subcommand that produced SQL DDL + DML output. It was already deprecated in earlier versions and is **fully removed** in v24.3.5:

```bash
docker exec mini-baas-cockroach cockroach dump learn_cli
# ERROR: unknown command "dump" for "cockroach"
```

Use `BACKUP`/`EXPORT` instead. For DDL-only documentation, use `SHOW CREATE TABLE <name>;` and capture the output.

## Scenario: nightly backup to host filesystem

```bash
#!/usr/bin/env bash
# Run on the host, triggered by a cron or make target

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
CONTAINER=mini-baas-cockroach
REMOTE_PATH=learn_cli_backup_${TIMESTAMP}
HOST_PATH=./backups/${REMOTE_PATH}

# 1. Run the backup inside the container
docker exec "${CONTAINER}" cockroach sql --insecure \
  -e "BACKUP DATABASE learn_cli INTO 'nodelocal://1/${REMOTE_PATH}';"

# 2. Copy to host
docker cp "${CONTAINER}:/cockroach/cockroach-data/extern/${REMOTE_PATH}" \
  "${HOST_PATH}"

echo "Backup saved to ${HOST_PATH}"
```

## Cleanup

```bash
docker exec mini-baas-cockroach cockroach sql --insecure \
  -e "DROP DATABASE learn_cli CASCADE;"
```

## Gotchas / Docker notes

- **`BACKUP TO` is deprecated.** Use `BACKUP INTO` (creates a versioned collection). `BACKUP TO` may be removed in a future major version.
- **`SHOW BACKUP 'path'` (without `IN`) is deprecated.** Use `SHOW BACKUPS IN 'collection'` to list, and `SHOW BACKUP FROM 'timestamp' IN 'collection'` to inspect.
- **`nodelocal://1/` maps to `/cockroach/cockroach-data/extern/` inside the container.** Files there are ephemeral if the container volume is not persisted. Mount an explicit volume in production.
- **`IMPORT INTO` locks the target table** during the import. Do not import into a table that is actively written to.
- **`EXPORT` file names are auto-generated.** The file name contains a job ID and node ID. List the directory after export to get the exact name.
- **`cockroach dump` is gone.** Do not reference it in scripts — it will fail with "unknown command".

---

← [06-security.md](06-security.md) | [08-transactions-isolation.md](08-transactions-isolation.md) →
