# PostgreSQL CLI — Docker Learning Notes

This series covers every day-to-day PostgreSQL skill you need when the only way in is
`docker exec`. There is no host `psql`; every command runs inside the `mini-baas-postgres`
container (PostgreSQL 16.14, Alpine-based, trust auth for local connections).

## Engine facts

| Item | Value |
|------|-------|
| Container | `mini-baas-postgres` |
| Compose project | `mini-baas` |
| PostgreSQL version | 16.14 |
| Auth (in-container) | trust — no password needed for `psql` inside the container |
| Key env vars | `$POSTGRES_USER`, `$POSTGRES_DB` |

## Quick connect

```bash
# Interactive shell
docker exec -it mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'

# One-shot query
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select version();"'
```

The `-lc` flag on `sh` reads the container's login profile so that `$POSTGRES_USER` and
`$POSTGRES_DB` are expanded from the container's own environment — never hardcode secrets.

## Concept files

1. [00-connect.md](00-connect.md) — interactive vs one-shot, running `.sql` files, essential
   psql meta-commands, listing databases/schemas/tables, creating the scratch DB
2. [01-crud.md](01-crud.md) — CREATE TABLE, INSERT, SELECT with JOINs and aggregates, UPDATE,
   DELETE, UPSERT
3. [02-views.md](02-views.md) — regular views, updatable views, WITH CHECK OPTION, materialized
   views, when to use which
4. [03-indexes.md](03-indexes.md) — B-tree, UNIQUE, composite, partial, expression indexes, GIN
   note, EXPLAIN / EXPLAIN ANALYZE
5. [04-users-roles.md](04-users-roles.md) — CREATE ROLE / CREATE USER, LOGIN, passwords, role
   attributes, group roles, membership, ALTER ROLE, DROP ROLE
6. [05-permissions-grants.md](05-permissions-grants.md) — GRANT/REVOKE on database/schema/table,
   read-only role recipe, ALTER DEFAULT PRIVILEGES, inspecting grants
7. [06-security-rls.md](06-security-rls.md) — Row-Level Security: enable, CREATE POLICY, FORCE
   RLS, SET ROLE testing, least-privilege guidance, repo tie-in
8. [07-backup-restore.md](07-backup-restore.md) — pg_dump (plain and custom `-Fc`), pg_restore,
   piping, docker cp, single-table dumps, restore into scratch DB
9. [08-transactions-isolation.md](08-transactions-isolation.md) — BEGIN/COMMIT/ROLLBACK,
   SAVEPOINT, isolation levels, SELECT FOR UPDATE, deadlock notes

## Sample domain

All files share one shop schema inside the `learn_cli` scratch database:

```
customers(id, name, email, created_at)
products(id, name, price_cents, stock)
orders(id, customer_id, product_id, qty, status, created_at)
```

`learn_cli` is the only database you ever write to while learning. Drop it with
`DROP DATABASE learn_cli;` when finished (see [00-connect.md](00-connect.md)).

## Real-world tie-in

The live `mini-baas-postgres` instance hosts grobase's own tables in the `postgres` database
(public schema, 100+ tables). PostgREST roles such as `anon`, `authenticated`, and
`authenticator` are already present. The root repo's `models/*.sql` migrations are
RLS-enforced — the patterns in [06-security-rls.md](06-security-rls.md) explain exactly how
that works.
