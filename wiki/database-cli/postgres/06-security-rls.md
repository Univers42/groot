# Row-Level Security (RLS)

After this file you can enable RLS on a table, write policies that filter or block rows
for specific roles, force the policy to apply even to the table owner, and test policies by
switching roles inside a session — the same pattern used in the repo's `models/*.sql`
migrations.

## What RLS does

Regular `GRANT` controls which operations a role may perform on an entire table. RLS goes
a level deeper: it controls which **rows** a role may see or touch. Every row that a policy's
`USING` clause returns `false` for is invisible — as if it does not exist.

Without RLS, a role with `SELECT` on `orders` sees every order in the system. With RLS and
a customer-scoping policy, the same role sees only the orders belonging to the current
customer. The database enforces this, not the application layer.

## Prerequisite

The `learn_cli` database must exist with the shop schema, data, roles `shop_readonly` and
`shop_app`, and grants from [05-permissions-grants.md](05-permissions-grants.md).

## Step 1 — Enable RLS on a table

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;"'
```

At this point, **superusers bypass RLS** (the `postgres` role still sees all rows). Non-owner
roles with SELECT on `orders` now see zero rows until a policy permits them.

## Step 2 — CREATE POLICY

### USING clause (read filter)

`USING` is evaluated for SELECT, UPDATE, and DELETE. Rows where the expression returns false
are hidden/rejected.

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE POLICY orders_owner ON orders
  USING (customer_id = current_setting('"'"'app.current_customer_id'"'"')::BIGINT);"'
```

The policy reads a custom session variable `app.current_customer_id`. The application sets
this variable when it starts a session:

```sql
SET app.current_customer_id = '42';
```

PostgreSQL preserves this for the duration of the connection.

### WITH CHECK clause (write guard)

`WITH CHECK` is evaluated for INSERT and UPDATE. Rows that fail the check are rejected.
If omitted, `WITH CHECK` defaults to the `USING` expression.

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
DROP POLICY IF EXISTS orders_owner ON orders;
CREATE POLICY orders_owner ON orders
  USING       (customer_id = current_setting('"'"'app.current_customer_id'"'"')::BIGINT)
  WITH CHECK  (customer_id = current_setting('"'"'app.current_customer_id'"'"')::BIGINT);"'
```

This means: you can only read rows that belong to you, and you can only write rows that
belong to you.

## Inspect policies

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
SELECT policyname, cmd, roles, qual
FROM pg_policies
WHERE tablename = '"'"'orders'"'"';"'
```

```
  policyname  | cmd |  roles   |                              qual
--------------+-----+----------+---------------------------------------------------
 orders_owner | ALL | {public} | (customer_id = (current_setting(...))::bigint)
```

`\d orders` also shows policies at the bottom of the table description.

## Step 3 — Test with SET ROLE

`postgres` is a superuser and bypasses RLS. To test policies, switch to a non-superuser role:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
SET ROLE shop_app;
SET app.current_customer_id = '"'"'1'"'"';
SELECT id, customer_id, status FROM orders;
RESET ROLE;"'
```

Expected — only customer 1's orders:
```
 id | customer_id | status
----+-------------+--------
  1 |           1 | paid
  2 |           1 | paid
```

Switch to customer 2:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
SET ROLE shop_app;
SET app.current_customer_id = '"'"'2'"'"';
SELECT id, customer_id, status FROM orders;
RESET ROLE;"'
```

```
 id | customer_id | status
----+-------------+---------
  3 |           2 | shipped
```

## FORCE RLS — apply policy to the table owner too

By default the table owner (usually `postgres`) bypasses RLS. Use `FORCE ROW LEVEL SECURITY`
to close that gap — useful when the application connects as the table owner:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
ALTER TABLE orders FORCE ROW LEVEL SECURITY;"'
```

> Superusers (`SUPERUSER` attribute) always bypass RLS regardless of `FORCE`. `FORCE` only
> applies to the non-superuser table owner.

## Per-role policies

You can write separate policies for different roles. Here: a staff role sees all orders;
a customer role sees only their own:

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE ROLE shop_staff NOLOGIN;

-- Staff see everything
CREATE POLICY orders_staff ON orders
  TO shop_staff
  USING (true);

-- Customers see only their rows (policy already exists for public)
"'
```

When multiple policies apply to the same role, PostgreSQL ORs them: a row is visible if
any applicable policy allows it.

## Disabling RLS

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
ALTER TABLE orders DISABLE ROW LEVEL SECURITY;"'
```

This removes enforcement but keeps the policies defined. Re-enable with `ENABLE ROW LEVEL
SECURITY`.

## Real-world tie-in: the repo's models/*.sql

The root repo's `models/*.sql` migrations follow this exact pattern. Each user-owned table
has:

```sql
ALTER TABLE <table> ENABLE ROW LEVEL SECURITY;
CREATE POLICY <table>_owner ON <table>
  USING  (user_id = auth.uid())   -- PostgREST JWT claim
  WITH CHECK (user_id = auth.uid());
```

`auth.uid()` is a helper function that reads the JWT subject claim injected by the GoTrue
auth service through the PostgREST `authenticator` role. The application never touches a
WHERE clause — the database enforces ownership at the storage layer.

## Least-privilege guidance

| Concern | Practice |
|---------|---------|
| Application reads | `shop_readonly` role + RLS policy |
| Application writes | `shop_app` role + `WITH CHECK` policy |
| Superuser access | Only for migrations and admin scripts, never the app role |
| `BYPASSRLS` | Never grant to application roles |
| `FORCE ROW LEVEL SECURITY` | Enable if the app connects as the table owner |

## Scenario: customers can only see their own orders

```bash
# 1. Enable RLS
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;"'

# 2. Create a policy: session var drives the filter
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
CREATE POLICY orders_owner ON orders
  USING       (customer_id = current_setting('"'"'app.current_customer_id'"'"')::BIGINT)
  WITH CHECK  (customer_id = current_setting('"'"'app.current_customer_id'"'"')::BIGINT);"'

# 3. Test as shop_app (customer 1)
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
SET ROLE shop_app;
SET app.current_customer_id = '"'"'1'"'"';
SELECT id, customer_id, status FROM orders;
RESET ROLE;"'

# 4. Test as shop_app (customer 3)
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d learn_cli -c "
SET ROLE shop_app;
SET app.current_customer_id = '"'"'3'"'"';
SELECT id, customer_id, status FROM orders;
RESET ROLE;"'
```

## Gotchas / Docker notes

- **Superusers always bypass RLS** — `FORCE ROW LEVEL SECURITY` only affects non-superuser
  owners. `postgres` inside this container is a superuser and always sees everything.
- **`SET app.current_customer_id = '1'` must happen before the SELECT**. If the session
  variable is missing, `current_setting('app.current_customer_id')` raises
  `ERROR: unrecognized configuration parameter`. Use `current_setting('...', true)` (with the
  `missing_ok` flag) to return NULL instead.
- **`pg_policies` column names**: use `policyname`, `cmd`, `roles`, `qual` — not `polname` or
  `polcmd` (those are the raw catalog column names in `pg_policy`, not the view).
- **Multiple policies are ORed, not ANDed**: if any policy permits the row, the row is
  accessible. To restrict further, use `WITH CHECK` or a more specific `USING` clause.
- **RLS is per-table**: enabling it on `orders` does not affect `customers` or `products`.
  Each table you want to protect needs its own `ENABLE` and policies.

---

Previous: [05-permissions-grants.md](05-permissions-grants.md) | Next: [07-backup-restore.md](07-backup-restore.md)
