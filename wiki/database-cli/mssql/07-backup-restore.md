# 07 — Backup and Restore

SQL Server native backups use `.bak` files. `bcp` bulk-exports individual tables to flat
files. Both work entirely through `docker exec` with no host database client required.

## Prepare the backup directory in-container

```bash
docker exec mini-baas-mssql bash -c 'mkdir -p /var/opt/mssql/backup'
```

SQL Server's process user (`mssql`) must be able to write to the target path.
`/var/opt/mssql/` is the data directory mounted inside the container and is always writable.

## BACKUP DATABASE

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
BACKUP DATABASE learn_cli
  TO DISK = '"'"'/var/opt/mssql/backup/learn_cli.bak'"'"'
  WITH FORMAT,
       INIT,
       NAME = '"'"'learn_cli full backup'"'"'"'
```

| Option | Meaning |
|--------|---------|
| `FORMAT` | Initialise the media set (overwrites any existing media header) |
| `INIT` | Overwrite any existing backup sets on the file |
| `NAME` | Friendly label stored in the backup header |

Expected output:

```
Processed 456 pages for database 'learn_cli', file 'learn_cli' on file 1.
Processed 2 pages for database 'learn_cli', file 'learn_cli_log' on file 1.
BACKUP DATABASE successfully processed 458 pages in 0.048 seconds (74.462 MB/sec).
```

## Copy the .bak file to the host

```bash
docker cp mini-baas-mssql:/var/opt/mssql/backup/learn_cli.bak /tmp/learn_cli.bak
ls -lh /tmp/learn_cli.bak
```

Copy it back in (e.g., on a different machine):

```bash
docker cp /tmp/learn_cli.bak mini-baas-mssql:/var/opt/mssql/backup/learn_cli.bak
```

## Inspect a backup before restoring — RESTORE FILELISTONLY

Always check what logical files are inside a `.bak` before restoring:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
RESTORE FILELISTONLY
  FROM DISK = '"'"'/var/opt/mssql/backup/learn_cli.bak'"'"'"'
```

The output shows the `LogicalName` and `PhysicalName` columns, which you need for the
`MOVE` clauses in `RESTORE DATABASE`.

Expected (abbreviated):

```
LogicalName    PhysicalName                              Type
-------------- ----------------------------------------- ----
learn_cli      /var/opt/mssql/data/learn_cli.mdf         D
learn_cli_log  /var/opt/mssql/data/learn_cli_log.ldf     L
```

## RESTORE DATABASE

Restore to a **new name** (`learn_cli_restore`) to avoid conflicting with the live database.
Use `MOVE` to redirect the physical files to new paths:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
RESTORE DATABASE learn_cli_restore
  FROM DISK = '"'"'/var/opt/mssql/backup/learn_cli.bak'"'"'
  WITH MOVE '"'"'learn_cli'"'"'     TO '"'"'/var/opt/mssql/data/learn_cli_restore.mdf'"'"',
       MOVE '"'"'learn_cli_log'"'"' TO '"'"'/var/opt/mssql/data/learn_cli_restore_log.ldf'"'"',
       REPLACE,
       RECOVERY"'
```

| Option | Meaning |
|--------|---------|
| `MOVE 'logical' TO 'physical'` | Redirect files to new paths (required when original paths are in use) |
| `REPLACE` | Overwrite an existing database with this name |
| `RECOVERY` | Bring the database online after restore (default — use `NORECOVERY` for log-chain restores) |

Clean up the restore test:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
DROP DATABASE learn_cli_restore"'
```

## bcp — bulk copy table data

`bcp` exports and imports individual tables or query results to flat files.
It is built into the container alongside `sqlcmd`.

**Important:** `bcp` also uses the ODBC Driver 18 and requires the `-u` flag to trust the
server certificate (not `-C` — that flag means "code page" in bcp):

### Export a table

