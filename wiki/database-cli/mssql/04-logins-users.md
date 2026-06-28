# 04 — Logins and Users (the two-level model)

SQL Server separates identity into two distinct layers that newcomers constantly conflate.
Understanding this split is the most important concept in SQL Server security.

## The two levels

| Layer | Object | Scope | Lives in |
|-------|--------|-------|----------|
| Authentication | **LOGIN** | Server (instance) | `master` database — `sys.server_principals` |
| Authorization | **USER** | Database | Each database — `sys.database_principals` |

A **LOGIN** says: "this identity is allowed to connect to the server."
A **USER** says: "this mapped identity is allowed to act inside *this* database."

A login without a user in a database cannot touch that database's objects.
A user without a login (contained users aside) cannot connect to the server at all.

The mapping: a USER in a database points to a LOGIN via `FOR LOGIN login_name`.

## CREATE LOGIN

Logins live at the instance level. They authenticate at connection time.

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
CREATE LOGIN shop_reader
WITH PASSWORD   = '"'"'R3aderP@ss!2026'"'"',
     CHECK_POLICY = ON,
     CHECK_EXPIRATION = OFF"'
```

`CHECK_POLICY = ON` enforces the OS password-complexity policy (minimum length, character
classes). On Linux containers this is the built-in SQL Server policy, not Windows group policy.
`CHECK_EXPIRATION` controls whether the password expires on a schedule.

List all SQL logins:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
SELECT name, type_desc, is_policy_checked, is_expiration_checked, is_disabled
FROM   sys.sql_logins
ORDER  BY name"'
```

## CREATE USER

Users live inside a specific database. Always run `USE db_name` or pass `-d db_name` first.

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
CREATE USER shop_reader FOR LOGIN shop_reader"'
```

List users in the current database:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SELECT name, type_desc, default_schema_name, create_date
FROM   sys.database_principals
WHERE  type IN ('"'"'S'"'"', '"'"'U'"'"', '"'"'G'"'"')  -- SQL, Windows, Group
  AND  name NOT IN ('"'"'dbo'"'"', '"'"'guest'"'"', '"'"'INFORMATION_SCHEMA'"'"', '"'"'sys'"'"')
ORDER  BY name"'
```

## ALTER LOGIN / ALTER USER

Change a login's password:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
ALTER LOGIN shop_reader WITH PASSWORD = '"'"'N3wP@ss!2026'"'"'"'
```

Disable / re-enable a login:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
ALTER LOGIN shop_reader DISABLE"'

docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
ALTER LOGIN shop_reader ENABLE"'
```

Change a user's default schema:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
ALTER USER shop_reader WITH DEFAULT_SCHEMA = dbo"'
```

## Contained-database users

A **contained-database user** is defined at the database level with its own password,
with no server-level login. The database itself authenticates the user.

To use them, enable partial containment on the database first:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
ALTER DATABASE learn_cli SET CONTAINMENT = PARTIAL"'

docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
CREATE USER contained_user
WITH PASSWORD = '"'"'C0ntained!2026'"'"'"'
```

Contained users simplify database portability (moving the database to another server does
not require re-creating logins). The trade-off: access is scoped to that database only.

## DROP USER / DROP LOGIN

Users must be dropped before their associated login can be dropped:

```bash
# 1. Drop the user from each database that has one
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
DROP USER IF EXISTS shop_reader"'

# 2. Then drop the server-level login
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
DROP LOGIN shop_reader"'
```

## Scenario — mapping a login to learn_cli

A read-only shop application needs its own login, mapped to `learn_cli`:

```bash
# Step 1: create the server login (run once per instance)
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '"'"'shop_reader'"'"')
  CREATE LOGIN shop_reader
  WITH PASSWORD = '"'"'R3aderP@ss!2026'"'"', CHECK_POLICY = ON"'

# Step 2: create the database user mapped to that login
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '"'"'shop_reader'"'"')
  CREATE USER shop_reader FOR LOGIN shop_reader"'

# Step 3: confirm the mapping
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SELECT dp.name AS db_user, dp.type_desc, sl.name AS login
FROM   sys.database_principals dp
LEFT   JOIN sys.server_principals sl ON sl.sid = dp.sid
WHERE  dp.name = '"'"'shop_reader'"'"'"'
```

## Gotchas / Docker notes

- `DROP LOGIN` fails if the login owns any securables or is still mapped as a user in any
  database. Drop all users first, then the login.
- `sa` is a special built-in login that is always `dbo` in every database. Avoid using it
  for application connections — create a least-privilege login instead.
- On a fresh container the `MSSQL_SA_PASSWORD` env var sets the `sa` password. After that,
  changes must go through `ALTER LOGIN sa WITH PASSWORD = '...'`.
- Orphaned users: when you restore a database from backup to a different instance, existing
  users lose their login mapping (different SIDs). Fix with:
  `ALTER USER orphaned_user WITH LOGIN = existing_login`.

---

Previous: [03-indexes.md](03-indexes.md) | Next: [05-permissions-grants.md](05-permissions-grants.md)
