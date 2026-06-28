# Users and the user@host Model

MariaDB identifies a user by a **pair**: username AND hostname. `alice@localhost` and `alice@%` are two completely separate accounts with independent passwords and grants. This surprises almost everyone coming from PostgreSQL or application-level auth systems.

## Prerequisites

Run the examples as root. Replace `$MARIADB_ROOT_PASSWORD` with `$MYSQL_ROOT_PASSWORD` and `mini-baas-mariadb` with `mini-baas-mysql` for the other container.

## The user@host pair

```
'username'@'host'
```

| Host value | Meaning |
|---|---|
| `localhost` | Connects via UNIX socket (same host, socket file) |
| `127.0.0.1` | Connects via TCP to loopback |
| `%` | Wildcard: any host (TCP connections, not socket) |
| `192.168.1.%` | Any host in that subnet |
| `app.internal` | Exact hostname (resolved at connect time) |

In Docker, application containers connect over the Docker bridge network — their IP is not `localhost`. An account granted to `'user'@'localhost'` is unreachable from another container; you need `'user'@'%'` or `'user'@'<container-subnet>'`.

## CREATE USER

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
CREATE USER \"shop_app\"@\"%\" IDENTIFIED BY \"appSecretPass1!\";
"'
```

### Verify

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
SELECT user, host, plugin, password_expired
FROM   mysql.user
WHERE  user = \"shop_app\";
"'
```

```
User       Host  plugin                 password_expired
shop_app   %     mysql_native_password  N
```

The `plugin` column shows the auth plugin. In this stack, `mysql_native_password` is the default (see [06-security.md](06-security.md) for plugin details).

### IF NOT EXISTS (idempotent)

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
CREATE USER IF NOT EXISTS \"shop_app\"@\"%\" IDENTIFIED BY \"appSecretPass1!\";
"'
```

Without `IF NOT EXISTS`, running the statement twice produces `ERROR 1396: Operation CREATE USER failed for 'shop_app'@'%'`.

## ALTER USER — change password

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
ALTER USER \"shop_app\"@\"%\" IDENTIFIED BY \"newSecurePass2!\";
"'
```

The older `SET PASSWORD FOR 'shop_app'@'%' = PASSWORD('newpass')` syntax also works in MariaDB 11.4 but is deprecated. Use `ALTER USER` for clarity.

## RENAME USER

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
-- Create a user to rename
CREATE USER IF NOT EXISTS \"old_name\"@\"%\" IDENTIFIED BY \"pass\";

-- Rename preserves password and grants
RENAME USER \"old_name\"@\"%\" TO \"new_name\"@\"%\";

SELECT user, host FROM mysql.user WHERE user = \"new_name\";
"'
```

```
User      Host
new_name  %
```

## DROP USER

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
DROP USER IF EXISTS \"new_name\"@\"%\";
"'
```

`IF EXISTS` prevents an error if the user was already removed. MariaDB automatically revokes all grants when a user is dropped — no separate `REVOKE` step needed.

## MariaDB ROLES

MariaDB has had native roles since 10.0 — predating MySQL 8.0's role support. A role is a named collection of privileges that can be granted to users.

### Create a role and assign privileges to it

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
CREATE ROLE IF NOT EXISTS \"shop_reader\";
GRANT SELECT ON learn_cli.* TO \"shop_reader\";
"'
```

### Create a user, grant the role, set as default

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
CREATE USER IF NOT EXISTS \"bob_reader\"@\"%\" IDENTIFIED BY \"bobpass\";
GRANT \"shop_reader\" TO \"bob_reader\"@\"%\";
SET DEFAULT ROLE \"shop_reader\" FOR \"bob_reader\"@\"%\";
"'
```

`SET DEFAULT ROLE` ensures the role is active immediately upon login without requiring the user to run `SET ROLE`. Without it, the user must explicitly activate it each session.

### Verify role grants

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
SHOW GRANTS FOR \"bob_reader\"@\"%\";
"'
```

```
Grants for bob_reader@%
GRANT `shop_reader` TO `bob_reader`@`%`
GRANT USAGE ON *.* TO `bob_reader`@`%` IDENTIFIED BY PASSWORD '...'
SET DEFAULT ROLE `shop_reader` FOR `bob_reader`@`%`
```

### SET ROLE in a session

A user can activate a role mid-session (if not set as default):

```sql
-- Inside a session connected as bob_reader:
SET ROLE shop_reader;
SELECT CURRENT_ROLE();  -- shows: shop_reader
```

```sql
-- To deactivate:
SET ROLE NONE;
```

### Drop a role

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
DROP ROLE IF EXISTS \"shop_reader\";
"'
```

Dropping a role revokes it from all users it was granted to.

## MariaDB vs Oracle MySQL: roles

| Feature | MariaDB | Oracle MySQL 8.0+ |
|---|---|---|
| Role creation | `CREATE ROLE` | `CREATE ROLE` |
| Activate role | `SET ROLE rolename` | `SET ROLE rolename` |
| Default role | `SET DEFAULT ROLE` | `SET DEFAULT ROLE` |
| Mandatory roles | Not available | `mandatory_roles` system variable |
| Role activation at login | Via `SET DEFAULT ROLE` | `activate_all_roles_on_login=ON` |

## Scenario: setting up a service account for the shop application

The shop's Node.js backend should connect as a limited service account:

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
-- Create the service user (accessible from any container on the network)
CREATE USER IF NOT EXISTS \"shop_svc\"@\"%\" IDENTIFIED BY \"SvcPass42!\";

-- Grant only what the app needs
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

## Cleanup

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
DROP USER IF EXISTS \"shop_app\"@\"%\", \"bob_reader\"@\"%\", \"shop_svc\"@\"%\";
DROP ROLE IF EXISTS \"shop_reader\";
"'
```

## Gotchas / Docker notes

- **`localhost` is NOT `%`**: a user granted to `@localhost` connects via the UNIX socket (`/run/mysqld/mysqld.sock`). Another container connecting via TCP is not `localhost`, even if the IP is `127.0.0.1`. Always use `@'%'` for Docker inter-container access.
- **Password in the SHOW GRANTS output**: MariaDB shows `IDENTIFIED BY PASSWORD '*<hash>'` in `SHOW GRANTS` — this is the hashed password, not the plaintext. It is safe to store in a diff or log, but it does reveal the hash.
- **`USAGE` grant**: every user entry begins with `GRANT USAGE ON *.*` — this means "can log in, no actual privileges". It is not a separate grant you issue; MariaDB generates it automatically.
- **Role gotcha — not active by default without `SET DEFAULT ROLE`**: if you forget `SET DEFAULT ROLE`, the user connects with `GRANT USAGE` only and gets access-denied errors. Always verify with `SELECT CURRENT_ROLE()` after connecting as the user.
- **Oracle MySQL 8.0 difference**: MySQL 8.0 changed the default auth plugin from `mysql_native_password` to `caching_sha2_password`. If you migrate a dump from this MariaDB container to Oracle MySQL 8.0, client connections that don't support `caching_sha2_password` will fail.

---

Previous: [03-indexes.md](03-indexes.md) | Next: [05-permissions-grants.md](05-permissions-grants.md)
