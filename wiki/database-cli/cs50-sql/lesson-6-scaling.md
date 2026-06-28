# Lesson 6 — Scaling (CS50 SQL)

At some point a single SQLite file is no longer enough. Traffic grows, concurrent writers
collide, and the database needs to live on its own machine so multiple application servers
can share it. Lecture 6 traces that journey: why it happens, what MySQL and PostgreSQL
offer that SQLite does not, and what new responsibilities — replication, access control,
injection defense — come with running a networked server.

Our Docker stack lives exactly at this boundary: every `mini-baas-mariadb` and
`mini-baas-postgres` container is a production-grade server engine that the frontends reach
over the `mini-baas_mini-baas` bridge network, while SQLite still appears in lighter tooling
and in the CS50 problem sets as a learning baseline.

## What you'll learn

- The architectural gap between an embedded file-based engine and a networked database server
- MySQL/MariaDB type system, DDL extensions, and the `SHOW`/`DESCRIBE` workflow
- Writing and calling stored procedures, including the delimiter problem
- PostgreSQL's equivalent type system and the `psql` meta-command toolkit
- Vertical vs horizontal scaling, single-leader replication, sharding, and their trade-offs
- Creating users and granting least-privilege access
- SQL injection — why naive string concatenation is dangerous and how prepared statements
  close the hole

---

## Why scale at all?

A well-tuned SQLite database can serve thousands of reads per second from a single file.
What it cannot do is handle concurrent writers without serializing them through a single
operating-system lock, or hand off work to a second machine without copying the whole file.
Once your shop's order volume outpaces what one process on one disk can absorb, you need a
server — a long-running process that speaks a network protocol, manages its own connection
pool, and can be reached by many application processes simultaneously.

That shift involves two things: choosing a server engine and rethinking how you think about
the database. It is no longer a file you open; it is a service you connect to.

### SQLite vs MySQL/PostgreSQL at a glance

| Dimension | SQLite | MySQL / PostgreSQL |
|---|---|---|
| Process model | In-process library | Separate server daemon |
| Concurrency | Serialized writes | Row/page-level locking, MVCC |
| Network access | No | Yes — host:port |
| Authentication | OS file permissions | Username + password + grants |
| DDL transactions | Partial | Full (Postgres) / limited (MySQL) |
| Typical use | Embedded, dev, mobile | Production web workloads |

---

## MySQL essentials

MySQL (and its drop-in fork MariaDB, which our stack ships) adds a richer type vocabulary and
several DDL conveniences that SQLite deliberately omits.

### Connecting to our MariaDB container

```bash
docker exec -it mini-baas-mariadb sh -lc 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'
```

The shell expansion happens inside the container so the password never appears on the host
command line.

### Auto-increment and unsigned integers

When you need a surrogate primary key that the server mints for you, MySQL uses
`AUTO_INCREMENT`. The `UNSIGNED` modifier doubles the positive range of an integer column
by dropping the sign bit — useful for IDs that will never be negative.

```sql
CREATE TABLE customers (
    id         INT UNSIGNED NOT NULL AUTO_INCREMENT,
    name       VARCHAR(120) NOT NULL,
    email      VARCHAR(255) NOT NULL UNIQUE,
    created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
);

CREATE TABLE products (
    id          INT UNSIGNED  NOT NULL AUTO_INCREMENT,
    name        VARCHAR(200)  NOT NULL,
    price_cents INT UNSIGNED  NOT NULL,
    stock       SMALLINT      NOT NULL DEFAULT 0,
    PRIMARY KEY (id)
);

CREATE TABLE orders (
    id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    customer_id INT UNSIGNED    NOT NULL,
    product_id  INT UNSIGNED    NOT NULL,
    qty         TINYINT         NOT NULL DEFAULT 1,
    status      ENUM('pending','paid','shipped','cancelled') NOT NULL DEFAULT 'pending',
    created_at  TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    FOREIGN KEY (customer_id) REFERENCES customers(id),
    FOREIGN KEY (product_id)  REFERENCES products(id)
);
```

### MySQL numeric types

