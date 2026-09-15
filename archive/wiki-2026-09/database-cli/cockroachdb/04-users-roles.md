# 04 — Users and Roles

In CockroachDB, `CREATE USER` and `CREATE ROLE` are synonyms — both create a principal. The distinction is conventional: users log in, roles group privileges. Roles are then granted to users.

## Listing existing principals

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "SHOW USERS;"
```

```
username      options  member_of
admin                  {}
root                   {admin}
```

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "SHOW ROLES;"
```

```
username      options  member_of
admin                  {}
root                   {admin}
```

`admin` is the built-in superuser role. `root` is the built-in superuser account and is a member of `admin`.

## CREATE USER

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "
CREATE USER IF NOT EXISTS shop_user;
"
```

**Passwords are not supported in insecure mode.** The `WITH PASSWORD` clause returns an error:

```
ERROR: setting or updating a password is not supported in insecure mode
```

In secure mode (see [06-security.md](06-security.md)), you would write:

```sql
-- pattern (unverified here — insecure mode only)
CREATE USER shop_user WITH PASSWORD 'strong-password-here';
```

## CREATE ROLE

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "
CREATE ROLE IF NOT EXISTS shop_readonly;
"
```

A role created this way gets `NOLOGIN` by default — it cannot authenticate directly, only be granted to users.

## GRANT a role to a user

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "
GRANT shop_readonly TO shop_user;
"
```

Verify:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "SHOW USERS;"
```

```
username      options   member_of
admin                   {}
root                    {admin}
shop_readonly  NOLOGIN  {}
shop_user                {shop_readonly}
```

`shop_user` now inherits all privileges granted to `shop_readonly`.

## ALTER USER / ALTER ROLE

Add the `CREATEDB` option so `shop_user` can create databases:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "
ALTER USER shop_user CREATEDB;
"
```

Other common options: `CREATEROLE`, `CONTROLJOB`, `VIEWACTIVITY`, `NOPASSWORD`.

Remove an option:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "
ALTER USER shop_user NOCREATEDB;
"
```

## REVOKE role membership

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "
REVOKE shop_readonly FROM shop_user;
"
```

## DROP USER / DROP ROLE

You must revoke all grants and default privileges before dropping a role, otherwise CockroachDB returns an error listing the dependent objects.

```bash
# 1. Revoke all table-level grants in the target schema
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM shop_readonly;
REVOKE ALL ON SCHEMA public FROM shop_readonly;
REVOKE ALL ON DATABASE learn_cli FROM shop_readonly;
"

# 2. Revoke any default privilege rules that reference this role
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
ALTER DEFAULT PRIVILEGES FOR ROLE root REVOKE ALL ON TABLES FROM shop_readonly;
"

# 3. Now drop safely
docker exec mini-baas-cockroach cockroach sql --insecure -e "
DROP USER IF EXISTS shop_user;
DROP ROLE IF EXISTS shop_readonly;
"
```

Verify they are gone:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "SHOW USERS;"
```

```
username  options  member_of
admin              {}
root               {admin}
```

## Scenario: setting up a service account

A backend service needs read access to the shop data and write access to orders only.

```bash
# 1. Create roles (no login, principle of least privilege)
docker exec mini-baas-cockroach cockroach sql --insecure -e "
CREATE ROLE IF NOT EXISTS shop_reader;
CREATE ROLE IF NOT EXISTS order_writer;
"

# 2. Create the service account
docker exec mini-baas-cockroach cockroach sql --insecure -e "
CREATE USER IF NOT EXISTS shop_api_svc;
GRANT shop_reader  TO shop_api_svc;
GRANT order_writer TO shop_api_svc;
"

# 3. Grant actual privileges to the roles (see 05-permissions-grants.md)
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
GRANT CONNECT ON DATABASE learn_cli TO shop_reader, order_writer;
GRANT USAGE   ON SCHEMA  learn_cli.public TO shop_reader, order_writer;
GRANT SELECT  ON ALL TABLES IN SCHEMA learn_cli.public TO shop_reader;
GRANT INSERT, UPDATE ON TABLE learn_cli.public.orders TO order_writer;
"

# 4. Verify
docker exec mini-baas-cockroach cockroach sql --insecure -e "SHOW USERS;"
```

## Cleanup

```bash
# Revoke grants first (see full pattern above), then:
docker exec mini-baas-cockroach cockroach sql --insecure -e "
DROP USER IF EXISTS shop_user;
DROP USER IF EXISTS shop_api_svc;
DROP ROLE IF EXISTS shop_readonly;
DROP ROLE IF EXISTS shop_reader;
DROP ROLE IF EXISTS order_writer;
"
```

## Gotchas / Docker notes

- **`CREATE USER` and `CREATE ROLE` are aliases.** Both create the same kind of principal. By convention: `USER` for accounts that log in, `ROLE` for permission groups.
- **Passwords fail in insecure mode.** The `WITH PASSWORD` clause raises `ERROR: setting or updating a password is not supported in insecure mode`. Design scripts for secure mode by keeping passwords in env vars, not hardcoded.
- **Drop order matters.** You must revoke privileges (including default privileges) before dropping a role; otherwise the drop fails with a detailed error listing every dependent object.
- **`admin` is the superuser role.** Granting `admin` to a user gives them full cluster access — treat it like root on Linux.
- **`NOLOGIN` roles cannot connect.** They exist only to hold privilege sets; you grant them to users.

---

← [03-indexes.md](03-indexes.md) | [05-permissions-grants.md](05-permissions-grants.md) →
