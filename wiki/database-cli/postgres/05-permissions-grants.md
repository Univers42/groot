# Permissions and Grants

After this file you can give a role exactly the access it needs and nothing more — granting
on databases, schemas, tables, and columns, setting defaults for future objects, and auditing
the ACL (access control list) with psql meta-commands.

## Prerequisite

The `learn_cli` database must exist with the shop schema and the roles from
[04-users-roles.md](04-users-roles.md) (`shop_readonly`, `shop_readwrite`, `shop_app`).

## The privilege ladder

Every object in PostgreSQL has an owner (full control) and an ACL. To reach a table, a role
needs privileges at every level:

1. **CONNECT** on the database
2. **USAGE** on the schema
3. **SELECT / INSERT / UPDATE / DELETE** on the table (or specific columns)

Miss any level and access is denied.

## GRANT on database

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
GRANT CONNECT ON DATABASE learn_cli TO shop_readonly;"'
```

Without `CONNECT`, a role cannot even open a connection to the database.

## GRANT USAGE on schema

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
GRANT USAGE ON SCHEMA public TO shop_readonly;"'
```

`USAGE` on a schema lets the role see and address objects inside it. Without this, even a
table grant is unreachable.

## GRANT on tables

### Read-only: SELECT on all current tables

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
GRANT SELECT ON ALL TABLES IN SCHEMA public TO shop_readonly;"'
```

`ALL TABLES IN SCHEMA` is a shortcut — it applies to every table, view, and materialized
view currently in the schema. Tables created after this statement need a separate grant (or
use `ALTER DEFAULT PRIVILEGES` — see below).

### Read-write: specific privileges on one table

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
GRANT SELECT, INSERT, UPDATE, DELETE ON orders TO shop_app;"'
```

### Granting on sequences

`GENERATED ALWAYS AS IDENTITY` columns use sequences internally. A role that inserts rows
also needs `USAGE` on the backing sequence:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO shop_app;"'
```

### Column-level grants

Restrict a role to specific columns only:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
GRANT SELECT (id, name) ON customers TO shop_readonly;"'
```

## Inspecting grants

### \dp — table ACL

```bash
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d learn_cli -c "\dp customers"'
```

```
                                   Access privileges
 Schema |   Name    | Type  |     Access privileges     | Column privileges | Policies
--------+-----------+-------+---------------------------+-------------------+----------
 public | customers | table | postgres=arwdDxt/postgres+|                   |
        |           |       | shop_readonly=r/postgres  |                   |
```

ACL letter key: `a`=INSERT, `r`=SELECT, `w`=UPDATE, `d`=DELETE, `D`=TRUNCATE, `x`=REFERENCES,
`t`=TRIGGER.

`\z` is an alias for `\dp`:

```bash
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d learn_cli -c "\z orders"'
```

### information_schema for scripting

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
SELECT grantee, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE grantee IN ('"'"'shop_readonly'"'"', '"'"'shop_app'"'"')
ORDER BY grantee, table_name, privilege_type;"'
```

Expected (with the grants applied above):
```
    grantee    |  table_name   | privilege_type
---------------+---------------+----------------
 shop_app      | orders        | DELETE
 shop_app      | orders        | INSERT
 shop_app      | orders        | SELECT
 shop_app      | orders        | UPDATE
 shop_readonly | customers     | SELECT
 shop_readonly | order_summary | SELECT
 shop_readonly | orders        | SELECT
 shop_readonly | products      | SELECT
```

## ALTER DEFAULT PRIVILEGES

Tables created after a bulk `GRANT ... ON ALL TABLES` do not automatically inherit the grant.
Fix this with default privileges so every new table in the schema gets the right grant
automatically:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO shop_readonly;"'
```

Verify:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
SELECT defaclobjtype, defaclacl
FROM pg_default_acl
WHERE defaclrole = (SELECT oid FROM pg_roles WHERE rolname = '"'"'postgres'"'"');"'
```

```
 defaclobjtype |         defaclacl
---------------+----------------------------
 r             | {shop_readonly=r/postgres}
```

`r` means tables (relations). The ACL `{shop_readonly=r/postgres}` reads as: `shop_readonly`
gets SELECT (`r`) granted by `postgres`.

## REVOKE

Remove a privilege:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
REVOKE DELETE ON orders FROM shop_app;"'
```

Revoke everything at once:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
REVOKE ALL ON orders FROM shop_app;"'
```

## Scenario: shop_readonly role for a reporting pipeline

```bash
# 1. Create the role (if not already done)
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE ROLE shop_readonly NOLOGIN;"'

# 2. Grant database connect
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
GRANT CONNECT ON DATABASE learn_cli TO shop_readonly;"'

# 3. Grant schema visibility
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
GRANT USAGE ON SCHEMA public TO shop_readonly;"'

# 4. Grant SELECT on existing tables
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
GRANT SELECT ON ALL TABLES IN SCHEMA public TO shop_readonly;"'

# 5. Auto-grant SELECT on future tables
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO shop_readonly;"'

# 6. Create a login user that inherits from shop_readonly
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE ROLE reporting_user LOGIN;
GRANT shop_readonly TO reporting_user;"'

# 7. Verify the ACL
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d learn_cli -c "\dp customers"'
```

## Gotchas / Docker notes

- **Public schema implicit USAGE**: in PostgreSQL 15+, the `public` schema no longer has
  implicit `USAGE` for all roles. Always grant `USAGE ON SCHEMA public` explicitly.
- **`ALL TABLES` is a snapshot**: it grants on tables that exist at the moment the statement
  runs. Use `ALTER DEFAULT PRIVILEGES` for future objects.
- **Sequence grants for identity columns**: even though the column generates its own value,
  the INSERT still touches the sequence. A missing sequence `USAGE` grant causes
  `permission denied for sequence ...` on insert.
- **Column grants and row grants are independent**: granting SELECT on column `(id, name)` does
  not grant SELECT on the whole row. The role sees only those two columns.
- **`GRANT ... TO PUBLIC`**: `PUBLIC` is a special pseudo-role meaning every role. Avoid
  using it for anything sensitive.

---

Previous: [04-users-roles.md](04-users-roles.md) | Next: [06-security-rls.md](06-security-rls.md)
