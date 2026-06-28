# CRUD Operations

MongoDB stores data as **documents** (JSON-like objects) inside **collections** (analogous to tables
but schema-free). Every document gets a unique `_id` field automatically — a 12-byte BSON `ObjectId`
by default — unless you supply your own.

All examples use the `learn_cli` scratch database with three collections: `customers`, `products`,
and `orders`.

---

## Setup — run once, copy to container

Save this file as `/tmp/shop_seed.js` on the host, copy it in, and run it before the other
sections.

```bash
cat > /tmp/shop_seed.js << 'EOF'
use("learn_cli");
db.customers.drop();
db.products.drop();
db.orders.drop();
EOF
docker cp /tmp/shop_seed.js mini-baas-mongo:/tmp/shop_seed.js
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
   --authenticationDatabase admin --quiet /tmp/shop_seed.js'
```

---

## Insert

### `insertOne`

```js
// in a .js file or interactive shell
use("learn_cli");

var result = db.customers.insertOne({
  name:      "Alice",
  email:     "alice@shop.dev",
  createdAt: new Date("2024-01-10")
});
print(result.acknowledged);   // true
print(result.insertedId);     // ObjectId("...")
```

`insertOne` returns `{ acknowledged: true, insertedId: ObjectId("...") }`.

### `insertMany`

```js
var result = db.products.insertMany([
  { name: "Laptop", priceCents: 99999, stock: 5  },
  { name: "Mouse",  priceCents:  2999, stock: 42 }
]);
print(Object.keys(result.insertedIds).length);  // 2
```

`insertMany` returns `{ acknowledged: true, insertedIds: { "0": ObjectId, "1": ObjectId, ... } }`.

Documents in MongoDB are **schemaless** — `customers` can hold any mix of fields across its
documents. The BSON type system supports strings, numbers, dates, arrays, embedded documents, and
the `ObjectId` type (distinct from a plain string).

---

## Find

### Basic find

```js
// All documents
db.customers.find()

// With a filter
db.customers.find({ name: "Alice" })

// findOne — returns a single document or null
db.customers.findOne({ email: "alice@shop.dev" })
```

### Query operators

All examples below belong in a `.js` file (dollar signs confuse the shell in `--eval "..."`).

```js
use("learn_cli");

// $eq (explicit form; usually just omit it)
db.products.find({ name: { $eq: "Laptop" } })

// $gt / $gte / $lt / $lte
db.products.find({ priceCents: { $gt: 3000 } })
db.products.find({ stock: { $gte: 5, $lt: 50 } })

// $in
db.products.find({ name: { $in: ["Laptop", "Mouse"] } })

// $and (implicit — just use a multi-key filter object)
db.products.find({ priceCents: { $gt: 2000 }, stock: { $gt: 0 } })

// $and (explicit — needed when you test the same field twice)
db.products.find({
  $and: [
    { priceCents: { $gt: 1000 } },
    { priceCents: { $lt: 50000 } }
  ]
})

// $or
db.products.find({
  $or: [
    { name: "Laptop" },
    { stock: { $lt: 5 } }
  ]
})
```

### Projection

The second argument to `find` controls which fields to return. `1` means include, `0` means
exclude. You cannot mix includes and excludes (except for `_id`).

```js
// Include only name and email; suppress _id
db.customers.find({}, { name: 1, email: 1, _id: 0 })
// → [{ name: "Alice", email: "alice@shop.dev" }]

// Exclude a field, return everything else
db.customers.find({}, { createdAt: 0 })
```

### Cursor modifiers — sort, limit, skip

```js
// Most expensive first
db.products.find({}, { name: 1, priceCents: 1, _id: 0 })
           .sort({ priceCents: -1 })

// Pagination: second page of 2 results
db.products.find().sort({ name: 1 }).skip(2).limit(2)
```

### `countDocuments`

```js
db.products.countDocuments()          // all
db.products.countDocuments({ stock: { $gt: 10 } })  // filtered
```

---

## Update

### `updateOne` and `updateMany`

The second argument is an **update document** containing update operators:

| Operator | Effect |
|----------|--------|
| `$set`   | Set field values (adds field if missing) |
| `$inc`   | Increment a numeric field |
| `$push`  | Append a value to an array field |
| `$unset` | Remove a field from the document |

```js
use("learn_cli");

// $set — add a verified flag
db.customers.updateOne(
  { name: "Alice" },
  { $set: { verified: true } }
)
// → { matchedCount: 1, modifiedCount: 1 }

// $inc — decrement stock by 1
db.products.updateOne(
  { name: "Mouse" },
  { $inc: { stock: -1 } }
)

// $push — append a tag
db.products.updateOne(
  { name: "Laptop" },
  { $push: { tags: "electronics" } }
)

// $unset — remove a field
db.products.updateOne(
  { name: "Laptop" },
  { $unset: { tags: "" } }   // value is ignored; "" is conventional
)

// updateMany — mark all low-stock products
db.products.updateMany(
  { stock: { $lt: 10 } },
  { $set: { lowStock: true } }
)
```