```bash
docker exec mini-baas-mssql sh -lc \
  'bcp learn_cli.dbo.products out /var/opt/mssql/backup/products.bcp \
   -S localhost -U sa -P "$MSSQL_SA_PASSWORD" \
   -n \
   -u'
```

| Flag | Meaning |
|------|---------|
| `out` | Export direction (table → file) |
| `-n` | Native SQL Server binary format (preserves types precisely) |
| `-c` | Character (text) format — tab-separated, human-readable but lossy for some types |
| `-u` | Trust server certificate (required with ODBC Driver 18) |

Expected:

```
2 rows copied.
```

### Export a query result

```bash
docker exec mini-baas-mssql sh -lc \
  'bcp "SELECT id, name, price_cents FROM learn_cli.dbo.products WHERE stock > 0" queryout \
   /var/opt/mssql/backup/products_instock.bcp \
   -S localhost -U sa -P "$MSSQL_SA_PASSWORD" \
   -n -u'
```

### Import a table

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
CREATE TABLE products_import (id INT, name NVARCHAR(200), price_cents INT, stock INT)"'

docker exec mini-baas-mssql sh -lc \
  'bcp learn_cli.dbo.products_import in /var/opt/mssql/backup/products.bcp \
   -S localhost -U sa -P "$MSSQL_SA_PASSWORD" \
   -n -u'
```

### Copy a bcp file to the host

```bash
docker cp mini-baas-mssql:/var/opt/mssql/backup/products.bcp /tmp/products.bcp
```

## Restore from a SQL script

For schema-only or data-only restores, copy a `.sql` file in and run it:

```bash
# Export schema (pattern — unverified here; requires SSMS or scripting tools)
# Import from a script file:
docker cp /tmp/schema.sql mini-baas-mssql:/tmp/schema.sql
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli \
   -i /tmp/schema.sql'
```

## Scenario — backup before a risky migration

Before dropping a column or altering a table, back up the database and verify the file exists:

```bash
# Backup
docker exec mini-baas-mssql bash -c 'mkdir -p /var/opt/mssql/backup'
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
BACKUP DATABASE learn_cli
  TO DISK = '"'"'/var/opt/mssql/backup/learn_cli_premigration.bak'"'"'
  WITH FORMAT, INIT, NAME = '"'"'pre-migration backup'"'"'"'

# Confirm the file
docker exec mini-baas-mssql bash -c 'ls -lh /var/opt/mssql/backup/'

# Copy to host
docker cp mini-baas-mssql:/var/opt/mssql/backup/learn_cli_premigration.bak \
  /tmp/learn_cli_premigration.bak
```

## Cleanup

Remove the backup files inside the container:

```bash
docker exec mini-baas-mssql bash -c 'rm /var/opt/mssql/backup/*.bak /var/opt/mssql/backup/*.bcp 2>/dev/null; true'
```

Drop the scratch import table:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
DROP TABLE IF EXISTS products_import"'
```

## Gotchas / Docker notes

- `bcp` uses `-u` for "trust server certificate", not `-C`. In `bcp`, `-C` means "code page"
  — a completely different option. Without `-u`, bcp fails with the same TLS error as sqlcmd
  without `-C`.
- `RESTORE DATABASE` fails if the target database already exists and is online unless you
  use `WITH REPLACE`. Use `WITH REPLACE` only when you intentionally want to overwrite.
- In a container without persistent volumes, `.bak` files inside the container are lost when
  the container is removed. Always `docker cp` important backups to the host.
- Differential and log backups (`WITH DIFFERENTIAL` / `BACKUP LOG`) build on a full backup
  baseline. Always start the chain with a `WITH FORMAT, INIT` full backup.
- The `NORECOVERY` option leaves the database in "restoring" state for subsequent log
  backups in a log-chain restore scenario. Do not use it when restoring a standalone backup.

---

Previous: [06-security.md](06-security.md) | Next: [08-transactions-isolation.md](08-transactions-isolation.md)
