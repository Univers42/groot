# CockroachDB CLI — Docker Notes

CockroachDB is a distributed, PostgreSQL-wire-compatible SQL database that runs as `mini-baas-cockroach` in the grobase backend stack. All access goes through `docker exec` using the bundled `cockroach` binary — no host client needed.

## Quick connect

```bash
# Interactive shell
docker exec -it mini-baas-cockroach cockroach sql --insecure

# One-shot query
docker exec mini-baas-cockroach cockroach sql --insecure -e "SELECT version();"
```

**Version confirmed:** CockroachDB CCL v24.3.5 (insecure mode, single-node dev cluster)

## What makes CockroachDB different from single-node SQL

| Property | CockroachDB | Typical single-node DB |
|---|---|---|
| Default isolation | **SERIALIZABLE** | READ COMMITTED (Postgres default) |
| Primary key strategy | **UUID / gen_random_uuid()** preferred | SERIAL / AUTOINCREMENT common |
| Schema changes | Online, non-blocking | Often table-lock |
| Retry logic | Client must handle `40001` | Usually not needed |
| Horizontal scale | Built-in (ranges + replicas) | Add-on or impossible |

## File index

| File | Topic |
|---|---|
| [00-connect.md](00-connect.md) | Connecting, shell commands, listing databases/tables |
| [01-crud.md](01-crud.md) | CREATE TABLE, INSERT, SELECT, UPDATE, DELETE, UPSERT |
| [02-views.md](02-views.md) | Regular views, materialized views, REFRESH |
| [03-indexes.md](03-indexes.md) | Secondary, covering (STORING), inverted, hash-sharded, EXPLAIN |
| [04-users-roles.md](04-users-roles.md) | CREATE USER/ROLE, membership, ALTER, DROP |
| [05-permissions-grants.md](05-permissions-grants.md) | GRANT, REVOKE, default privileges, read-only role recipe |
| [06-security.md](06-security.md) | Insecure vs secure mode, RBAC, network/auth notes |
| [07-backup-restore.md](07-backup-restore.md) | BACKUP/RESTORE, EXPORT/IMPORT INTO CSV, SQL export |
| [08-transactions-isolation.md](08-transactions-isolation.md) | BEGIN/COMMIT, SAVEPOINT, SERIALIZABLE, client retry loop |

## Sibling engine notes

- [../](../) — database-cli index (other engines in this stack)