### `replaceOne`

Replaces the entire document except `_id`. Unlike `updateOne`, there is no operator — you pass the
new document directly.

```js
db.products.replaceOne(
  { name: "Mouse" },
  { name: "Wireless Mouse", priceCents: 3499, stock: 38, category: "peripherals" }
)
// The old price, stock, and any other fields are gone; only the new document remains (plus _id)
```

### Upsert — insert-if-missing

Add `{ upsert: true }` as a third argument. If no document matches the filter, MongoDB inserts one.

```js
var result = db.products.updateOne(
  { name: "Keyboard" },
  { $set: { name: "Keyboard", priceCents: 4999, stock: 10 } },
  { upsert: true }
);
print(result.upsertedCount);  // 1 (inserted) or 0 (updated)
print(JSON.stringify(result));
// { acknowledged:true, insertedId:"...", matchedCount:0, modifiedCount:0, upsertedCount:1 }
```

Note: in mongosh 7, the serialised result field for the new document's id is `insertedId`, not
`upsertedId`. Use `result.upsertedCount` to distinguish insert from update.

---

## Delete

```js
// Delete one matching document
db.customers.deleteOne({ name: "Bob" })
// → { deletedCount: 1 }

// Delete all matching documents
db.orders.deleteMany({ status: "cancelled" })
// → { deletedCount: N }

// Delete ALL documents in a collection (keeps the collection itself)
db.sessions.deleteMany({})
```

---

## Scenario — a complete shop transaction

```bash
cat > /tmp/shop_txn.js << 'EOF'
use("learn_cli");

// Seed
db.customers.drop(); db.products.drop(); db.orders.drop();

var alice  = db.customers.insertOne({ name: "Alice", email: "alice@shop.dev", createdAt: new Date("2024-01-10") }).insertedId;
var laptop = db.products.insertOne( { name: "Laptop", priceCents: 99999, stock: 5  }).insertedId;
var mouse  = db.products.insertOne( { name: "Mouse",  priceCents:  2999, stock: 42 }).insertedId;

// Place two orders
db.orders.insertMany([
  { customerId: alice, productId: laptop, qty: 1, status: "pending", createdAt: new Date() },
  { customerId: alice, productId: mouse,  qty: 2, status: "pending", createdAt: new Date() }
]);

// Decrement stock for both items
db.products.updateOne({ _id: laptop }, { $inc: { stock: -1 } });
db.products.updateOne({ _id: mouse  }, { $inc: { stock: -2 } });

// Ship the laptop order
db.orders.updateOne({ productId: laptop }, { $set: { status: "shipped" } });

// Read back pending orders
var pending = db.orders.find({ status: "pending" }, { status: 1, qty: 1, _id: 0 }).toArray();
print("pending:", JSON.stringify(pending));

// Read stock levels
var stock = db.products.find({}, { name: 1, stock: 1, _id: 0 }).sort({ name: 1 }).toArray();
print("stock:", JSON.stringify(stock));

// Cleanup
db.dropDatabase();
print("done — learn_cli dropped");
EOF
docker cp /tmp/shop_txn.js mini-baas-mongo:/tmp/shop_txn.js
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
   --authenticationDatabase admin --quiet /tmp/shop_txn.js'
```

Expected output:

```
pending: [{"qty":2,"status":"pending"}]
stock: [{"name":"Laptop","stock":4},{"name":"Mouse","stock":40}]
done — learn_cli dropped
```

---

## Gotchas / Docker notes

- **`_id` is immutable.** You cannot change it with `$set` or `replaceOne`. If you need a different
  `_id`, delete and reinsert.
- **`replaceOne` with `$set` is a common mistake.** `replaceOne` takes a plain document, not an
  operator. Using `{ $set: ... }` as the second argument to `replaceOne` creates a document that
  literally has a field named `"$set"`.
- **`$` in shell `--eval`.** Query operators (`$gt`, `$set`, etc.) start with `$`. In a
  double-quoted `--eval "..."` string, the shell tries to expand `$gt` as a variable — it expands
  to an empty string and the query silently fails or does the wrong thing. Use a `.js` file for any
  query that contains operators.
- **`find` returns a cursor, not an array.** In the interactive shell it auto-iterates 20 docs.
  In a `.js` file, call `.toArray()` or use `.forEach(doc => print(...))`.
- **BSON date vs string.** `new Date("2024-01-10")` stores a BSON Date. If you insert
  `"2024-01-10"` (a string) instead, range queries with `$gt`/`$lt` on dates will not work as
  expected. Always use `new Date(...)` for temporal data.

---

[README](README.md) | [00-connect.md](00-connect.md) | [02-indexes.md](02-indexes.md) |
[03-aggregation-views.md](03-aggregation-views.md) | [04-users-roles.md](04-users-roles.md) |
[05-security.md](05-security.md) | [06-backup-restore.md](06-backup-restore.md)
