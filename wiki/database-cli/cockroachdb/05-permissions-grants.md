# 05 — Permissions and Grants

CockroachDB uses a layered privilege model: privileges flow from database → schema → table. A principal needs `CONNECT` on the database, `USAGE` on the schema, and then object-level privileges. Default privileges control what new objects get automatically.

## Setup

```bash
docker exec mini-baas-cockroach cockroach sql --insecure \
  -e "CREATE DATABASE IF NOT EXISTS learn_cli;"
```

Create the shop schema from [01-crud.md](01-crud.md), then create a role to work with:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "
CREATE ROLE IF NOT EXISTS shop_readonly;
"
```

## GRANT — database level

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "
GRANT CONNECT ON DATABASE learn_cli TO shop_readonly;
"
```

`CONNECT` is the minimum needed to enter the database. Without it, the role cannot do anything.

## GRANT — schema level

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "
GRANT USAGE ON SCHEMA learn_cli.public TO shop_readonly;
"
```

`USAGE` lets the role reference objects in the schema. Required before any table-level grant takes effect.

## GRANT — table level

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "
GRANT SELECT ON TABLE learn_cli.public.customers TO shop_readonly;
GRANT SELECT ON TABLE learn_cli.public.products  TO shop_readonly;
"
```

Or grant across all existing tables at once:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "
GRANT SELECT ON ALL TABLES IN SCHEMA learn_cli.public TO shop_readonly;
"
```

Other common table privileges: `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `REFERENCES`, `TRIGGER`, `ALL`.

## SHOW GRANTS

Inspect grants on a database:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure -e "
SHOW GRANTS ON DATABASE learn_cli;
"
```

```
database_name  grantee        privilege_type  is_grantable
learn_cli      admin          ALL             t
learn_cli      public         CONNECT         f
learn_cli      root           ALL             t
learn_cli      shop_readonly  CONNECT         f
```

On a specific table:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
SHOW GRANTS ON TABLE customers;
"
```

```
database_name  schema_name  table_name  grantee        privilege_type  is_grantable
learn_cli      public       customers   admin           ALL             t
learn_cli      public       customers   root            ALL             t
learn_cli      public       customers   shop_readonly   SELECT          f
```

## REVOKE

Revoke a specific privilege:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
REVOKE SELECT ON TABLE orders FROM shop_readonly;
"
```

Revoke everything at once:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM shop_readonly;
REVOKE ALL ON SCHEMA public FROM shop_readonly;
"
docker exec mini-baas-cockroach cockroach sql --insecure -e "
REVOKE ALL ON DATABASE learn_cli FROM shop_readonly;
"
```

## Default privileges

Default privileges apply to objects created **in the future** — they do not retroactively change existing grants.

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
ALTER DEFAULT PRIVILEGES FOR ROLE root GRANT SELECT ON TABLES TO shop_readonly;
"
```

Now every table that `root` creates in `learn_cli` will automatically have `SELECT` granted to `shop_readonly`.

To revoke the default (required before dropping the role):

```bash
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
ALTER DEFAULT PRIVILEGES FOR ROLE root REVOKE ALL ON TABLES FROM shop_readonly;
"
```

## Scenario: `shop_readonly` read-only role recipe

This is the complete, copy-pasteable recipe for a read-only role that can see all shop tables but modify nothing.

```bash
# 1. Create the role
docker exec mini-baas-cockroach cockroach sql --insecure -e "
CREATE ROLE IF NOT EXISTS shop_readonly;
"

# 2. Layer the required privileges
docker exec mini-baas-cockroach cockroach sql --insecure -e "
GRANT CONNECT ON DATABASE learn_cli TO shop_readonly;
"
docker exec mini-baas-cockroach cockroach sql --insecure -e "
GRANT USAGE ON SCHEMA learn_cli.public TO shop_readonly;
"
docker exec mini-baas-cockroach cockroach sql --insecure -e "
GRANT SELECT ON ALL TABLES IN SCHEMA learn_cli.public TO shop_readonly;
"

# 3. Auto-grant SELECT on future tables created by root
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
ALTER DEFAULT PRIVILEGES FOR ROLE root GRANT SELECT ON TABLES TO shop_readonly;
"

# 4. Grant the role to a user (if needed)
docker exec mini-baas-cockroach cockroach sql --insecure -e "
CREATE USER IF NOT EXISTS reporting_svc;
GRANT shop_readonly TO reporting_svc;
"

# 5. Verify
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
SHOW GRANTS ON TABLE customers;
"
```

## Cleanup: removing the role safely

```bash
# Must revoke in reverse order: tables → schema → database → default privileges → drop
docker exec mini-baas-cockroach cockroach sql --insecure --database=learn_cli -e "
ALTER DEFAULT PRIVILEGES FOR ROLE root REVOKE ALL ON TABLES FROM shop_readonly;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM shop_readonly;
REVOKE ALL ON SCHEMA public FROM shop_readonly;
"
docker exec mini-baas-cockroach cockroach sql --insecure -e "
REVOKE ALL ON DATABASE learn_cli FROM shop_readonly;
REVOKE shop_readonly FROM reporting_svc;
DROP USER IF EXISTS reporting_svc;
DROP ROLE IF EXISTS shop_readonly;
"
```

Finally drop the scratch database:

```bash
docker exec mini-baas-cockroach cockroach sql --insecure \
  -e "DROP DATABASE learn_cli CASCADE;"
```

## Gotchas / Docker notes

- **Layer order is mandatory.** `GRANT SELECT ON TABLE` has no effect if the role lacks `CONNECT` on the database and `USAGE` on the schema. Both are required upstream.
- **`GRANT ... ON ALL TABLES IN SCHEMA` only covers existing tables.** Tables created later are not covered unless you also set `ALTER DEFAULT PRIVILEGES`.
- **`is_grantable` column.** If `t`, that grantee can in turn grant the privilege to others. The root and admin roles always have `is_grantable = t`.
- **`DROP ROLE` fails if grants exist.** The error message is helpful — it lists every object still granting to the role, including default privileges, which are easy to miss.
- **`public` role gets `CONNECT` by default.** New databases grant `CONNECT` to the built-in `public` role, meaning any authenticated user can enter the database. Restrict this with `REVOKE CONNECT ON DATABASE db FROM public;` if needed.

---

← [04-users-roles.md](04-users-roles.md) | [06-security.md](06-security.md) →
