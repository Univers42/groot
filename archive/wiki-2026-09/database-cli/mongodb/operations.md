# MongoDB Operations & Live-Data Inspection

The numbered files (00–06) teach MongoDB concepts against the `learn_cli` scratch database. This page
is the **operational** companion: how to connect, find where the real data lives, browse it safely,
and run the server/ops commands you reach for day to day — all against the running `mini-baas-mongo`
container (MongoDB 7.0.37).

Everything here is **read-only against the real databases**. For anything that writes, switch to
`learn_cli` first (see [00-connect.md](00-connect.md)) — never mutate `activity`, `mini_baas`,
`mini_baas_ai`, `mini_baas_analytics`, `admin`, `config`, or `local`.

---

## Connect (recap)

```bash
# Interactive
docker exec -it mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'
```

Three flags are mandatory — `-u`, `-p` (resolved from container env, never hardcoded), and
`--authenticationDatabase admin` (the root user lives in `admin`, not in your data db). Full
rationale and the `--eval` / `.js` patterns are in [00-connect.md](00-connect.md).

---

## Where the data actually lives

`mongosh` is *not* the only way in. There are two distinct services — target the right one:

| Target | What it is | Use it for |
|--------|------------|------------|
| `mini-baas-mongo` | the **datastore** (mongod) | raw CLI browsing — everything on this page |
| `mini-baas-mongo-api` | an HTTP **API layer** over Mongo | app traffic, not direct queries |

For CLI inspection always `docker exec` into **`mini-baas-mongo`**.

### What each database holds in this stack

```bash
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
   --authenticationDatabase admin --quiet \
   --eval "db.adminCommand({listDatabases:1}).databases.forEach(d => print(d.name.padEnd(22) + (d.sizeOnDisk/1048576).toFixed(1) + \" MiB\"))"'
```

| Database | Holds | Notes |
|----------|-------|-------|
| `activity` | **the real seeded data** | `product_reviews` (8000), `events` (30000), `notes` (400) |
| `mini_baas` | — | empty auto-shell from `MONGO_DB_NAME` env var; **not** where data lands |
| `mini_baas_ai` | — | empty auto-shell (`AI_MONGO_DB`) |
| `mini_baas_analytics` | — | empty auto-shell (`ANALYTICS_MONGO_DB`) |
| `admin` / `config` / `local` | server internals | never touch |

> The `mini_baas*` databases are the Mongo equivalent of the empty `mini_baas` shell on the SQL
> engines — created by the container from a `*_DB` env var, never populated. The actual records are
> in **`activity`**. Always `show dbs` / list databases before assuming where data is.