| Type | Storage | Unsigned max |
|---|---|---|
| `TINYINT` | 1 byte | 255 |
| `SMALLINT` | 2 bytes | 65 535 |
| `INT` | 4 bytes | ~4.3 billion |
| `BIGINT` | 8 bytes | ~18.4 × 10¹⁸ |
| `DECIMAL(p,s)` | variable | exact; use for money |

For currency, prefer `DECIMAL(10,2)` or store an integer number of cents (`INT UNSIGNED`)
and divide in application code — floating-point types introduce rounding errors in financial
sums.

### String and text types

`CHAR(n)` pads to a fixed width; `VARCHAR(n)` stores only what you write plus a one- or
two-byte length prefix. `TEXT` holds up to 65 535 bytes and cannot have a default; `BLOB`
is the binary equivalent. For small controlled vocabularies, `ENUM('a','b','c')` enforces
the set at the storage layer and uses a single byte on disk. `SET` is similar but allows
multiple values per row.

`DATETIME` stores a literal date-and-time with no timezone awareness.
`TIMESTAMP` is stored as UTC and converted to the session timezone on retrieval — nearly
always the right choice for `created_at` and `updated_at` columns.

### Schema inspection commands

```sql
SHOW DATABASES;          -- list every database the server knows about
USE shop;                -- switch to the shop database
SHOW TABLES;             -- list tables in the current database
DESCRIBE orders;         -- column names, types, nullability, keys, defaults
```

### ALTER TABLE … MODIFY

After the fact, you can change a column's type without recreating the table:

```sql
-- Expand the name column from 120 to 200 characters
ALTER TABLE customers MODIFY name VARCHAR(200) NOT NULL;

-- Change stock from SMALLINT to INT to handle larger warehouses
ALTER TABLE products MODIFY stock INT NOT NULL DEFAULT 0;
```

`MODIFY` replaces the full column definition. Shrinking a column or changing its type can
silently truncate data, so always check the current values first.

---

## Stored procedures in MySQL

A stored procedure is SQL logic that lives inside the database server itself. You call it by
name from any client, the server runs it atomically in the engine process, and the client
receives only the result. This keeps business logic close to the data and reduces round-trips.

### The delimiter problem

MySQL's command-line client uses `;` to detect the end of a statement and send it. A
procedure body contains semicolons too, which would confuse the client into sending an
incomplete fragment. The solution is to temporarily change the statement terminator:

```sql
DELIMITER $$

CREATE PROCEDURE place_order(
    IN p_customer_id INT UNSIGNED,
    IN p_product_id  INT UNSIGNED,
    IN p_qty         TINYINT
)
BEGIN
    -- Guard: refuse if not enough stock
    IF (SELECT stock FROM products WHERE id = p_product_id) < p_qty THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Insufficient stock';
    END IF;

    INSERT INTO orders (customer_id, product_id, qty, status)
    VALUES (p_customer_id, p_product_id, p_qty, 'pending');

    UPDATE products
    SET stock = stock - p_qty
    WHERE id = p_product_id;
END$$

DELIMITER ;
```

`DELIMITER $$` tells the client to wait for `$$` before sending; `DELIMITER ;` restores
normal behaviour. The `BEGIN … END` block can contain multiple statements, conditionals
(`IF`/`ELSE`), loops, and local variables (`DECLARE`).

### Calling a procedure

```sql
-- Place 3 units of product 7 for customer 42
CALL place_order(42, 7, 3);
```

Parameters flow in as `IN`, out as `OUT`, or both ways as `INOUT`. Here only input is
needed, so all three are `IN`.

---

## PostgreSQL essentials

PostgreSQL has the same relational core as MySQL but a different type vocabulary, stricter
standard-SQL adherence, and a distinct command-line client, `psql`.

### Connecting to our Postgres container

