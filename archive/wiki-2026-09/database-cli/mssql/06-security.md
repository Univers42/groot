# 06 — Security Hardening in SQL Server

Security in SQL Server is layered: schemas define namespaces and permission boundaries,
ownership chaining reduces the permission surface for stored procedures and views, and
transport/at-rest encryption protects data in flight and on disk.

## Schemas as security boundaries

A schema is both a namespace (`dbo.orders`, `reporting.order_totals`) and a unit of
permission. Granting `SELECT ON SCHEMA::reporting` covers all current and future objects
in that schema without touching the `dbo` schema.

```bash
# Create a reporting schema owned by dbo
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
CREATE SCHEMA reporting"'

# Create a view in the reporting schema
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
CREATE VIEW reporting.order_totals AS
SELECT customer_id,
       SUM(o.qty * p.price_cents) AS total_cents
FROM   dbo.orders o
JOIN   dbo.products p ON p.id = o.product_id
GROUP  BY customer_id"'

# Grant access to the whole schema — no per-object grants needed
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
GRANT SELECT ON SCHEMA::reporting TO shop_reader"'
```

The `shop_reader` user can query `reporting.*` but cannot reach `dbo.*` unless granted
separately (or unless a DENY is in place, which overrides everything).

## Ownership chaining

When a stored procedure or view references a table and both share the same owner, SQL Server
skips the permission check on the underlying table and checks only the procedure/view
permission. This is called the "ownership chain."

Example: `shop_reader` has `EXECUTE` on `dbo.get_orders` but no SELECT on `dbo.orders`.
If both are owned by `dbo`, the chain is unbroken and the procedure succeeds:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
CREATE PROCEDURE dbo.get_pending_orders AS
  SELECT id, customer_id, qty FROM dbo.orders WHERE status = '"'"'pending'"'"'"'

docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
GRANT EXECUTE ON dbo.get_pending_orders TO shop_reader"'
```

`shop_reader` can now call the procedure even without a direct SELECT grant on `orders`.
This is the standard pattern for exposing data through a controlled API layer.

## Principle of least privilege

Follow this checklist when creating any new application user:

1. Create a dedicated login with a strong password and `CHECK_POLICY = ON`.
2. Create a corresponding user in only the databases the application needs.
3. Grant permissions at the schema level rather than the table level where possible.
4. Use DENY to explicitly block access to sensitive tables (PII, audit logs, credentials).
5. Never add an application user to `db_owner` or `sysadmin`.
6. Use stored procedures or views as access layers — grant EXECUTE/SELECT on them only.

## Password policy (`CHECK_POLICY`)

`CHECK_POLICY = ON` enforces SQL Server's built-in complexity rules:
- Minimum 8 characters.
- Must include characters from at least three of: uppercase, lowercase, digits, symbols.

```bash
# Create a login with policy enforcement on, expiration off
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
CREATE LOGIN app_user
WITH PASSWORD       = '"'"'Str0ng!Pass2026'"'"',
     CHECK_POLICY    = ON,
     CHECK_EXPIRATION = OFF"'
```

Check current policy settings for all SQL logins:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
SELECT name, is_policy_checked, is_expiration_checked, is_disabled
FROM   sys.sql_logins
ORDER  BY name"'
```

## Encryption in transit — the `-C` story

The `sqlcmd` tools18 client **encrypts all connections by default**. When the server uses a
self-signed certificate (as in this Docker stack), you must pass `-C` on every connection
to trust it:

```
sqlcmd ... -C
```

Without `-C` you get:
```
SSL Provider: certificate verify failed: self-signed certificate
Client unable to establish connection.
```

In production, replace the self-signed cert with one issued by a trusted CA and remove
the need for `-C`. Set `MSSQL_TLS_CERT` and `MSSQL_TLS_KEY` environment variables on the
container to provide a real certificate.

To force unencrypted connections (never do this in production):

```bash
# -Ys = encrypt=strict, -Ym = encrypt=mandatory, -Yo = encrypt=optional (no cert check)
# -Yo disables encryption entirely — only for isolated local dev, never network-exposed
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -Yo -Q "SELECT 1"'
```

## Transparent Data Encryption (TDE)

TDE encrypts the data files and log files on disk. If someone steals the `.mdf`/`.ldf` files,
they cannot read them without the database encryption key. TDE is transparent to applications.

Enabling TDE is a pattern (unverified in this dev container — it requires a service master
key and database master key that may not be initialised):

```sql
-- pattern (unverified here)
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'MasterK3y!';
CREATE CERTIFICATE tde_cert WITH SUBJECT = 'TDE Certificate';
CREATE DATABASE ENCRYPTION KEY WITH ALGORITHM = AES_256
  ENCRYPTION BY SERVER CERTIFICATE tde_cert;
ALTER DATABASE learn_cli SET ENCRYPTION ON;
```

TDE has no query-level overhead but does affect backup size and time.

## Auditing overview

SQL Server audits at two levels:
- **Server Audit**: captures instance-level events (logins, server role changes) — written
  to the Windows Event Log or a file target.
- **Database Audit Specification**: captures database-level events (SELECT, INSERT, schema
  changes) — attached to a Server Audit.

In this Docker-only context, auditing writes to files or the SQL Server error log:

```sql
-- pattern (unverified here — requires elevated permissions and file target path)
CREATE SERVER AUDIT shop_audit
  TO FILE (FILEPATH = '/var/opt/mssql/audit/');
ALTER SERVER AUDIT shop_audit WITH (STATE = ON);
CREATE DATABASE AUDIT SPECIFICATION shop_db_audit
  FOR SERVER AUDIT shop_audit
  ADD (SELECT ON dbo.customers BY public);
ALTER DATABASE AUDIT SPECIFICATION shop_db_audit WITH (STATE = ON);
```

For lightweight event capture in dev, use `SQL Server Profiler` (not available in sqlcmd)
or `sys.dm_exec_query_stats` / `sys.dm_exec_sessions` DMVs to inspect live activity.

## Practical hardening checklist

```
[ ] sa login is disabled or has a strong, unique password
[ ] Every application login uses CHECK_POLICY = ON
[ ] No application user has sysadmin or db_owner
[ ] Sensitive tables (PII, audit) have explicit DENY on non-admin users
[ ] Connections use encryption (-C or a trusted cert in production)
[ ] The `guest` user is disabled in user databases:
      REVOKE CONNECT FROM guest;
[ ] Old / unused logins are disabled or dropped
[ ] Permissions follow schema-level grants + object-level DENYs
[ ] TDE is enabled for databases that store PII (production)
[ ] Backups are tested and stored off-box
```

Disable the guest user in `learn_cli`:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -Q "
REVOKE CONNECT FROM guest"'
```

## Gotchas / Docker notes

- On Linux the SQL Server process runs as the `mssql` user inside the container.
  The data directory `/var/opt/mssql/data/` must be writable by that user — relevant
  if you mount a host volume.
- `CREATE SCHEMA` must be the only statement in its batch (use separate docker exec
  calls or the `sqlcmd -i` pattern).
- Ownership chaining breaks across databases by default. Cross-database chaining requires
  `TRUSTWORTHY` on the database or a certificate-based trust — avoid it unless necessary.
- In this stack the `mini-baas-mssql` container is not exposed to the host network by
  default. The security surface is only the Docker bridge network shared with other
  `mini-baas-*` services.

---

Previous: [05-permissions-grants.md](05-permissions-grants.md) | Next: [07-backup-restore.md](07-backup-restore.md)
