# Connecting to PostgreSQL via Docker

After reading this file you can open an interactive `psql` session, fire one-shot queries,
run a `.sql` script inside the container, and navigate databases, schemas, and tables using
psql meta-commands — all without installing anything on the host.

## The two connection patterns

### Interactive session

```bash
docker exec -it mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

What each flag does:
- `-it` — allocates a TTY so psql can show its prompt and accept keystrokes
- `sh -lc '...'` — runs a login shell (`-l`) so the container's env vars (`$POSTGRES_USER`,
  `$POSTGRES_DB`) are set before the quoted command (`-c`) runs; never hardcode values
- `-U "$POSTGRES_USER"` — the database role to connect as
- `-d "$POSTGRES_DB"` — the initial database

You land at the `postgres=#` prompt. Type `\q` to quit.

### One-shot (non-interactive)

```bash
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT version();"'
```

Expected output:
```
                                         version
------------------------------------------------------------------------------------------
 PostgreSQL 16.14 on x86_64-pc-linux-musl, compiled by gcc (Alpine 15.2.0) 15.2.0, 64-bit
(1 row)
```

Drop `-it` for one-shot commands — the shell is not interactive so no TTY is needed.

### Chaining multiple one-shot commands

Pass each meta-command or SQL statement as a separate `-c` flag; psql executes them in order:

```bash
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\x on" -c "SELECT * FROM pg_database LIMIT 1;"'
```

> **Why separate `-c` flags?** psql meta-commands (`\x`, `\d`, etc.) cannot be mixed with SQL
> inside a single `-c "..."` string — that would be parsed as SQL and raise a syntax error.

## Running a `.sql` file

Two steps: copy the file in, then run it with `psql -f`.

```bash
# 1. Copy your local script into the container
docker cp /path/to/my_script.sql mini-baas-postgres:/tmp/my_script.sql

# 2. Execute it
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d learn_cli -f /tmp/my_script.sql'
```

Pipe stdout back out if you want to capture results on the host:

```bash
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d learn_cli -f /tmp/my_script.sql' > results.txt
```

## Essential psql meta-commands

Meta-commands start with `\` and are interpreted by the psql client, not the server.

| Command | What it shows |
|---------|--------------|
| `\l` | all databases |
| `\c <db>` | switch to another database |
| `\dn` | schemas in the current database |
| `\dt` | tables in the current search_path |
| `\dt public.*` | tables in the `public` schema |
| `\d <table>` | column types, defaults, indexes, constraints, FK, policies |
| `\dv` | views |
| `\di` | indexes |
| `\du` | roles and their attributes |
| `\dp <table>` | ACL (access privileges) for a table |
| `\timing` | toggle query timing on/off |
| `\x` | toggle expanded (vertical) display |
| `\q` | quit |

In one-shot mode each meta-command needs its own `-c`:

```bash
# List schemas
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\dn"'
```

Expected output:
```
        List of schemas
    Name    |       Owner
------------+-------------------
 auth       | postgres
 gdpr       | postgres
 newsletter | postgres
 public     | pg_database_owner
 session    | postgres
```

```bash
# List roles
docker exec mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\du"'
```

Expected output (abbreviated):
```
                                   List of roles
       Role name       |                         Attributes
-----------------------+------------------------------------------------------------
 anon                  | Cannot login
 authenticated         | Cannot login
 authenticator         | No inheritance
 postgres              | Superuser, Create role, Create DB, Replication, Bypass RLS
 service_role          | Cannot login, Bypass RLS
```

## Listing databases with SQL

`\l` works inside an interactive session. In automation, a SQL query is more scriptable:

```bash
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT datname FROM pg_database ORDER BY datname;"'
```

## Creating the learn_cli scratch database

Every example in this series writes only to `learn_cli`. Create it once:

```bash
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE DATABASE learn_cli;"'
```

Connect to it in one-shot commands by passing `-d learn_cli`:

```bash
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d learn_cli -c "SELECT current_database();"'
```

```
 current_database
------------------
 learn_cli
(1 row)
```

### Cleanup

When you are done with all the exercises, drop the scratch database:

```bash
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DROP DATABASE learn_cli;"'
```

## Scenario: orient yourself on a live system

```bash
# What databases exist?
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT datname FROM pg_database ORDER BY datname;"'

# What schemas are in postgres?
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\dn"'

# What tables are in the public schema?
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\dt public.*"'

# Inspect one table
docker exec mini-baas-postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\d public.tenants"'
```

## Gotchas / Docker notes

- **`-it` vs no `-it`**: always include `-it` for interactive sessions; omit it for scripted
  one-shot commands (a missing TTY causes garbled output in non-interactive contexts).
- **Login shell matters**: `sh -lc '...'` (with `-l`) sources the container's profile and
  expands `$POSTGRES_USER`. Plain `sh -c '...'` may leave the variable unset on some images.
- **Meta-commands in `-c`**: psql meta-commands (`\d`, `\l`, etc.) cannot appear inside the
  same `-c "..."` string as SQL. Each meta-command needs its own `-c` flag.
- **Trust auth**: connections from inside the container use trust authentication — no password
  prompt. This is an internal-only shortcut; PostgREST and external clients still require
  the role password.
- **`DROP DATABASE` cannot run inside a transaction block**: pass it as a single standalone
  `-c` statement, never combined with other statements in the same `-c "..."` string.
- **Never read or modify the live databases** (`postgres`, `agency`, `commerce`, etc.) while
  learning. All DDL and DML go into `learn_cli`.

---

Next: [01-crud.md](01-crud.md) — CREATE TABLE, INSERT, SELECT, UPDATE, DELETE, UPSERT
