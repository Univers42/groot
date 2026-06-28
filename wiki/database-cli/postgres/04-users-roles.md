# Users and Roles

After this file you can create roles with the right attributes for any situation — group roles
that cannot log in, application users that can, superusers for admin work — wire them together
with membership, and clean them up safely.

## Prerequisite

The `learn_cli` database must exist (see [00-connect.md](00-connect.md)).

## Roles vs users: the PostgreSQL model

PostgreSQL has a single object type for both: the **role**. The only difference between a
"role" and a "user" is the `LOGIN` attribute.

| Statement | Equivalent to |
|-----------|--------------|
| `CREATE USER foo` | `CREATE ROLE foo WITH LOGIN` |
| `CREATE ROLE foo` | `CREATE ROLE foo` (no LOGIN by default) |

Prefer `CREATE ROLE` everywhere and be explicit about `LOGIN`. It makes intent clear.

## Real roles on this instance

```bash
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\du"'
```

You will see `anon`, `authenticated`, `authenticator`, `service_role` — these are
PostgREST / Supabase-pattern roles that grobase wires up. Do not modify them.

## CREATE ROLE — no login (group / permission role)

A role without `LOGIN` can hold privileges; real users inherit those privileges by joining
the group:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE ROLE shop_readonly NOLOGIN;"'
```

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE ROLE shop_readwrite NOLOGIN;"'
```

## CREATE ROLE — with LOGIN (application user)

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE ROLE shop_app LOGIN;"'
```

In a real deployment you would always set a password (see below). Trust auth inside the
container lets you skip it while learning.

## Passwords

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
ALTER ROLE shop_app WITH PASSWORD '"'"'s3cr3t_app_pw'"'"';"'
```

Passwords are stored hashed; `\du` never reveals them. To rotate:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
ALTER ROLE shop_app WITH PASSWORD '"'"'new_s3cr3t'"'"';"'
```

To remove a password (trust only):

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
ALTER ROLE shop_app WITH PASSWORD NULL;"'
```

## Role attributes

Pass attributes directly in `CREATE ROLE` or change them with `ALTER ROLE`:

| Attribute | Meaning |
|-----------|---------|
| `LOGIN` / `NOLOGIN` | Whether the role can open a connection |
| `SUPERUSER` / `NOSUPERUSER` | Bypasses all access checks (dangerous) |
| `CREATEDB` / `NOCREATEDB` | Can create new databases |
| `CREATEROLE` / `NOCREATEROLE` | Can create / alter / drop roles |
| `REPLICATION` | Can connect in replication mode |
| `BYPASSRLS` / `NOBYPASSRLS` | Ignores Row-Level Security policies |
| `CONNECTION LIMIT n` | Max concurrent connections (-1 = unlimited) |
| `VALID UNTIL 'timestamp'` | Expiry date for the role |

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
ALTER ROLE shop_app CONNECTION LIMIT 10;"'
```

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
SELECT rolname, rolcanlogin, rolconnlimit, rolinherit
FROM pg_roles
WHERE rolname LIKE '"'"'shop%'"'"';"'
```

```
   rolname    | rolcanlogin | rolconnlimit | rolinherit
--------------+-------------+--------------+------------
 shop_app     | t           |           10 | t
 shop_readonly | f          |           -1 | t
 shop_readwrite| f          |           -1 | t
```

## Group roles and membership (GRANT role TO role)

Assign `shop_readonly` to `shop_app` so `shop_app` inherits its privileges:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
GRANT shop_readonly TO shop_app;"'
```

`rolinherit = t` (the default) means `shop_app` automatically has all privileges of
`shop_readonly` without needing to call `SET ROLE`.

Add a second application role with write access:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE ROLE shop_writer LOGIN;
GRANT shop_readwrite TO shop_writer;"'
```

Verify membership:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
SELECT r.rolname AS role, m.rolname AS member
FROM pg_auth_members am
JOIN pg_roles r ON r.oid = am.roleid
JOIN pg_roles m ON m.oid = am.member
WHERE r.rolname LIKE '"'"'shop%'"'"'
ORDER BY role, member;"'
```

```
     role      |   member
---------------+-------------
 shop_readonly | shop_app
 shop_readwrite| shop_writer
```

## ALTER ROLE

```bash
# Rename a role
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
ALTER ROLE shop_writer RENAME TO shop_api_writer;"'

# Add CREATEDB
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
ALTER ROLE shop_api_writer CREATEDB;"'
```

## DROP ROLE

A role cannot be dropped while it owns objects or has outstanding privileges.

```bash
# Safe cleanup sequence
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
REVOKE shop_readwrite FROM shop_api_writer;
DROP ROLE IF EXISTS shop_api_writer;"'
```

If you see `ERROR: role cannot be dropped because some objects depend on it`, reassign its
objects first:

```sql
-- pattern (unverified here — no owned objects in our scratch DB)
REASSIGN OWNED BY shop_api_writer TO postgres;
DROP OWNED BY shop_api_writer;
DROP ROLE shop_api_writer;
```

## Scenario: three-tier role hierarchy

```bash
# 1. Group roles (no login)
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE ROLE shop_readonly  NOLOGIN;
CREATE ROLE shop_readwrite NOLOGIN;"'

# 2. Application users (login, inherits from group)
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE ROLE app_reader LOGIN;
CREATE ROLE app_writer LOGIN;
GRANT shop_readonly  TO app_reader;
GRANT shop_readwrite TO app_writer;
GRANT shop_readonly  TO app_writer;"'
# app_writer inherits BOTH read + write by being in both groups

# 3. Verify hierarchy
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
SELECT r.rolname, m.rolname AS member
FROM pg_auth_members am
JOIN pg_roles r ON r.oid = am.roleid
JOIN pg_roles m ON m.oid = am.member
WHERE r.rolname LIKE '"'"'shop%'"'"'
ORDER BY r.rolname, m.rolname;"'
```

## Gotchas / Docker notes

- **`CREATE USER` is just an alias** — prefer `CREATE ROLE ... LOGIN` so the intent is explicit.
- **`postgres` is a superuser** inside this container. Every `psql` session inside the
  container runs as `postgres` (trust auth). Real application code should connect with a
  minimal-privilege role.
- **Dropping a role with objects fails silently only with `IF EXISTS`** — `IF EXISTS` only
  suppresses "role does not exist", not "role has dependent objects".
- **Role names are shared across all databases** in the cluster. A role you create in
  `learn_cli` is visible from `postgres` and every other database.
- **`BYPASSRLS` is dangerous**: it silently skips every Row-Level Security policy. Never
  grant it to application roles; reserve it for admin scripts.

---

Previous: [03-indexes.md](03-indexes.md) | Next: [05-permissions-grants.md](05-permissions-grants.md)
