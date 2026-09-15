# Permissions and Grants

GRANT and REVOKE control what a user (or role) can do in MariaDB. Privileges cascade from global (`*.*`) down to database (`db.*`), table (`db.table`), and column scope. The most specific matching grant wins.

## Prerequisites

This file assumes `learn_cli` schema exists (from [01-crud.md](01-crud.md)) and users from [04-users.md](04-users.md) may already exist. All commands run as root.

## GRANT syntax

```sql
GRANT <privileges> ON <scope> TO 'user'@'host' [WITH GRANT OPTION];
```

Where scope is:
- `*.*` — all databases, all tables (global)
- `learn_cli.*` — all tables in learn_cli (database-level)
- `learn_cli.orders` — specific table
- `learn_cli.orders` with column list — column-level

## Global grant (admin use only)

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
-- Full admin — DANGEROUS: equivalent to root
GRANT ALL PRIVILEGES ON *.* TO \"admin_user\"@\"%\" IDENTIFIED BY \"adminpass\" WITH GRANT OPTION;
"'
```

Never use `ALL PRIVILEGES ON *.*` for application accounts. Reserve it for DBA access.

## Database-level grant

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
CREATE USER IF NOT EXISTS \"shop_manager\"@\"%\" IDENTIFIED BY \"managerpass\";
GRANT SELECT, INSERT, UPDATE ON learn_cli.* TO \"shop_manager\"@\"%\";
SHOW GRANTS FOR \"shop_manager\"@\"%\";
"'
```

```
Grants for shop_manager@%
GRANT USAGE ON *.* TO `shop_manager`@`%` IDENTIFIED BY PASSWORD '...'
GRANT SELECT, INSERT, UPDATE ON `learn_cli`.* TO `shop_manager`@`%`
```

## Table-level grant

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
CREATE USER IF NOT EXISTS \"shop_svc\"@\"%\" IDENTIFIED BY \"svcpass\";
GRANT SELECT, INSERT, UPDATE ON learn_cli.orders    TO \"shop_svc\"@\"%\";
GRANT SELECT                  ON learn_cli.customers TO \"shop_svc\"@\"%\";
GRANT SELECT                  ON learn_cli.products  TO \"shop_svc\"@\"%\";
SHOW GRANTS FOR \"shop_svc\"@\"%\";
"'
```

```
Grants for shop_svc@%
GRANT USAGE ON *.* TO `shop_svc`@`%` IDENTIFIED BY PASSWORD '...'
GRANT SELECT ON `learn_cli`.`customers` TO `shop_svc`@`%`
GRANT SELECT ON `learn_cli`.`products` TO `shop_svc`@`%`
GRANT SELECT, INSERT, UPDATE ON `learn_cli`.`orders` TO `shop_svc`@`%`
```

## Column-level grant

Restrict access to specific columns within a table:

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
CREATE USER IF NOT EXISTS \"reporter\"@\"%\" IDENTIFIED BY \"reportpass\";
-- Allow seeing customer name but NOT email
GRANT SELECT (id, name, created_at) ON learn_cli.customers TO \"reporter\"@\"%\";
SHOW GRANTS FOR \"reporter\"@\"%\";
"'
```

```
Grants for reporter@%
GRANT USAGE ON *.* TO `reporter`@`%` IDENTIFIED BY PASSWORD '...'
GRANT SELECT (id, name, created_at) ON `learn_cli`.`customers` TO `reporter`@`%`
```

A `SELECT *` by `reporter` will fail; only the granted columns work.

## GRANT ... WITH GRANT OPTION

Allows the grantee to re-grant their own privileges to other users:

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
GRANT SELECT, INSERT, UPDATE ON learn_cli.* TO \"shop_manager\"@\"%\" WITH GRANT OPTION;
SHOW GRANTS FOR \"shop_manager\"@\"%\";
"'
```

```
GRANT SELECT, INSERT, UPDATE ON `learn_cli`.* TO `shop_manager`@`%` WITH GRANT OPTION
```

Use `WITH GRANT OPTION` sparingly. A user with grant option can grant their own privileges to anyone — including a backdoor account.

## REVOKE

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
-- Revoke INSERT privilege only
REVOKE INSERT ON learn_cli.* FROM \"shop_manager\"@\"%\";
SHOW GRANTS FOR \"shop_manager\"@\"%\";
"'
```

```
GRANT SELECT, UPDATE ON `learn_cli`.* TO `shop_manager`@`%` WITH GRANT OPTION
```

