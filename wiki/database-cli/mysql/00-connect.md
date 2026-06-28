# Connecting to MariaDB

Everything runs inside Docker — never `mariadb`/`mysql` directly on the host. The two connection styles are **interactive** (a live prompt) and **one-shot** (`-e` flag for scripted queries).

## Interactive session

```bash
docker exec -it mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'
```

The shell login (`sh -l`) ensures the container's environment is sourced so `$MARIADB_ROOT_PASSWORD` expands inside the container, not on the host. Remove `-it` and the `-i` from `docker exec` when running non-interactively from scripts.

Expected prompt:

```
Welcome to the MariaDB monitor.  Commands end with ; or \g.
MariaDB [(none)]>
```

### mini-baas-mysql equivalent

```bash
docker exec -it mini-baas-mysql sh -lc 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'
```

`mysql` prints a deprecation warning (`Deprecated program name. It will be removed in a future release, use '/usr/bin/mariadb' instead`) — this is harmless, just informational.

## One-shot queries with `-e`

```bash
# Single statement
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "SELECT VERSION();"'

# Target a specific database with the db name after options
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "SHOW TABLES;"'

# Multiple statements separated by semicolons
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
  CREATE DATABASE IF NOT EXISTS learn_cli;
  SHOW DATABASES;
"'
```

## Running a `.sql` file

Two approaches: pipe via stdin, or copy into the container first.

### Approach 1 — docker cp then redirect (recommended for large files)

```bash
# 1. Copy the file into the container
docker cp /path/to/schema.sql mini-baas-mariadb:/tmp/schema.sql

# 2. Execute it
docker exec mini-baas-mariadb sh -lc \
  'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli < /tmp/schema.sql'
```

### Approach 2 — pipe from host (simpler for small files)

```bash
docker exec -i mini-baas-mariadb sh -lc \
  'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli' \
  < /path/to/schema.sql
```

Note: use `-i` (not `-it`) on `docker exec` when piping — a pseudo-TTY (`-t`) breaks stdin redirection.

### source command (interactive mode only)

Inside an active session, `source` reads a file from inside the container:

```sql
-- Inside the interactive prompt, after copying the file in:
source /tmp/schema.sql
```

## Creating the learn_cli scratch database

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
  CREATE DATABASE IF NOT EXISTS learn_cli
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_general_ci;
"'
```

Expected output: (none — MariaDB is silent on success)

## Client meta-commands

These work inside the interactive prompt and cannot be passed via `-e`:

| Command | Meaning |
|---|---|
| `SHOW DATABASES;` | List all databases |
| `USE learn_cli;` | Switch to a database |
| `SHOW TABLES;` | List tables in current database |
| `DESCRIBE orders;` | Show columns and types of a table |
| `SHOW CREATE TABLE orders\G` | Full DDL for a table |
| `\s` | Server status (version, user, SSL, uptime) |
| `\G` | Re-display last result vertically (one field per line) |
| `\q` or `exit` | Quit |

`DESCRIBE` is a shortcut for `SHOW COLUMNS FROM`. Both work identically.

Example — `DESCRIBE` output:

```
Field        Type                                       Null  Key  Default  Extra
id           int(11)                                    NO    PRI  NULL     auto_increment
customer_id  int(11)                                    NO    MUL  NULL
product_id   int(11)                                    NO    MUL  NULL
qty          int(11)                                    NO         1
status       enum('pending','paid','shipped','cancelled') NO   MUL  pending
created_at   datetime                                   YES        current_timestamp()
```

## Output modes

### Vertical output with `\G`

Append `\G` instead of `;` at the end of a statement — or use it in `-e` strings:

```bash
docker exec mini-baas-mariadb sh -lc \
  'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -e "SELECT * FROM customers LIMIT 1\G"'
```

```
*************************** 1. row ***************************
        id: 1
      name: Alice Dupont
     email: alice@shop.example
created_at: 2026-06-28 10:26:32
```

### Batch mode `-B` (tab-separated, no box-drawing)

```bash
docker exec mini-baas-mariadb sh -lc \
  'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -B -e "SELECT name, email FROM customers;"'
```

```
name	email
Alice Dupont	alice@shop.example
Bob Martin	bob@shop.example
```

### Strip headers with `-N`

Combine `-B -N` for pure tab-separated values — ideal for piping into `awk`/`cut` on the host:

```bash
docker exec mini-baas-mariadb sh -lc \
  'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" learn_cli -B -N -e "SELECT name, email FROM customers LIMIT 2;"'
```

```
Alice Dupont	alice@shop.example
Bob Martin	bob@shop.example
```

## Scenario: verify the connection is TLS-encrypted

```bash
docker exec mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "\s"' | grep -E 'SSL|version'
```

Expected: `SSL: Cipher in use is TLS_AES_256_GCM_SHA384, cert is OK` — this container connects over a UNIX socket which MariaDB reports as TLS with a valid cert.

## Gotchas / Docker notes

- **Always use `sh -lc`**, not `sh -c`. The `-l` (login) flag loads the container's environment including `$MARIADB_ROOT_PASSWORD`. Without it the variable is empty and the connection is refused.
- **The password appears in the command string** — acceptable inside a container for learning, but in production use `--defaults-file` or `MYSQL_PWD` environment variable via `-e MYSQL_PWD=...` on `docker exec`.
- **`-it` vs `-i`**: use `-it` for interactive sessions (gives you a proper TTY with readline history), use just `-i` (or neither flag) for non-interactive/piped invocations. Mixing them incorrectly produces `the input device is not a TTY` errors.
- The `mysql` binary in `mini-baas-mariadb` is a compatibility symlink to `mariadb`. Prefer `mariadb` for new scripts.

---

Next: [01-crud.md](01-crud.md) — CREATE TABLE, INSERT, SELECT, UPDATE, DELETE, UPSERT
