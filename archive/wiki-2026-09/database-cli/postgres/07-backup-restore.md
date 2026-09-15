# Backup and Restore

After this file you can dump a whole database or a single table in plain SQL or binary format,
move dump files between the container and the host with `docker cp`, restore into a fresh
database, and pipe dumps to keep your host filesystem tidy.

## Tools in the container

Both `pg_dump` and `pg_restore` are already present in `mini-baas-postgres`. There is no need
to install anything on the host.

## Prerequisite

`learn_cli` must exist with the shop data from [01-crud.md](01-crud.md).

## pg_dump — plain SQL format (default)

Plain format produces a file you can read and pipe directly into `psql`. Good for portability
and inspection.

### Full database dump to a file inside the container

```bash
docker exec mini-baas-postgres sh -lc \
  'pg_dump -U "$POSTGRES_USER" -d learn_cli -f /tmp/learn_cli.sql'
```

### Single-table dump (schema + data)

```bash
docker exec mini-baas-postgres sh -lc \
  'pg_dump -U "$POSTGRES_USER" -d learn_cli -t customers -f /tmp/customers.sql'
```

### Schema-only dump (no data)

```bash
docker exec mini-baas-postgres sh -lc \
  'pg_dump -U "$POSTGRES_USER" -d learn_cli --schema-only -f /tmp/learn_cli_schema.sql'
```

### Data-only dump

```bash
docker exec mini-baas-postgres sh -lc \
  'pg_dump -U "$POSTGRES_USER" -d learn_cli --data-only -f /tmp/learn_cli_data.sql'
```

> Plain format data dumps use `COPY` statements, not `INSERT`. This is faster to restore but
> less human-readable. Add `--inserts` to get INSERT statements instead.

## pg_dump — custom format (-Fc)

Custom format is compressed and supports parallel restore. Prefer it for large databases.

```bash
docker exec mini-baas-postgres sh -lc \
  'pg_dump -U "$POSTGRES_USER" -d learn_cli -Fc -f /tmp/learn_cli.dump'
```

```bash
# Verify the dump was written
docker exec mini-baas-postgres sh -lc 'ls -lh /tmp/learn_cli.dump'
```

## docker cp — moving dump files

### Extract a dump from the container to the host

```bash
docker cp mini-baas-postgres:/tmp/learn_cli.dump ./learn_cli.dump
```

### Push a dump file into the container from the host

```bash
docker cp ./learn_cli.dump mini-baas-postgres:/tmp/learn_cli.dump
```

### Full host-side backup workflow

```bash
# Dump directly to host (no temp file inside container)
docker exec mini-baas-postgres sh -lc \
  'pg_dump -U "$POSTGRES_USER" -d learn_cli -Fc' > ./learn_cli.dump

echo "Dump size: $(du -h ./learn_cli.dump | cut -f1)"
```

Pipe stdout directly — nothing is written inside the container.

## pg_restore — restore custom-format dump

Create a target database first:

```bash
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE DATABASE learn_restore;"'
```

Restore from a file already inside the container:

```bash
docker exec mini-baas-postgres sh -lc \
  'pg_restore -U "$POSTGRES_USER" -d learn_restore /tmp/learn_cli.dump'
```

Verify the restore:

```bash
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d learn_restore -c "SELECT COUNT(*) FROM customers;"'
```

```
 count
-------
     3
(1 row)
```

### Restore from the host via pipe

```bash
cat ./learn_cli.dump | docker exec -i mini-baas-postgres sh -lc \
  'pg_restore -U "$POSTGRES_USER" -d learn_restore'
```

`-i` keeps stdin open so `docker exec` can receive the pipe.

## Restoring plain SQL dumps

Plain SQL dumps are restored with `psql`, not `pg_restore`:

```bash
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d learn_restore -f /tmp/learn_cli.sql'
```

Or from host via pipe:

```bash
cat ./learn_cli.sql | docker exec -i mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d learn_restore'
```

## Dumping a single schema

```bash
docker exec mini-baas-postgres sh -lc \
  'pg_dump -U "$POSTGRES_USER" -d learn_cli -n public -Fc -f /tmp/public_schema.dump'
```

`-n public` restricts the dump to the `public` schema only.

## pg_restore options reference

| Flag | Meaning |
|------|---------|
| `-U user` | Connect as this role |
| `-d dbname` | Target database |
| `-Fc` | Input is custom format (matches pg_dump's `-Fc`) |
| `--schema-only` | Restore DDL only (no data) |
| `--data-only` | Restore data only (no DDL) |
| `-t tablename` | Restore a single table |
| `-j N` | Parallel restore with N workers (custom format only) |
| `--no-owner` | Skip OWNER clauses (useful when restoring to a different user) |

```bash
# Restore only the customers table from the full dump
docker exec mini-baas-postgres sh -lc \
  'pg_restore -U "$POSTGRES_USER" -d learn_restore -t customers /tmp/learn_cli.dump'
```

## Scenario: daily backup and restore drill

```bash
# 1. Dump learn_cli to host
docker exec mini-baas-postgres sh -lc \
  'pg_dump -U "$POSTGRES_USER" -d learn_cli -Fc' > ./learn_cli_$(date +%Y%m%d).dump

# 2. Drop and recreate a restore target
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DROP DATABASE IF EXISTS learn_restore; CREATE DATABASE learn_restore;"'

# 3. Push the dump back into the container
docker cp ./learn_cli_$(date +%Y%m%d).dump mini-baas-postgres:/tmp/restore_input.dump

# 4. Restore
docker exec mini-baas-postgres sh -lc \
  'pg_restore -U "$POSTGRES_USER" -d learn_restore /tmp/restore_input.dump'

# 5. Smoke-test
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d learn_restore -c "
SELECT '"'"'customers'"'"' AS tbl, COUNT(*) FROM customers
UNION ALL
SELECT '"'"'products'"'"', COUNT(*) FROM products
UNION ALL
SELECT '"'"'orders'"'"', COUNT(*) FROM orders;"'
```

## Cleanup after the backup drill

```bash
# Remove restore target
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DROP DATABASE IF EXISTS learn_restore;"'

# Remove temp dump files inside container
docker exec mini-baas-postgres sh -lc 'rm -f /tmp/learn_cli.dump /tmp/learn_cli.sql /tmp/restore_input.dump'
```

## Gotchas / Docker notes

- **`pg_dump` output includes a `\restrict` header** on this grobase-patched image. This is
  a grobase-specific dump guard; `pg_restore` handles it transparently. Do not modify or
  strip it manually when restoring.
- **`pg_restore` only reads custom or directory format**; use `psql -f` for plain SQL dumps.
- **Trust auth means no password in the command** for connections from inside the container.
  In CI or remote contexts, pass credentials via `PGPASSWORD` or `.pgpass` — never on the
  command line where they appear in `ps` output.
- **Never dump the live production databases** (`postgres`, `agency`, `commerce`, etc.) with
  these commands unless you specifically intend to. Target `learn_cli` only during learning.
- **`GENERATED ALWAYS AS IDENTITY` sequences**: a restored database sets sequences to their
  starting value. If you restore data with existing IDs, call
  `SELECT setval('seq_name', (SELECT MAX(id) FROM table));` afterwards, or use
  `GENERATED BY DEFAULT AS IDENTITY` so pg_dump includes the correct `setval` call.
- **Plain dumps vs custom dumps**: plain dumps can be split and searched with text tools;
  custom dumps are smaller and support selective table restore and parallel workers.

---

Previous: [06-security-rls.md](06-security-rls.md) | Next: [08-transactions-isolation.md](08-transactions-isolation.md)