```bash
docker exec -it mini-baas-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

### Type system

| Postgres type | MySQL rough equivalent | Notes |
|---|---|---|
| `SMALLINT` | `SMALLINT` | 2 bytes |
| `INTEGER` | `INT` | 4 bytes |
| `BIGINT` | `BIGINT` | 8 bytes |
| `SERIAL` | `INT AUTO_INCREMENT` | auto-incrementing integer; `BIGSERIAL` for 8-byte |
| `NUMERIC(p,s)` | `DECIMAL(p,s)` | exact decimal |
| `VARCHAR(n)` | `VARCHAR(n)` | variable-length string |
| `TEXT` | `TEXT` | unlimited-length string; has a default |
| `TIMESTAMP` | `DATETIME` | no timezone |
| `TIMESTAMPTZ` | — | with timezone (stored UTC) |

### Enums the Postgres way

Postgres enums are user-defined types, not inline column attributes:

```sql
CREATE TYPE order_status AS ENUM ('pending', 'paid', 'shipped', 'cancelled');

CREATE TABLE orders (
    id          BIGSERIAL    NOT NULL,
    customer_id INTEGER      NOT NULL REFERENCES customers(id),
    product_id  INTEGER      NOT NULL REFERENCES products(id),
    qty         SMALLINT     NOT NULL DEFAULT 1,
    status      order_status NOT NULL DEFAULT 'pending',
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (id)
);
```

`now()` returns the current transaction timestamp, which is the Postgres idiom for the same
default you would write as `CURRENT_TIMESTAMP` in standard SQL.

### psql meta-commands

`psql` has backslash commands that are interpreted by the client, not sent to the server:

```
\l          -- list databases (analogous to SHOW DATABASES in MySQL)
\c shop     -- connect to the "shop" database
\dt         -- list tables in the current schema
\d orders   -- describe the orders table (columns, types, indexes, constraints)
\q          -- quit psql
```

These are not SQL, so they do not need a semicolon.

---

## Scaling with replication

Once a single server cannot absorb the load, you have two levers: make the server bigger
or add more servers.

**Vertical scaling** means buying more CPU, RAM, and faster disks for the existing machine.
It is simple to operate — no topology changes, no synchronization code — but it hits a
physical ceiling, and doubling the hardware often more than doubles the price.

**Horizontal scaling** means adding more machines. For databases the dominant pattern is
**replication**: keeping identical copies of the data on multiple servers so that reads can
be distributed.

### Single-leader replication

In the most common topology one server is the **leader** (also called primary or master).
All writes go to the leader. The leader streams its write-ahead log to one or more
**replicas** (also called secondaries or read replicas). Applications that only read data —
analytics queries, reporting, search — can be pointed at a replica, leaving the leader free
for writes.

```
              ┌──────────────────────────┐
  writes ───► │  Leader (read+write)     │
              └────────────┬─────────────┘
                           │ log stream
             ┌─────────────┼─────────────┐
             ▼             ▼             ▼
         Replica 1     Replica 2     Replica 3
         (read only)   (read only)   (read only)
```

In our stack every frontend that reads customer order history could theoretically hit a
replica, while the checkout path that inserts new orders always hits the primary.

### Synchronous vs asynchronous replication

With **synchronous replication** the leader waits for at least one replica to confirm it
has written the data before acknowledging the write to the client. This guarantees no data
loss if the leader crashes immediately after the write, but it adds the replica's round-trip
latency to every write.

With **asynchronous replication** the leader acknowledges the write as soon as it hits
local disk and propagates to replicas in the background. Writes are faster, but a leader
crash can lose the last few milliseconds of commits that were not yet replicated.

Most production deployments use asynchronous replication for performance and accept a small
replication lag, then promote a replica manually (or automatically with a health-check agent)
if the leader fails.

### Sharding

Replication copies the entire dataset to each node. **Sharding** partitions the dataset: a
different subset of rows lives on each shard. A common partition key for an orders table
would be customer ID, so all orders for customers 1–100 000 go to shard A, customers
100 001–200 000 to shard B, and so on.

Sharding scales writes horizontally because each shard has its own leader. The cost is
complexity: queries that cross shard boundaries require the application to fan out and
merge, and transactions spanning two shards need distributed coordination.

### Hotspots

A **hotspot** occurs when a partition key is poorly chosen and most traffic concentrates on
one shard. If you shard orders by the first letter of the product name and 40 % of your
products start with "A", shard A is perpetually overloaded while others sit idle. Choosing
a uniform partition key — often a hash of the primary key rather than the key itself — is
the standard mitigation.

### Single point of failure

A single leader is a **single point of failure** for writes. If the leader goes down and
promotion is manual, writes are unavailable until an operator intervenes. Managed databases
(Amazon RDS Multi-AZ, Google Cloud SQL, CockroachDB) automate failover so a replica becomes
the new leader within seconds, but the fundamental trade-off between write availability and
consistency is unchanged.

---

## Access controls

Running a database server means the database is reachable over the network. Anyone who can
reach the port and knows a valid credential can read or destroy your data. Access control
is not optional.

### Creating users in MySQL/MariaDB

```sql
-- Create an application user restricted to the shop database
CREATE USER 'shop_app'@'%' IDENTIFIED BY 'str0ng-r@ndom-secret';

