# 00 — Connecting to SQL Server via sqlcmd

`sqlcmd` is the primary CLI client for Microsoft SQL Server; it ships inside `mini-baas-mssql`
and is the only way to interact with the database from a Docker-first workflow.

## The mandatory `-C` flag

`sqlcmd` in the tools18 build encrypts connections by default. When the server uses a self-signed
certificate (as it does here) you must pass `-C` (trust server certificate) on **every** call,
or the connection fails:

```
SQLState = 08001, NativeError = 4294967295
Error: SSL Provider: certificate verify failed: self-signed certificate
```

Always include `-C`. There are no exceptions in this stack.

## Interactive mode

```bash
docker exec -it mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C'
```

The `-it` flags on `docker exec` allocate a pseudo-TTY — required for the interactive prompt.
You land at the `1>` prompt and type T-SQL freely.

## The GO batch terminator

`sqlcmd` does not execute SQL as you type it. Instead it accumulates lines into a **batch**.
`GO` is the signal to send the current batch to the server and reset the buffer:

```sql
1> SELECT @@VERSION
2> GO
```

Without `GO`, nothing runs. This trips up everyone coming from `psql` (which executes on `;`)
or MySQL (same). In `sqlcmd`:
- Semicolons are optional within a batch (they separate statements but do not send the batch).
- `GO` is the batch terminator, not part of T-SQL itself — it is a `sqlcmd` directive.
- Certain DDL statements (`CREATE VIEW`, `CREATE PROCEDURE`, `CREATE SCHEMA`, `ALTER VIEW`, etc.)
  must be the **first and only** statement in their batch. Surround them with `GO` above and below.

## One-shot mode (`-Q` and `-q`)

For scripting, use `-Q` to run a query and exit immediately:

```bash
# -Q runs the query, prints results, and exits
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "SELECT @@VERSION"'
```

Expected output:

```
Microsoft SQL Server 2022 (RTM-CU25) (KB5081477) - 16.0.4255.1 (X64)
  Apr 23 2026 22:38:54
  Copyright (C) 2022 Microsoft Corporation
  Developer Edition (64-bit) on Linux (Ubuntu 22.04.5 LTS)
```

`-q` (lowercase) also runs the query, but then drops you into the interactive prompt instead
of exiting. Useful for inspecting state after a setup command.

## Running a .sql file (`-i`)

`GO` batch separators work correctly only in `-i` (file input) mode or interactive mode —
not in `-Q` one-shots. The typical workflow for multi-batch scripts:

```bash
# 1. Write the script locally
cat > /tmp/setup.sql << 'EOF'
SET QUOTED_IDENTIFIER ON;
GO
CREATE VIEW dbo.order_summary AS
SELECT id FROM dbo.orders;
GO
EOF

# 2. Copy it into the container
docker cp /tmp/setup.sql mini-baas-mssql:/tmp/setup.sql

# 3. Run it
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -i /tmp/setup.sql'
```

Use this pattern whenever you need `GO` separators (multi-batch DDL, stored procedures, etc.).

## Useful flags

| Flag | Meaning |
|------|---------|
| `-S localhost` | Server/host to connect to |
| `-U sa` | Login name |
| `-P "$MSSQL_SA_PASSWORD"` | Password (resolve from container env, never hardcode) |
| `-C` | Trust server certificate (REQUIRED) |
| `-d learn_cli` | Default database context (`USE learn_cli`) |
| `-Q "..."` | Run query and exit |
| `-q "..."` | Run query then drop into interactive |
| `-i /path/file.sql` | Execute a SQL script file |
| `-h -1` | Suppress column headers entirely |
| `-W` | Remove trailing spaces from column values |
| `-s "|"` | Column separator character (useful for CSV-like output) |
| `-E` | Use trusted connection (Windows auth — not applicable in Linux containers) |

Combined for pipe-friendly output:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -h -1 -W -s "|" \
   -Q "SELECT id, name, stock FROM products"'
```

Expected:

```
1|Keyboard|43
2|Mouse|220
```

## Scripting variables with `:setvar`

`:setvar` defines a variable that can be referenced as `$(VARNAME)` in the script. It works
in `-i` file mode and interactive mode, but **not** in `-Q` one-shots.

```bash
cat > /tmp/query.sql << 'EOF'
:setvar TABLENAME customers
SELECT TOP 3 name, email FROM $(TABLENAME) ORDER BY id;
GO
EOF
docker cp /tmp/query.sql mini-baas-mssql:/tmp/query.sql
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli -i /tmp/query.sql'
```

## Listing databases and tables

```bash
# All databases on the instance
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C \
   -Q "SELECT name FROM sys.databases ORDER BY name"'
```

Expected (this instance):

```
finance
learn_cli
master
model
msdb
tempdb
```

```bash
# Tables in the current database (two equivalent approaches)
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli \
   -Q "SELECT name, type_desc FROM sys.tables ORDER BY name"'

docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d learn_cli \
   -Q "SELECT TABLE_SCHEMA, TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE='"'"'BASE TABLE'"'"'"'
```

`sys.tables` is SQL-Server-specific and richer; `INFORMATION_SCHEMA.TABLES` is the ANSI-standard
view and more portable.

## Creating the scratch database

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C \
   -Q "CREATE DATABASE learn_cli"'
```

Once created, use `-d learn_cli` on every subsequent command to set the database context.
You can also run `USE learn_cli` as the first statement inside a batch.

## Cleanup

When you are finished with all the examples across this series, drop the scratch database:

```bash
docker exec mini-baas-mssql sh -lc \
  'sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C \
   -Q "DROP DATABASE learn_cli"'
```

## Gotchas / Docker notes

- `sh -lc '...'` loads a login shell, which ensures `$MSSQL_SA_PASSWORD` is in the environment.
  Without `-l`, the env var may be missing and you get an auth error.
- Interactive mode requires `-it` on `docker exec`. One-shot (`-Q`/`-i`) does not.
- `:setvar` and other scripting directives are `sqlcmd`-level, not T-SQL. They only apply
  in interactive or file-input (`-i`) mode. `-Q` ignores them (and the shell will error on
  `:setvar` before the query even reaches the server).
- `GO` is not T-SQL. It is not valid inside a stored procedure or function body.
  Inside such objects, separate statements with `;` only.

---

Next: [01-crud.md](01-crud.md) — CREATE TABLE, INSERT, SELECT, UPDATE, DELETE, MERGE