To revoke the grant option itself:

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
REVOKE GRANT OPTION ON learn_cli.* FROM \"shop_manager\"@\"%\";
"'
```

## SHOW GRANTS FOR

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
SHOW GRANTS FOR \"shop_svc\"@\"%\";
"'
```

To see your own grants (inside a session):

```sql
SHOW GRANTS;
-- or
SHOW GRANTS FOR CURRENT_USER();
```

## FLUSH PRIVILEGES

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;"'
```

`FLUSH PRIVILEGES` re-reads the grant tables from disk into memory. It is **not required** after `GRANT`/`REVOKE`/`CREATE USER` statements — these commands update the in-memory grant cache automatically. You only need it if you manually edit the `mysql.user` table with `INSERT`/`UPDATE` directly (which you should not do).

## Scenario: shop_readonly — a read-only analyst account

A classic setup: a user who can only SELECT from the shop database, accessible from any host.

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
-- Step 1: create the user
CREATE USER IF NOT EXISTS \"shop_readonly\"@\"%\" IDENTIFIED BY \"readOnlyPass1!\";

-- Step 2: grant SELECT only, on all tables in learn_cli
GRANT SELECT ON learn_cli.* TO \"shop_readonly\"@\"%\";

-- Step 3: verify
SHOW GRANTS FOR \"shop_readonly\"@\"%\";
"'
```

```
Grants for shop_readonly@%
GRANT USAGE ON *.* TO `shop_readonly`@`%` IDENTIFIED BY PASSWORD '...'
GRANT SELECT ON `learn_cli`.* TO `shop_readonly`@`%`
```

Test it works — connect as the readonly user and try a write:

```bash
# Read succeeds
docker exec mini-baas-mariadb sh -lc \
  'mariadb -ushop_readonly -p"readOnlyPass1!" learn_cli -e "SELECT name FROM customers;"' 2>&1

# Write fails
docker exec mini-baas-mariadb sh -lc \
  'mariadb -ushop_readonly -p"readOnlyPass1!" learn_cli -e "DELETE FROM customers WHERE id=1;"' 2>&1
```

```
name
Alice Dupont
Bob Martin
Carol Lee

ERROR 1142 (42000): DELETE command denied to user 'shop_readonly'@'localhost' for table `learn_cli`.`customers`
```

## Privilege reference

| Privilege | Scope | Meaning |
|---|---|---|
| `SELECT` | table/column | Read rows |
| `INSERT` | table/column | Write new rows |
| `UPDATE` | table/column | Modify existing rows |
| `DELETE` | table | Remove rows |
| `CREATE` | db/table | Create databases/tables |
| `DROP` | db/table | Drop databases/tables |
| `ALTER` | table | Modify table structure |
| `INDEX` | table | Create/drop indexes |
| `CREATE VIEW` | db | Create views |
| `SHOW VIEW` | db | See view definitions |
| `TRIGGER` | table | Create triggers |
| `EXECUTE` | routine | Call stored procedures |
| `GRANT OPTION` | any | Re-grant own privileges |
| `ALL PRIVILEGES` | any | Every privilege (except GRANT OPTION) |

## Cleanup

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
DROP USER IF EXISTS \"shop_manager\"@\"%\";
DROP USER IF EXISTS \"shop_svc\"@\"%\";
DROP USER IF EXISTS \"reporter\"@\"%\";
DROP USER IF EXISTS \"shop_readonly\"@\"%\";
DROP USER IF EXISTS \"admin_user\"@\"%\";
"'
```

## Gotchas / Docker notes

- **Privilege specificity vs. additive grants**: MariaDB applies all matching grants additively. If a user has `SELECT ON *.*` (global) and `INSERT ON learn_cli.*` (database), they can INSERT into learn_cli. There is no "deny" mechanism — only absence of a grant.
- **Column grants slow `SELECT *`**: granting column-level privileges forces MariaDB to evaluate column ACLs on every query against that table for that user, even for other users. In very high-throughput systems, prefer table-level grants and rely on view-based column restriction instead.
- **`SHOW GRANTS` requires the `SELECT` privilege on `mysql.*`** when querying for another user. As root, this is always available.
- **Grants persist across restarts**: grants are stored in the `mysql` system database (persistent volume in this Docker setup). They survive container restarts.
- **Oracle MySQL 8.0 difference**: MySQL 8.0 deprecated the `IDENTIFIED BY` clause inside `GRANT`. In MySQL 8.0+ you must `CREATE USER` first, then `GRANT`. MariaDB still allows the combined form in 11.4.

---

Previous: [04-users.md](04-users.md) | Next: [06-security.md](06-security.md)
