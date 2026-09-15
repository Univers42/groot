# 05 — Permissions: GRANT, DENY, REVOKE

SQL Server uses a three-state permission model. DENY is absolute and overrides GRANT — this
is a SQL Server-specific behaviour and the most common source of "why can't I do this?" bugs.

## The three states

| Statement | Effect |
|-----------|--------|
| `GRANT` | Allows the permission |
| `DENY` | Explicitly blocks the permission — overrides any GRANT, including via roles |
| `REVOKE` | Removes a previously granted or denied permission (neutral state) |

The effective permission for any principal is:
1. If any DENY exists in any role or direct grant chain → **denied**, period.
2. Else if a GRANT exists directly or through a role → **allowed**.
3. Otherwise → **denied** (default deny).

This means a user who is in `db_datareader` (which grants SELECT on all tables) can still be
blocked from reading a single sensitive table by issuing `DENY SELECT ON table TO user`.

## Scopes

Permissions can be granted at different levels of granularity:

```
Instance → Database → Schema → Object (table/view/procedure)
```

Higher-level grants cascade down unless overridden. Grant at the narrowest scope that
satisfies the need.

### Object-level GRANT

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
GRANT SELECT ON dbo.products TO shop_reader;
GRANT SELECT ON dbo.orders   TO shop_reader"'
```

### Schema-level GRANT

Grants the permission on all current and future objects in that schema:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
GRANT SELECT ON SCHEMA::dbo TO shop_reader"'
```

### Database-level GRANT

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
GRANT VIEW DEFINITION TO shop_reader"'
```

## DENY — the override

Even if `shop_reader` has a schema-level SELECT grant, DENY on a specific table blocks it:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
DENY SELECT ON dbo.customers TO shop_reader"'
```

`shop_reader` can now query `products` and `orders` but not `customers` — even if they are
added to `db_datareader` later. The DENY wins unconditionally.

## REVOKE — remove the permission entry

REVOKE removes a GRANT or DENY entry. It does not grant or deny — it returns the permission
to its default (neutral) state.

```bash
# Remove the DENY on customers (shop_reader falls back to whatever their roles allow)
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
REVOKE SELECT ON dbo.customers FROM shop_reader"'
```

## Fixed database roles

SQL Server ships with built-in database roles that cover common access patterns.
Add a user to a role with `ALTER ROLE`:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
ALTER ROLE db_datareader ADD MEMBER shop_reader"'
```

| Role | Permissions |
|------|-------------|
| `db_datareader` | SELECT on all tables/views |
| `db_datawriter` | INSERT, UPDATE, DELETE on all tables |
| `db_ddladmin` | CREATE, ALTER, DROP objects |
| `db_owner` | Full control of the database |
| `db_securityadmin` | Manage role membership and object permissions |
| `db_backupoperator` | BACKUP DATABASE |

Remove from a role:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
ALTER ROLE db_datareader DROP MEMBER shop_reader"'
```

Check a user's role membership:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SELECT dp.name AS member,
       rp.name AS role
FROM   sys.database_role_members rm
JOIN   sys.database_principals   dp ON dp.principal_id = rm.member_principal_id
JOIN   sys.database_principals   rp ON rp.principal_id = rm.role_principal_id
WHERE  dp.name = '"'"'shop_reader'"'"'"'
```

## Inspect effective permissions

See what permissions are explicitly granted or denied for a user:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
SELECT class_desc,
       OBJECT_NAME(major_id) AS object_name,
       permission_name,
       state_desc
FROM   sys.database_permissions
WHERE  grantee_principal_id = USER_ID('"'"'shop_reader'"'"')"'
```

## Scenario — read-only application user

Recipe for a connection that can only SELECT from the shop tables:

```bash
# 1. Create login + user (see 04-logins-users.md)
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '"'"'shop_reader'"'"')
  CREATE LOGIN shop_reader WITH PASSWORD = '"'"'R3aderP@ss!2026'"'"', CHECK_POLICY = ON"'

docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '"'"'shop_reader'"'"')
  CREATE USER shop_reader FOR LOGIN shop_reader"'

# 2. Grant SELECT on the dbo schema (covers products, orders, customers, views)
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
GRANT SELECT ON SCHEMA::dbo TO shop_reader"'

# 3. Block access to the sensitive customers PII table
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
DENY SELECT ON dbo.customers TO shop_reader"'

# 4. Verify by switching context
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
EXECUTE AS USER = '"'"'shop_reader'"'"';
  SELECT COUNT(*) AS can_read_products FROM dbo.products;
  SELECT COUNT(*) AS can_read_orders   FROM dbo.orders;
REVERT"'
```

Expected: `can_read_products` and `can_read_orders` return row counts.
Attempting `SELECT * FROM customers` inside `EXECUTE AS USER` would return a permission error.

## Gotchas / Docker notes

- **DENY always wins.** If a user is in `db_datareader` AND has a `DENY SELECT` on a table,
  the DENY wins — they cannot read that table. There is no way to override a DENY except with
  `REVOKE`.
- `REVOKE` is not the same as `DENY`. `REVOKE GRANT` leaves the user with no explicit
  permission entry — they may still get the permission through a role.
- `GRANT ... WITH GRANT OPTION` lets the grantee re-grant the permission to others.
  Avoid it unless you specifically need delegation.
- `EXECUTE AS USER` impersonation is useful for testing effective permissions without
  switching connections. Always `REVERT` when done.
- Fixed server roles (`sysadmin`, `securityadmin`, etc.) live at the instance level and
  are managed through `ALTER SERVER ROLE`. Database roles are separate from server roles.

---

Previous: [04-logins-users.md](04-logins-users.md) | Next: [06-security.md](06-security.md)