-- Grant exactly what the application needs: SELECT, INSERT, UPDATE on orders
GRANT SELECT, INSERT, UPDATE ON shop.orders    TO 'shop_app'@'%';
GRANT SELECT                  ON shop.products  TO 'shop_app'@'%';
GRANT SELECT                  ON shop.customers TO 'shop_app'@'%';

-- Make the grants effective immediately
FLUSH PRIVILEGES;
```

`'%'` matches any host; in a real deployment replace it with the application server's
IP or hostname to limit the attack surface further.

### Least privilege

The principle of **least privilege** says a user should hold only the permissions required
for its exact role. The `shop_app` user above can read products and customers and can
write orders — it cannot drop tables, create new users, or touch any other database.
If an attacker compromises the application, the blast radius is limited to what
`shop_app` can do.

The complementary principle for DDL is to create a separate **migration user** that holds
`CREATE`, `ALTER`, and `DROP` rights, run it only during deployments, and never embed those
credentials in the long-running application process.

For PostgreSQL the same ideas apply through `GRANT` and `REVOKE`; see the wiki cross-references
at the bottom of this file.

---

## SQL injection and prepared statements

The most persistently dangerous database vulnerability is not a bug in the engine — it is
what the application does when assembling queries from user-supplied input.

### The vulnerable pattern

Imagine the order-lookup endpoint for our shop builds a query by concatenating a string
the client sends:

```sql
-- Application code (pseudocode) — NEVER DO THIS
query = "SELECT * FROM orders WHERE customer_id = " + user_input;
```

If `user_input` is `42` the query is harmless. If an attacker sends `42 OR 1=1` the
resulting query is:

```sql
SELECT * FROM orders WHERE customer_id = 42 OR 1=1;
```

`1=1` is always true, so every order in the table is returned. A more destructive payload:

```
42; DROP TABLE orders; --
```

produces:

```sql
SELECT * FROM orders WHERE customer_id = 42;
DROP TABLE orders;
-- (rest of original query commented out)
```

Now the orders table is gone. This class of attack is **SQL injection** and it is the root
cause of countless data breaches, because so many applications have been written with
concatenated SQL.

### Prepared statements close the hole

A **prepared statement** (also called a parameterized query) separates the SQL structure
from the data values. The server parses and compiles the query template once with
placeholders, then executes it many times with different bound values. User input is
treated as a data value — never as SQL syntax — so no amount of quotes, semicolons, or
SQL keywords in the input can alter the query's structure.

**MySQL/MariaDB — PREPARE / EXECUTE / USING:**

```sql
-- Prepare the template (? is a placeholder)
PREPARE fetch_orders FROM
    'SELECT id, product_id, qty, status
     FROM orders
     WHERE customer_id = ?';

-- Bind and execute: the value goes through USING, not into the SQL text
SET @cid = 42;
EXECUTE fetch_orders USING @cid;

-- Reuse with a different value
SET @cid = 99;
EXECUTE fetch_orders USING @cid;

-- Clean up
DEALLOCATE PREPARE fetch_orders;
```

The `?` placeholder can hold any scalar value. Whatever the client passes in — even a
string full of SQL metacharacters — the engine treats it as a literal value to compare
against the column. The structure of the query is already fixed.

**PostgreSQL — PREPARE / EXECUTE:**

```sql
PREPARE fetch_orders(integer) AS
    SELECT id, product_id, qty, status
    FROM orders
    WHERE customer_id = $1;

EXECUTE fetch_orders(42);
EXECUTE fetch_orders(99);