The `activity` documents all carry `tenant_id: "agency"` and `owner_id: "api-key:827ad2d7…"` — this
is the **agency-simulation** dataset (`make agency-all`), not the osionos account (that's in Postgres).

---

## Navigate — the `SHOW DATABASES` / `SHOW TABLES` equivalents

Inside the interactive shell:

```js
show dbs                         // list databases (only non-empty ones appear)
use activity                     // switch db (lazily created on first write)
db                               // current db name
show collections                 // list collections          (≈ SHOW TABLES)
db.product_reviews.countDocuments()   // row count             (≈ SELECT count(*))
db.product_reviews.findOne()          // one doc — see the shape (≈ SELECT * LIMIT 1)
db.product_reviews.getIndexes()       // indexes on a collection (≈ SHOW INDEX)
```

`findOne()` is the fastest way to learn an unfamiliar collection's structure:

```js
use activity
db.product_reviews.findOne()
// {
//   _id: 'rev-00001', product_ref: 117, customer_ref: 3128, rating: 5,
//   title: 'F1782642345617', body: 'Battery life is shorter than advertised.',
//   verified: true, helpful_votes: 32, reviewed_at: ISODate('2025-10-03T21:03:19.721Z'),
//   owner_id: 'api-key:827ad2d7-b516-4e5e-ae5e-81d30136430f', tenant_id: 'agency'
// }
```

---

## Read data — `find()` is your `SELECT`

```js
use activity

db.product_reviews.find().pretty()                     // all docs (type `it` for next page)
db.product_reviews.find({ rating: 5 })                 // WHERE rating = 5
db.product_reviews.find({ rating: { $gte: 4 }, verified: true })  // AND
db.product_reviews.find({ rating: 5 }, { title: 1, rating: 1, _id: 0 })  // projection
db.product_reviews.find().sort({ helpful_votes: -1 }).limit(5)   // ORDER BY … LIMIT
db.product_reviews.countDocuments({ verified: true })  // filtered count
db.product_reviews.distinct("rating")                  // SELECT DISTINCT
```

### SQL → Mongo operator map

| SQL | Mongo |
|-----|-------|
| `col = v` | `{ col: v }` |
| `>` `>=` `<` `<=` | `$gt` `$gte` `$lt` `$lte` |
| `!=` | `$ne` |
| `IN (a,b)` | `{ col: { $in: [a,b] } }` |
| `LIKE 'foo%'` | `{ col: /^foo/ }` (regex) |
| `AND` | comma-separate keys (or `$and`) |
| `OR` | `{ $or: [ {…}, {…} ] }` |
| `IS NULL` | `{ col: null }` |
| `ORDER BY c ASC/DESC` | `.sort({ c: 1 })` / `.sort({ c: -1 })` |
| `LIMIT n` / `OFFSET m` | `.limit(n)` / `.skip(m)` |
| `COUNT(*)` | `.countDocuments()` |
| `DISTINCT c` | `.distinct("c")` |

### GROUP BY → aggregation pipeline

```js
// avg rating per product, top 10   (SELECT product_ref, AVG(rating) … GROUP BY … ORDER BY … LIMIT)
db.product_reviews.aggregate([
  { $group: { _id: "$product_ref", avgRating: { $avg: "$rating" }, n: { $sum: 1 } } },
  { $sort: { avgRating: -1 } },
  { $limit: 10 }
])

// count reviews per rating value   (histogram)
db.product_reviews.aggregate([
  { $group: { _id: "$rating", count: { $sum: 1 } } },
  { $sort: { _id: 1 } }
])
```

Full pipeline reference (`$match`, `$lookup` joins, `$unwind`, views, `$out`) is in
[03-aggregation-views.md](03-aggregation-views.md).

---

## One-shot queries from the host (`--eval`)

For scripting without entering the shell. Pass the **db name positionally** before `--eval` so `db`
points at it, and use `.toArray()` so a cursor actually prints in non-interactive mode:

```bash
# count
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
   --authenticationDatabase admin --quiet activity \
   --eval "db.product_reviews.countDocuments({rating:5})"'

# top-3 most helpful, as JSON
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
   --authenticationDatabase admin --quiet activity \
   --eval "db.product_reviews.find({},{title:1,helpful_votes:1,_id:0}).sort({helpful_votes:-1}).limit(3).toArray()"'
```

> **`$`-expansion trap:** inside a double-quoted `--eval "…"` the host shell eats `$match`, `$gt`,
> etc. as shell variables. For any query containing `$` operators (most aggregations), put it in a
> `.js` file and run that instead — see the [.js file pattern in 00-connect.md](00-connect.md). Append
> `| grep -viE 'deprecat|experimental'` to drop harmless mongosh notices.

---

## Server & operations commands

```js
// --- sizing ---
db.stats()                          // current db: size, collections, indexes, objects
db.product_reviews.stats()          // one collection: storageSize, count, avgObjSize, indexSizes
db.adminCommand({ listDatabases: 1 })   // every db + sizeOnDisk

// --- health / runtime ---
db.adminCommand({ serverStatus: 1 })    // connections, opcounters, mem, uptime, network
db.serverStatus().connections           // just the connection counts
db.hello()                              // replica-set role (isWritablePrimary, setName, hosts)
rs.status()                             // replica-set members & health (this stack runs as a RS)

// --- live activity ---
db.currentOp()                          // in-flight operations (find the slow one)
db.currentOp({ "secs_running": { $gte: 3 } })   // ops running ≥ 3s
db.killOp(<opid>)                       // kill a runaway op by its opid

// --- per-collection inventory of a db ---
db.getCollectionNames().forEach(c => print(c.padEnd(20) + db[c].countDocuments()))
```

Handy one-shot — full inventory of every non-system db and its collection counts:

```bash
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
   --authenticationDatabase admin --quiet --eval "
     db.adminCommand({listDatabases:1}).databases
       .filter(d => ![\"admin\",\"config\",\"local\"].includes(d.name))
       .forEach(d => {
         const x = db.getSiblingDB(d.name);
         x.getCollectionNames().forEach(c => print(d.name + \".\" + c + \"  \" + x[c].countDocuments()));
       });
   "' 2>&1 | grep -viE 'deprecat|experimental'
```

---

## Performance — read the query plan

```js
// Is a query using an index or scanning the whole collection?
db.product_reviews.find({ rating: 5 }).explain("executionStats")
// look at: winningPlan.stage  (IXSCAN = index used, COLLSCAN = full scan)
//          executionStats.totalDocsExamined  vs  nReturned
```

A `COLLSCAN` on a large collection (e.g. `events`, 30k docs) is the signal to add an index — see
[02-indexes.md](02-indexes.md).

---

## Gotchas / Docker notes

- **`sh -lc`, not `sh -c`** — the login shell sources the container env so `$MONGO_INITDB_ROOT_*`
  expand inside the container.
- **`-it` only for interactive** — drop it in CI/scripts and use `--eval` or a `.js` file, else you
  hit `the input device is not a TTY`.
- **`mongodump`/`mongorestore` are absent** from this image — use a `mongo:7` sidecar on the
  `mini-baas_mini-baas` network ([06-backup-restore.md](06-backup-restore.md)).
- **Row estimates can lie** — for an exact count always use `countDocuments()` (a true count), not
  `estimatedDocumentCount()` (metadata estimate).
- **Reads are safe; writes are not** — every example here reads. Any insert/update/delete must target
  `learn_cli`, never the live databases.

---

[README](README.md) | [00-connect.md](00-connect.md) | [01-crud.md](01-crud.md) |
[02-indexes.md](02-indexes.md) | [03-aggregation-views.md](03-aggregation-views.md) |
[04-users-roles.md](04-users-roles.md) | [05-security.md](05-security.md) |
[06-backup-restore.md](06-backup-restore.md)
</content>
</invoke>
