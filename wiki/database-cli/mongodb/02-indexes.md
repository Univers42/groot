# Indexes

Without an index, every query scans every document in the collection — a **collection scan**. An
index is a pre-sorted data structure that lets MongoDB jump straight to the matching documents.
MongoDB always creates a unique index on `_id` automatically; every other index is explicit.

---

## Creating indexes

### Single-field index

```js
// in a .js file
use("learn_cli");

// Ascending index on email
db.customers.createIndex({ email: 1 })

// Descending is less common for single fields but valid
db.products.createIndex({ priceCents: -1 })
```

`1` = ascending, `-1` = descending. For a single field the direction only matters when you combine
it with a compound index.

### Compound index

```js
// Supports queries that filter on name AND/OR sort on createdAt
db.customers.createIndex({ name: 1, createdAt: -1 })
```

A compound index covers queries that use a **prefix** of the key list. The index above covers
`{ name: ... }` and `{ name: ..., createdAt: ... }` but not `{ createdAt: ... }` alone.

### Unique index

```js
db.customers.createIndex(
  { email: 1 },
  { unique: true, name: "idx_email_unique" }
)
```

Attempting to insert a second document with the same `email` raises a duplicate-key error. Giving
the index a name (the `name` option) makes it easy to reference later in `dropIndex`.

### TTL index — automatic document expiry

A TTL (Time To Live) index tells MongoDB to delete documents automatically once a Date field is
older than `expireAfterSeconds`.

```js
// Sessions expire after 1 hour (3600 seconds)
db.sessions.createIndex(
  { createdAt: 1 },
  { expireAfterSeconds: 3600, name: "idx_sessions_ttl" }
)
```

Requirements:
- The field must be a BSON Date (not a string).
- A background task runs roughly once per minute, so expiry is eventual, not exact.
- TTL indexes cannot be compound.

### Text index

```js
// Full-text search on product name
db.products.createIndex(
  { name: "text" },
  { name: "idx_products_text" }
)

// Query with $text — must use a .js file
var hits = db.products.find(
  { $text: { $search: "keyboard" } },
  { score: { $meta: "textScore" }, name: 1, _id: 0 }
).sort({ score: { $meta: "textScore" } }).toArray();
print(JSON.stringify(hits));
// → [{"name":"Gaming Keyboard","score":0.75}]
```

Only one text index is allowed per collection. It can cover multiple fields:
`{ name: "text", description: "text" }`.

### Partial index

Indexes only the subset of documents that match a filter expression. Smaller and faster than a
full index on the field.

```js
// Index only pending orders — saves space, speeds up the pending queue query
db.orders.createIndex(
  { createdAt: -1 },
  {
    partialFilterExpression: { status: "pending" },
    name: "idx_orders_pending_created"
  }
)
```

A query must include the same filter (or a subset) to be eligible to use a partial index.

---

## Listing indexes

```js
db.customers.getIndexes()
// [
//   { key: { _id: 1 },    name: "_id_" },
//   { key: { email: 1 },  name: "idx_email_unique", unique: true },
//   { key: { name: 1, createdAt: -1 }, name: "name_1_createdAt_-1" }
// ]
```

---

## Dropping an index

```js
// By name (preferred — unambiguous)
db.customers.dropIndex("idx_email_unique")

// By key specification (matches the exact key object)
db.customers.dropIndex({ email: 1 })

// You cannot drop the _id index
```

---

## `explain` — understanding query execution

`explain("executionStats")` shows whether MongoDB used an index (`IXSCAN`) or had to scan all
documents (`COLLSCAN`), plus how many keys and documents it examined.

```js
var plan = db.customers.find({ email: "alice@shop.dev" }).explain("executionStats");

print("winning plan stage:", plan.queryPlanner.winningPlan.stage);
// FETCH  (found via index, then fetched document)

print("keys examined:", plan.executionStats.totalKeysExamined);
// 1  (only one index entry checked)

print("docs examined:", plan.executionStats.totalDocsExamined);
// 1  (only one document fetched)
```

A `COLLSCAN` with `totalDocsExamined` in the thousands for a small result set is a sign you need
an index. A `FETCH` on top of an `IXSCAN` is the normal, efficient pattern.

---

## Scenario — unique email and TTL sessions for a shop

```bash
cat > /tmp/index_scenario.js << 'EOF'
use("learn_cli");
db.customers.drop();
db.sessions.drop();

// Unique email index
db.customers.createIndex({ email: 1 }, { unique: true, name: "idx_email_unique" });

db.customers.insertOne({ name: "Alice", email: "alice@shop.dev", createdAt: new Date() });

// This should throw a duplicate-key error:
try {
  db.customers.insertOne({ name: "Alice2", email: "alice@shop.dev", createdAt: new Date() });
} catch (e) {
  print("duplicate key caught:", e.codeName);  // DuplicateKey
}

// TTL on sessions
db.sessions.createIndex(
  { createdAt: 1 },
  { expireAfterSeconds: 3600, name: "idx_sessions_ttl" }
);

db.sessions.insertOne({
  userId:    db.customers.findOne({name:"Alice"})._id,
  token:     "tok_abc123",
  createdAt: new Date()
});

// Confirm indexes
var cidx = db.customers.getIndexes().map(i => i.name);
print("customer indexes:", JSON.stringify(cidx));
// ["_id_","idx_email_unique"]

var sidx = db.sessions.getIndexes().map(i => i.name + (i.expireAfterSeconds ? " TTL:"+i.expireAfterSeconds : ""));
print("session indexes:", JSON.stringify(sidx));
// ["_id_","idx_sessions_ttl TTL:3600"]

// Explain the email lookup
var exp = db.customers.find({ email: "alice@shop.dev" }).explain("executionStats");
print("plan stage:", exp.queryPlanner.winningPlan.stage);
print("keys examined:", exp.executionStats.totalKeysExamined);

// Cleanup
db.dropDatabase();
print("done");
EOF
docker cp /tmp/index_scenario.js mini-baas-mongo:/tmp/index_scenario.js
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
   --authenticationDatabase admin --quiet /tmp/index_scenario.js'
```

Expected output:

```
duplicate key caught: DuplicateKey
customer indexes: ["_id_","idx_email_unique"]
session indexes: ["_id_","idx_sessions_ttl TTL:3600"]
plan stage: FETCH
keys examined: 1
done
```

---

## Gotchas / Docker notes

- **Index builds block writes in MongoDB 7 by default** for small collections. For large production
  collections use `{ background: true }` (deprecated in 4.2+; see `createIndex` docs for the
  newer `commitQuorum` option). In `learn_cli` with tiny collections it is instantaneous.
- **Text index limitation** — only one text index per collection. If you need to search multiple
  collections, build a separate text index on each.
- **Partial indexes and query planning** — if your query filter doesn't include the partial filter
  expression exactly, the planner won't use the index. Run `explain` to confirm.
- **`dropIndex` by spec must match exactly.** `{ email: 1 }` matches but `{ email: -1 }` does not.
  When in doubt, drop by name.
- **TTL and replica sets** — TTL cleanup only runs on the primary. Reads on secondaries can still
  return logically expired documents until the primary removes them and replication propagates.

---

[README](README.md) | [00-connect.md](00-connect.md) | [01-crud.md](01-crud.md) |
[03-aggregation-views.md](03-aggregation-views.md) | [04-users-roles.md](04-users-roles.md) |
[05-security.md](05-security.md) | [06-backup-restore.md](06-backup-restore.md)
