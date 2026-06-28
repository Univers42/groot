# SQL Injection — platform / infrastructure (cross-cutting)

> Every `SECURITY DEFINER` function in the root database migrations pins its own `search_path`, preventing a hostile schema from shadowing built-ins or application objects to hijack execution under the function owner's elevated rights.

## What it is (the concept)

**SQL injection** is any attack in which attacker-controlled input is interpreted as SQL rather than data. A specific, under-appreciated variant targets **`SECURITY DEFINER` functions** in PostgreSQL: because such functions run under the privileges of their *owner* rather than the *caller*, an unguarded `search_path` lets an adversary pre-load a shadow schema whose objects (functions, operators, tables) intercept calls the function makes by unqualified name. Fixing it requires declaring a **fixed `search_path`** directly in the function header so PostgreSQL resolves names against that path before the session's path — and before any attacker-controlled schema can be inserted.

**Key vocabulary:** `SECURITY DEFINER`, `search_path`, schema shadowing, privilege escalation.

## What it defends against

See [SQL Injection](../../attack/sql-injection.md).

In this application, `SECURITY DEFINER` functions run as the `postgres` superuser (or a privileged role) and bypass RLS. A caller who can manipulate the session `search_path` — by creating a schema object with the same unqualified name as a built-in (`current_setting`, `lower`, `now`, etc.) — could redirect execution to attacker-controlled code running with elevated rights. The attack surface is realistic because `authenticated` and `anon` roles are created by GoTrue and can create objects in their own schemas.

## How platform implements it

The control is implemented directly in the `CREATE OR REPLACE FUNCTION` body of every `SECURITY DEFINER` function in the root migrations, using the `SET search_path = ...` clause that PostgreSQL evaluates before the function body runs.

**`models/auth-security-migration.sql`** (lines 88–92) — `auth_record_audit_event`, the audit logging hook:

```sql
CREATE OR REPLACE FUNCTION auth_record_audit_event(...)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
```

This function is called by the auth gateway to record every sensitive authentication event (login, registration, MFA, IP shift). It runs as the table owner and inserts into `auth_audit_events`. Pinning to `public` means it can only resolve `users`, `auth_audit_events`, and the standard built-ins in `pg_catalog`; no injected schema can shadow `current_setting` or `lower`.

**`models/auth-gateway-users-reconcile-migration.sql`** (lines 66–70 and 102–106) — two `SECURITY DEFINER` triggers:

```sql
-- users_reconcile_email() — BEFORE INSERT trigger, lines 66–70
CREATE OR REPLACE FUNCTION public.users_reconcile_email()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
```

```sql
-- handle_new_user() — AFTER INSERT on auth.users, lines 102–106
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
```

Both triggers bypass forced RLS (they need to write across auth/public schema boundaries) and would be high-value hijack targets. The `pg_temp` addition is intentional: it prevents a search-path attack via temporary objects that would otherwise be invisible to a `public`-only pin.

## How we know it is applied

The `search_path` pin is embedded in the `CREATE OR REPLACE FUNCTION` DDL itself: PostgreSQL stores it as a function attribute and re-applies it on every invocation, regardless of the session's `search_path`. There is no way to call these functions without the pin being active.

The bootstrap executor is `apps/grobase/scripts/db/apply-project-sql.sh`, mounted into the `project-db-init` service (defined in `apps/grobase/orchestrators/compose/docker-compose.track-binocle.yml`, line 77). At line 46 of the script the auth-security migration is applied unconditionally on every container start:

```sh
$psql_base -f /project-init/03-auth-security.sql
```

The reconcile migration carries its own idempotent apply command in its header (lines 32–35):

```sql
-- docker exec -i mini-baas-postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--   -f - < models/auth-gateway-users-reconcile-migration.sql
```

Both migrations are wrapped in `BEGIN; … COMMIT;` and are idempotent (`CREATE OR REPLACE FUNCTION`), so re-runs converge without overwriting the existing pin.

## Reference

The [SQL Injection Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html) from OWASP covers parameterized queries and stored-procedure hardening as the two primary defenses against injection. Pinning `search_path` on `SECURITY DEFINER` functions is the stored-procedure hardening discipline applied to PostgreSQL's privilege-escalation attack surface — it is not a substitute for parameterized queries but an additional, orthogonal layer that the cheat sheet's "defense in depth" principle requires.

The PostgreSQL documentation on [security-definer functions](https://www.postgresql.org/docs/current/sql-createfunction.html#SQL-CREATEFUNCTION-SECURITY) explicitly recommends this technique.

## Residual risk / assumptions

- **Volume mount drift.** The `docker-compose.track-binocle.yml` `project-db-init` service currently only mounts `models/user.sql` and `models/seeds.sql` into `/project-init/`. The `apply-project-sql.sh` script references several additional paths (including `/project-init/03-auth-security.sql`, `/project-init/04-osionos-bridge.sql`, etc.) that are **not mounted** in the compose file as of the current commit. This means the compose file is out of sync with the script; the migrations must be applied manually (via the inline `docker exec` commands in each file's header) or the compose volume list must be updated before the bootstrap path is fully automated.
- **Scope is root-app migrations only.** This control covers the functions in `models/*.sql`. Any `SECURITY DEFINER` function introduced in grobase's own migrations (`apps/grobase/scripts/migrations/postgresql/`) is subject to that submodule's own review standards.
- **RLS is still required.** `search_path` pinning prevents *schema shadowing*; it does not replace Row-Level Security for multi-tenant data isolation.
- **Superuser bypass.** A database superuser or a role with `SET ROLE` rights can still override the `search_path` at session level; the control assumes that only `service_role` (not `anon`/`authenticated`) has such rights.
