# Connecting to MongoDB

`mongosh` is the official MongoDB shell. It is the only client present in the `mini-baas-mongo`
container — `mongodump`, `mongorestore`, and the legacy `mongo` binary are all absent.

---

## Why the auth flags are required

MongoDB in this stack runs with keyfile authentication enabled (replica-set mode). Every connection
must prove who it is before the server will respond. Three flags do that job:

| Flag | Purpose |
|------|---------|
| `-u "$MONGO_INITDB_ROOT_USERNAME"` | The username to authenticate as |
| `-p "$MONGO_INITDB_ROOT_PASSWORD"` | The password (resolved from container env, never hardcoded) |
| `--authenticationDatabase admin` | The database that holds the user record for the root account |

The `admin` database is the authority for all cross-database superuser accounts. Omitting
`--authenticationDatabase admin` causes an `Authentication failed` error even with correct
credentials, because `mongosh` defaults to authenticating against the *current* database, which is
not where the root user lives.

---

## Interactive shell

```bash
docker exec -it mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" \
           -p "$MONGO_INITDB_ROOT_PASSWORD" \
           --authenticationDatabase admin'
```

The `-it` flags attach a TTY so the shell prompt works. The `-lc` on `sh` makes it a login shell
so the container's environment variables (`MONGO_INITDB_ROOT_*`) are available.

Expected banner (abbreviated):

```
Current Mongosh Log ID: ...
Connecting to: mongodb://...@127.0.0.1:27017/?...
Using MongoDB: 7.0.37
Using Mongosh: 2.x.x
...
test>
```

The default database is `test`; it does not actually exist until you write to it.

---

## Shell basics

Once inside the interactive shell:

```js
// List all databases (only shows dbs with at least one collection)
show dbs
// activity    3.79 MiB
// admin      140.00 KiB
// ...

// Switch to your scratch database (created on first write)
use learn_cli
// switched to db learn_cli

// List collections in current database
show collections

// Check current database
db.getName()
// learn_cli

// Database statistics
db.stats()
// { db: 'learn_cli', collections: Long('0'), ... }

// Create data so learn_cli materialises
db.customers.insertOne({ name: "Alice", email: "alice@shop.dev", createdAt: new Date() })

// Now show dbs will include learn_cli
show dbs

// Iterate a cursor — mongosh shows 20 documents then pauses
// Type `it` to fetch the next batch
db.customers.find()
it

// Exit
exit
```

---

## One-shot `--eval`

Run a single expression without entering the interactive shell. Add `--quiet` to suppress the
connection banner.

```bash
# Check server version
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" \
           -p "$MONGO_INITDB_ROOT_PASSWORD" \
           --authenticationDatabase admin \
           --quiet --eval "db.version()"'
# 7.0.37

# Run a JS expression against a specific database
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" \
           -p "$MONGO_INITDB_ROOT_PASSWORD" \
           --authenticationDatabase admin \
           --quiet --eval "use(\"learn_cli\"); db.customers.countDocuments()"'
# 1
```

**Shell expansion warning** — inside a double-quoted `--eval "..."` string, the shell expands
`$var` and `$operator`. MongoDB query operators start with `$` (`$match`, `$gt`, etc.), so they
collide with shell variable expansion. Use one of these safe patterns:

- Use `--quiet ... file.js` (preferred for anything with operators — see next section).
- Wrap the eval value in single quotes (only works if you have no shell variables to expand):
  `--eval '...'` — but then you cannot embed `$MONGO_*` credential vars, so you would need a
  wrapper script.
- Escape each `$` as `\$` in a double-quoted string — fragile; avoid for complex queries.

---

## Running a `.js` file

For multi-line scripts or any query that contains `$` operators, write a `.js` file on the host,
copy it into the container with `docker cp`, then pass it directly to `mongosh`.

```bash
# 1. Write the script on the host
cat > /tmp/my_query.js << 'EOF'
use("learn_cli");

db.customers.insertMany([
  { name: "Alice", email: "alice@shop.dev", createdAt: new Date("2024-01-10") },
  { name: "Bob",   email: "bob@shop.dev",   createdAt: new Date("2024-02-05") }
]);

var results = db.customers.find(
  { createdAt: { $gt: new Date("2024-01-15") } },
  { name: 1, email: 1, _id: 0 }
).toArray();

print("Results:", JSON.stringify(results));
EOF

# 2. Copy into the container
docker cp /tmp/my_query.js mini-baas-mongo:/tmp/my_query.js

# 3. Run it
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" \
           -p "$MONGO_INITDB_ROOT_PASSWORD" \
           --authenticationDatabase admin \
           --quiet /tmp/my_query.js'
# Results: [{"name":"Bob","email":"bob@shop.dev"}]
```

The file is executed in order, top to bottom. `use("dbname")` inside a `.js` file switches the
active database exactly like typing it in the interactive shell.

---

## Scenario — materialising `learn_cli` and confirming it exists

```bash
# Step 1: create the scratch database with one document
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" \
           -p "$MONGO_INITDB_ROOT_PASSWORD" \
           --authenticationDatabase admin --quiet \
           --eval "use(\"learn_cli\"); db.customers.insertOne({name:\"test\"}); print(db.getName())"'
# learn_cli

# Step 2: confirm it shows in the list
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" \
           -p "$MONGO_INITDB_ROOT_PASSWORD" \
           --authenticationDatabase admin --quiet \
           --eval "db.adminCommand({listDatabases:1}).databases.map(d=>d.name).join(\", \")"'
# activity, admin, config, learn_cli, local, mini_baas, ...

# Step 3: cleanup
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" \
           -p "$MONGO_INITDB_ROOT_PASSWORD" \
           --authenticationDatabase admin --quiet \
           --eval "use(\"learn_cli\"); db.dropDatabase(); print(\"gone\")"'
# gone
```

---

## Gotchas / Docker notes

- `docker exec -it` requires a real TTY on the calling terminal. In CI or inside another script,
  drop `-it` and use `--eval` or a `.js` file instead.
- `sh -lc '...'` (not `sh -c '...'`) triggers a login shell so the container's entrypoint env
  vars (`MONGO_INITDB_ROOT_*`) are in scope. Without `-l`, those vars may be absent.
- `mongosh` does not expose a `--password-stdin` flag. The `-p` value is always on the command
  line; the env-var pattern here means it never appears in logs or history as a literal string.
- `--quiet` suppresses the connection banner but not `print()` output or errors. Leave it on for
  scripted use; drop it when you want version info in the banner.
- `use("dbname")` in a `.js` file vs `use dbname` in the interactive shell: both work; the
  function call form `use("...")` is required in `.js` files.

---

[README](README.md) | [01-crud.md](01-crud.md) | [02-indexes.md](02-indexes.md) |
[03-aggregation-views.md](03-aggregation-views.md) | [04-users-roles.md](04-users-roles.md) |
[05-security.md](05-security.md) | [06-backup-restore.md](06-backup-restore.md)