DEALLOCATE fetch_orders;
```

Postgres uses `$1`, `$2`, … for positional parameters; the type is declared in the
`PREPARE` signature.

**The rule:** every piece of user-supplied or externally-derived data that goes into a
query must travel through a parameter placeholder, never through string concatenation. This
applies equally whether you write SQL by hand or use an ORM — most ORMs parameterize by
default, but raw query escape hatches reintroduce the risk.

---

## SQLite → server migration framing

When the shop schema moves from a SQLite prototype to our Docker stack, the structural
SQL stays almost identical — the tables, foreign keys, and indexes are portable. What
changes:

1. **Connection string** — from a file path to `mysql://shop_app:…@mini-baas-mariadb:3306/shop`
   or `postgresql://shop_app:…@mini-baas-postgres:5432/shop`.
2. **Types** — SQLite's dynamic affinity yields to strict types; `INTEGER` becomes
   `INT UNSIGNED AUTO_INCREMENT` in MariaDB or `SERIAL` in Postgres.
3. **Auth** — a new database user with least-privilege grants replaces file-system
   permissions.
4. **Replication config** — the `mini-baas` compose project can expose replica containers;
   point analytics queries there.
5. **Application code** — replace any concatenated SQL with parameterized queries.

The migration itself is the subject of `DATA-MIGRATION.md` at the repo root.

---

## CS50 specifics

The datasets CS50 uses in Lecture 6 to motivate scaling:
- **MBTA** — Boston subway ridership, large enough to stress single-server SQLite
- **MFA** — Museum of Fine Arts Boston collection
- **Rideshare** — trip-level data across multiple cities
- **Bank** — account and transaction records used in the access-control examples

The tools used in lecture:
- **MySQL** (or MariaDB) for the server-side DDL, stored procedures, and user-management
  demonstrations
- **PostgreSQL** + `psql` for the enum, `SERIAL`, and `now()` walkthroughs
- **SQLite** retained as the baseline to contrast with server engines

---

## Maps to your wiki

The topics in this lesson have dedicated guides in the wiki:

- [mysql/](../mysql/README.md) — MariaDB connect, CRUD, DDL overview
- [mysql/04-users](../mysql/04-users.md) — `CREATE USER`, `GRANT`, `REVOKE`
- [mysql/06-security](../mysql/06-security.md) — injection, prepared statements, audit log
- [postgres/](../postgres/README.md) — Postgres connect, type system, psql tour
- [postgres/05-permissions-grants](../postgres/05-permissions-grants.md) — roles, `GRANT`, RLS
- [postgres/06-security-rls](../postgres/06-security-rls.md) — row-level security policies

---

## Key takeaways

- SQLite is excellent for development and embedded workloads; production web workloads
  need a server engine that handles concurrent writes and network clients.
- MySQL's `AUTO_INCREMENT`, `UNSIGNED`, `ENUM`, and `TIMESTAMP` cover most production
  schema needs; `SHOW`/`DESCRIBE` are the quickest inspection tools.
- Stored procedures encapsulate multi-statement logic server-side; the delimiter trick
  (`DELIMITER $$`) is mandatory in the MySQL CLI.
- PostgreSQL's `SERIAL`, `TIMESTAMPTZ`, `now()`, and user-defined `ENUM` types deliver
  the same outcomes with stricter type semantics; `\d tablename` replaces `DESCRIBE`.
- Horizontal scaling via replication means one leader accepts writes while read replicas
  distribute query load; synchronous replication trades latency for durability.
- Sharding partitions rows across nodes to scale writes, but poor key choice creates hotspots.
- Access control is not optional on a networked server: create per-role users, grant only
  what each role needs, and never embed DDL-level credentials in application processes.
- SQL injection exploits string concatenation; prepared statements with `?` / `$1`
  placeholders eliminate the vulnerability by separating SQL structure from data values.

---

> **Source & license.** Original study notes following *CS50's Introduction to Databases with SQL*, Lecture 6 — Scaling (<https://cs50.harvard.edu/sql/notes/6/>). Course materials © President and Fellows of Harvard College, licensed [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/). These notes are an original summary in our own words; see the source for the canonical lecture.
