# Aggregation Pipeline and Views

The **aggregation pipeline** is MongoDB's answer to SQL's `GROUP BY`, `JOIN`, `HAVING`, and
window functions — all chained as an ordered list of stages. A **view** is a named, stored pipeline
that looks like a collection to readers.

All examples must go in a `.js` file (the `$` operators collide with shell expansion in `--eval`).

---

## The aggregation pipeline

`db.collection.aggregate([stage1, stage2, ...])` passes documents through each stage in order.
Each stage transforms or filters the stream.

### Core stages

| Stage | What it does |
|-------|-------------|
| `$match` | Filter documents (like `find`) |
| `$group` | Collapse multiple documents into one per `_id` group |
| `$sort`  | Sort the stream |
| `$project` | Reshape or rename fields |
| `$lookup` | Left-outer join from another collection |
| `$unwind` | Flatten an array field into one document per element |
| `$limit` / `$skip` | Pagination |
| `$out` | Write the pipeline result into a collection (replaces it) |
| `$merge` | Merge the pipeline result into an existing collection |

---

## Seed data (run this first)

```bash
cat > /tmp/agg_seed.js << 'EOF'
use("learn_cli");
db.customers.drop(); db.products.drop(); db.orders.drop();

var alice  = db.customers.insertOne({ name: "Alice", email: "alice@shop.dev", createdAt: new Date("2024-01-10") }).insertedId;
var bob    = db.customers.insertOne({ name: "Bob",   email: "bob@shop.dev",   createdAt: new Date("2024-02-05") }).insertedId;

var laptop = db.products.insertOne({ name: "Laptop", priceCents: 99999, stock: 5  }).insertedId;
var mouse  = db.products.insertOne({ name: "Mouse",  priceCents:  2999, stock: 42 }).insertedId;

db.orders.insertMany([
  { customerId: alice, productId: laptop, qty: 1, status: "shipped",   createdAt: new Date("2024-03-01") },
  { customerId: alice, productId: mouse,  qty: 2, status: "pending",   createdAt: new Date("2024-03-05") },
  { customerId: bob,   productId: laptop, qty: 1, status: "shipped",   createdAt: new Date("2024-03-10") },
  { customerId: bob,   productId: mouse,  qty: 3, status: "delivered", createdAt: new Date("2024-03-12") }
]);
print("seeded");
EOF
docker cp /tmp/agg_seed.js mini-baas-mongo:/tmp/agg_seed.js
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
   --authenticationDatabase admin --quiet /tmp/agg_seed.js'
```

---

## `$match` and `$group`

```js
use("learn_cli");

// Total revenue per customer across completed orders
db.orders.aggregate([
  // 1. Filter to shipped/delivered only
  { $match: { status: { $in: ["shipped", "delivered"] } } },

  // 2. Join to products to get price
  { $lookup: {
      from:         "products",
      localField:   "productId",
      foreignField: "_id",
      as:           "product"
  }},
  { $unwind: "$product" },

  // 3. Join to customers to get name
  { $lookup: {
      from:         "customers",
      localField:   "customerId",
      foreignField: "_id",
      as:           "customer"
  }},
  { $unwind: "$customer" },

  // 4. Group by customer name, sum up revenue
  { $group: {
      _id:        "$customer.name",
      totalCents: { $sum: { $multiply: ["$qty", "$product.priceCents"] } }
  }},

  // 5. Sort descending
  { $sort: { totalCents: -1 } },

  // 6. Rename _id to customer in output
  { $project: { _id: 0, customer: "$_id", totalCents: 1 } }
]).toArray()
// → [{ totalCents: 108996, customer: "Bob" }, { totalCents: 99999, customer: "Alice" }]
```

### How `$lookup` works

`$lookup` is a left outer join:

```
localField  = the field in the current (left) collection
foreignField = the field in the joined (right) collection
as          = name of the array field added to each document
```

Each matched document from the right collection is added as an element of the array. A document
with no match gets an empty array. `$unwind` then flattens that one-element array back into the
document.

### Common `$group` accumulators

| Accumulator | Meaning |
|-------------|---------|
| `$sum`    | Total |
| `$avg`    | Average |
| `$min` / `$max` | Extremes |
| `$first` / `$last` | First/last value in the group |
| `$push`   | Collect values into an array |
| `$addToSet` | Collect unique values |

---

## Read-only views — `db.createView`

A view is a stored aggregation pipeline. It behaves like a collection for `find` and `aggregate`
but cannot be written to.

