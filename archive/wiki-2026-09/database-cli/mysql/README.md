# MariaDB / MySQL CLI — Docker Notes

Both database engines in this stack are **MariaDB 11.4.12** (a MySQL fork), reached exclusively via `docker exec` — no host DB clients are installed. All commands here are verified against the live `mini-baas-mariadb` container.

## Quick connect

```bash
# Interactive session
docker exec -it mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'

# One-shot query
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "SELECT VERSION();"'
```

Output: `11.4.12-MariaDB`

## Containers at a glance

| Container | Client binary | Root password env |
|---|---|---|
| `mini-baas-mariadb` | `mariadb` (preferred), `mysql` (compat symlink), `mysqldump`, `mariadb-dump` | `MARIADB_ROOT_PASSWORD` |
| `mini-baas-mysql` | `mysql` (prints deprecation warning), `mysqldump` | `MYSQL_ROOT_PASSWORD` |

All examples target `mini-baas-mariadb`. To run the same command in `mini-baas-mysql`, swap the container name and env var.

## MariaDB vs Oracle MySQL — key differences

| Topic | MariaDB | Oracle MySQL |
|---|---|---|
| Client binary name | `mariadb` (preferred); `mysql` prints deprecation warning | `mysql` |
| Dump binary | `mariadb-dump` (preferred); `mysqldump` prints deprecation warning | `mysqldump` |
| Roles | Built-in since 10.0 | Added in 8.0 |
| Auth plugin default | `mysql_native_password` | `caching_sha2_password` (8.0+) |
| `JSON` type | Alias for `LONGTEXT` with validation | Native binary type |
| `SHOW CREATE VIEW` algorithm | Shows `ALGORITHM=UNDEFINED` by default | Same |
| Materialized views | Not supported (workaround: table + EVENT) | Not supported |
| `tx_isolation` variable | `@@tx_isolation` | `@@transaction_isolation` (8.0+) |

## Concept files — read in order

1. [00-connect.md](00-connect.md) — interactive vs one-shot, running `.sql` files, meta-commands, output modes
2. [01-crud.md](01-crud.md) — CREATE TABLE, INSERT, SELECT, UPDATE, DELETE, UPSERT
3. [02-views.md](02-views.md) — CREATE VIEW, WITH CHECK OPTION, updatable views, no materialized views
4. [03-indexes.md](03-indexes.md) — B-Tree, UNIQUE, composite, prefix, FULLTEXT, EXPLAIN
5. [04-users.md](04-users.md) — user@host model, CREATE/ALTER/RENAME/DROP USER, MariaDB roles
6. [05-permissions-grants.md](05-permissions-grants.md) — GRANT/REVOKE scope, SHOW GRANTS, read-only recipe
7. [06-security.md](06-security.md) — least privilege, auth plugins, TLS, hardening checklist
8. [07-backup-restore.md](07-backup-restore.md) — mariadb-dump/mysqldump, docker cp, restore pipeline
9. [08-transactions-isolation.md](08-transactions-isolation.md) — START TRANSACTION, SAVEPOINT, isolation levels, locking

## Scratch database

All examples use `learn_cli`. It is safe to recreate:

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS learn_cli;"'
```
