# Microsoft SQL Server — Docker CLI Learning Notes

SQL Server 2022 (16.0.4255.1) runs as `mini-baas-mssql` inside the `mini-baas` compose project.
All access is through `docker exec` — no host SQL Server client is installed or required.

## Quick connect

```bash
docker exec -it mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C'
```

The `-C` flag (trust server certificate) is **mandatory** for every `sqlcmd` invocation.
The tools18 build encrypts by default; without `-C` you get a TLS error and the connection
is refused. Pass it on every command shown in these notes.

One-shot query (non-interactive):

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "SELECT @@VERSION"'
```

## Contents

| File | Topic |
|------|-------|
| [00-connect.md](00-connect.md) | Connect modes, GO terminator, running .sql files, listing objects, `learn_cli` setup |
| [01-crud.md](01-crud.md) | CREATE TABLE, INSERT/OUTPUT, SELECT, UPDATE, DELETE, MERGE (UPSERT) |
| [02-views.md](02-views.md) | CREATE/ALTER VIEW, WITH SCHEMABINDING, indexed views, DROP VIEW |
| [03-indexes.md](03-indexes.md) | Clustered vs nonclustered, filtered, INCLUDE, SET STATISTICS IO ON |
| [04-logins-users.md](04-logins-users.md) | Server LOGINs vs database USERs (the two-level model) |
| [05-permissions-grants.md](05-permissions-grants.md) | GRANT/DENY/REVOKE, DENY precedence, fixed roles, read-only recipe |
| [06-security.md](06-security.md) | Schemas as boundaries, ownership chaining, CHECK_POLICY, TDE, hardening |
| [07-backup-restore.md](07-backup-restore.md) | BACKUP/RESTORE DATABASE, docker cp, bcp export/import |
| [08-transactions-isolation.md](08-transactions-isolation.md) | BEGIN/COMMIT/ROLLBACK, XACT_ABORT, isolation levels, SNAPSHOT/RCSI |

## Scratch database

All examples use `learn_cli`. Create it once:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "CREATE DATABASE learn_cli"'
```

Clean up when done:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "DROP DATABASE learn_cli"'
```

**Never run these examples against `finance`, `master`, `msdb`, `model`, or `tempdb`.**