```js
use("learn_cli");

db.createView(
  "active_orders",       // view name
  "orders",              // source collection
  [
    { $match: { status: { $in: ["pending", "shipped"] } } },
    { $lookup: { from: "products",  localField: "productId",  foreignField: "_id", as: "product"  } },
    { $unwind: "$product" },
    { $lookup: { from: "customers", localField: "customerId", foreignField: "_id", as: "customer" } },
    { $unwind: "$customer" },
    { $project: {
        _id:          0,
        customerName: "$customer.name",
        productName:  "$product.name",
        qty:          1,
        status:       1
    }}
  ]
);

// Querying the view works exactly like querying a collection
var rows = db.active_orders.find().toArray();
print(JSON.stringify(rows));
// → [{ qty:1, status:"shipped", customerName:"Alice", productName:"Laptop" }, ...]
```

Views do not store data; they re-run the pipeline on every query. Indexes on the source collection
are used transparently.

To drop a view:

```js
db.active_orders.drop()
```

---

## On-demand materialized view — `$out`

`$out` writes the pipeline result to a collection, replacing it entirely. Useful for pre-computing
heavy aggregations that don't need to be fresh on every query.

```js
use("learn_cli");

db.orders.aggregate([
  { $match: { status: { $in: ["shipped", "delivered"] } } },
  { $lookup: { from: "products", localField: "productId", foreignField: "_id", as: "product" } },
  { $unwind: "$product" },
  { $group: {
      _id:         "$productId",
      productName: { $first: "$product.name" },
      totalQty:    { $sum:   "$qty"           }
  }},
  { $out: "product_sales_summary" }   // ← write to this collection
]);

db.product_sales_summary.find({}, { _id: 0 }).toArray()
// → [{ productName: "Laptop", totalQty: 2 }, { productName: "Mouse", totalQty: 3 }]
```

`$out` atomically swaps the destination collection; there is no partial state. `$merge` is a
softer alternative that can upsert into an existing collection rather than replace it.

---

## Scenario — `order_summary` view

```bash
cat > /tmp/agg_scenario.js << 'EOF'
use("learn_cli");

// Create summary view
try { db.order_summary.drop(); } catch(e) {}

db.createView("order_summary", "orders", [
  { $lookup: { from: "products",  localField: "productId",  foreignField: "_id", as: "p" } },
  { $unwind: "$p" },
  { $lookup: { from: "customers", localField: "customerId", foreignField: "_id", as: "c" } },
  { $unwind: "$c" },
  { $project: {
      _id:      0,
      customer: "$c.name",
      product:  "$p.name",
      qty:      1,
      status:   1,
      lineTotal: { $multiply: ["$qty", "$p.priceCents"] }
  }},
  { $sort: { customer: 1, product: 1 } }
]);

// Query the view
var rows = db.order_summary.find().toArray();
rows.forEach(r => print(r.customer, "|", r.product, "|", r.status, "|", r.lineTotal + "c"));

// Check collections
print("collections:", db.getCollectionNames().join(", "));

// Cleanup
db.order_summary.drop();
db.dropDatabase();
print("done");
EOF
docker cp /tmp/agg_scenario.js mini-baas-mongo:/tmp/agg_scenario.js
docker exec mini-baas-mongo sh -lc \
  'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
   --authenticationDatabase admin --quiet /tmp/agg_scenario.js'
```

Expected output:

```
Alice | Laptop | shipped | 99999c
Alice | Mouse | pending | 5998c
Bob | Laptop | shipped | 99999c
Bob | Mouse | delivered | 8997c
collections: orders, system.views, products, customers, order_summary
done
```

---

## Gotchas / Docker notes

- **`$` operators in shell** — any pipeline stage name or accumulator (`$match`, `$group`, `$sum`,
  etc.) starts with `$`. In a double-quoted `--eval "..."` string bash treats `$match` as a shell
  variable (expands to empty string). Always use a `.js` file for aggregation.
- **`$unwind` on an empty array** removes the document from the pipeline. If a `$lookup` might
  return no matches, use `{ $unwind: { path: "$field", preserveNullAndEmptyArrays: true } }`.
- **View pipeline re-executes on every read.** If your `$lookup`-heavy pipeline is slow, cache
  the result with `$out` and run the refresh on a schedule.
- **`$out` drops and replaces.** If the pipeline fails mid-way, the destination collection is not
  updated — `$out` is atomic at the collection level. `$merge` gives you more control.
- **`system.views` is a real collection.** It stores view definitions and will show up in
  `show collections`. Don't write to it directly.

---

[README](README.md) | [00-connect.md](00-connect.md) | [01-crud.md](01-crud.md) |
[02-indexes.md](02-indexes.md) | [04-users-roles.md](04-users-roles.md) |
[05-security.md](05-security.md) | [06-backup-restore.md](06-backup-restore.md)
