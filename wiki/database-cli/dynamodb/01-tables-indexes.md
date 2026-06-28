# 01 — Tables and Indexes

In DynamoDB the table's key structure is the most important design decision you make. Unlike a relational schema, you cannot add columns or change keys later — you can only add indexes. This file covers creating tables, understanding key types, and adding indexes.

Assumes the `ddb` helper from [00-connect.md](00-connect.md) is defined.

---

## Key design: partition key and sort key

Every table has a **partition key** (HASH). An optional **sort key** (RANGE) turns the table into a two-level hierarchy. Together they form the **primary key** — it must be unique per item.

| Key type | DynamoDB term | Purpose |
|---|---|---|
| Partition key only | HASH | Best when you always look up by a single value (e.g., user ID) |
| Partition key + sort key | HASH + RANGE | Enables range queries within a partition (e.g., all orders for a customer, sorted by date) |

**Design rule:** your most common read access pattern should be expressible as a partition-key lookup. Secondary access patterns go on indexes.

The shop model used throughout these notes:

- `customer_id` (S) — HASH: fetches all orders for one customer in one request
- `order_id` (S) — RANGE: identifies a specific order, enables `begins_with` / `between` on order IDs

---

## `create-table`

```bash
ddb create-table \
  --table-name learn_orders \
  --attribute-definitions \
      AttributeName=customer_id,AttributeType=S \
      AttributeName=order_id,AttributeType=S \
      AttributeName=status,AttributeType=S \
  --key-schema \
      AttributeName=customer_id,KeyType=HASH \
      AttributeName=order_id,KeyType=RANGE \
  --global-secondary-indexes '[
    {
      "IndexName": "status-order-index",
      "KeySchema": [
        {"AttributeName":"status","KeyType":"HASH"},
        {"AttributeName":"order_id","KeyType":"RANGE"}
      ],
      "Projection": {"ProjectionType":"ALL"}
    }
  ]' \
  --billing-mode PAY_PER_REQUEST
```

Key points:

- `--attribute-definitions` lists **only** the attributes that appear in a key (primary or index key). Every other attribute is schema-free — you can store anything.
- `AttributeType`: `S` = string, `N` = number, `B` = binary.
- `--billing-mode PAY_PER_REQUEST` (on-demand) removes the need to pre-provision read/write capacity units. Use `PROVISIONED` in production only when you have a predictable, stable traffic pattern.
- `TableStatus` will be `ACTIVE` immediately on Local.

Expected output (trimmed):

```json
{
    "TableDescription": {
        "TableName": "learn_orders",
        "TableStatus": "ACTIVE",
        "BillingModeSummary": {
            "BillingMode": "PAY_PER_REQUEST"
        },
        "GlobalSecondaryIndexes": [
            { "IndexName": "status-order-index", "IndexStatus": "ACTIVE" }
        ]
    }
}
```

---

## `describe-table`

```bash
ddb describe-table --table-name learn_orders
```

Narrow the output with `--query`:

```bash
ddb describe-table --table-name learn_orders \
  --query 'Table.{Name:TableName,Status:TableStatus,Keys:KeySchema,GSI:GlobalSecondaryIndexes[*].{Index:IndexName,Keys:KeySchema}}'
```

Expected:

```json
{
    "Name": "learn_orders",
    "Status": "ACTIVE",
    "Keys": [
        { "AttributeName": "customer_id", "KeyType": "HASH" },
        { "AttributeName": "order_id", "KeyType": "RANGE" }
    ],
    "GSI": [
        {
            "Index": "status-order-index",
            "Keys": [
                { "AttributeName": "status", "KeyType": "HASH" },
                { "AttributeName": "order_id", "KeyType": "RANGE" }
            ]
        }
    ]
}
```

---

## `list-tables`

```bash
ddb list-tables
```

Paginate large lists (over 100 tables):

```bash
ddb list-tables --max-items 10
ddb list-tables --max-items 10 --starting-token <NextToken>
```

---

## Global Secondary Indexes (GSI)

A GSI lets you query on a different key than the table's primary key. It is eventually consistent by default (strong consistency is only available on the base table).

- You can have up to 20 GSIs per table.
- The GSI's partition key can be any attribute — it does not have to be unique.
- Use `"Projection": {"ProjectionType":"ALL"}` to copy every attribute into the index. Use `KEYS_ONLY` or `INCLUDE` to save storage at the cost of a second read.

The `status-order-index` GSI created above lets you ask: "show me all orders where `status = 'shipped'`" — which the base table cannot answer without a full scan.

---

## Local Secondary Indexes (LSI)

An LSI provides an alternate **sort key** for the same partition key. Unlike a GSI:

- Must be declared at `create-table` time — you cannot add one later.
- Shares the base table's partition key.
- Supports `--consistent-read`.
- Limit: 5 per table.

Example LSI (declare inside `create-table`, alongside `--key-schema`):

```bash
--local-secondary-indexes '[
  {
    "IndexName": "customer-total-lsi",
    "KeySchema": [
      {"AttributeName":"customer_id","KeyType":"HASH"},
      {"AttributeName":"total_usd","KeyType":"RANGE"}
    ],
    "Projection": {"ProjectionType":"ALL"}
  }
]'
```

This would let you query one customer's orders sorted by total spend — without a GSI — at the cost of being declared upfront and unchangeable.

---

## `update-table` — adding a GSI after creation

You can add a GSI to an existing table without downtime. In production this backfills asynchronously; on Local it is immediate.

```bash
ddb update-table \
  --table-name learn_orders \
  --attribute-definitions \
      AttributeName=customer_id,AttributeType=S \
      AttributeName=total_usd,AttributeType=N \
  --global-secondary-index-updates '[
    {"Create": {
      "IndexName": "customer-total-index",
      "KeySchema": [
        {"AttributeName":"customer_id","KeyType":"HASH"},
        {"AttributeName":"total_usd","KeyType":"RANGE"}
      ],
      "Projection": {"ProjectionType":"KEYS_ONLY"}
    }}
  ]' \
  --billing-mode PAY_PER_REQUEST
```

You can also **delete** an existing GSI in the same call:

```bash
--global-secondary-index-updates '[{"Delete":{"IndexName":"customer-total-index"}}]'
```

---

## `delete-table`

```bash
ddb delete-table --table-name learn_orders
```

This is immediate on Local. In production it is irreversible and takes a few seconds. Always verify the table name before running.

---

## Scenario: design `learn_orders` with a status GSI

**Problem:** you need two access patterns:
1. "Fetch all orders for customer X, newest first."
2. "Fetch all orders currently in status `shipped`."

**Solution:**

- Base table: `customer_id` (HASH) + `order_id` (RANGE). Pattern 1 is a single query.
- GSI `status-order-index`: `status` (HASH) + `order_id` (RANGE). Pattern 2 is a GSI query.

No scan needed for either pattern. This is the core of single-table DynamoDB design: let your key structure — not SQL WHERE clauses — answer your queries.

```bash
# Create the table (full command from the create-table section above)
ddb create-table \
  --table-name learn_orders \
  --attribute-definitions \
      AttributeName=customer_id,AttributeType=S \
      AttributeName=order_id,AttributeType=S \
      AttributeName=status,AttributeType=S \
  --key-schema \
      AttributeName=customer_id,KeyType=HASH \
      AttributeName=order_id,KeyType=RANGE \
  --global-secondary-indexes '[
    {
      "IndexName": "status-order-index",
      "KeySchema": [
        {"AttributeName":"status","KeyType":"HASH"},
        {"AttributeName":"order_id","KeyType":"RANGE"}
      ],
      "Projection": {"ProjectionType":"ALL"}
    }
  ]' \
  --billing-mode PAY_PER_REQUEST

# Confirm
ddb describe-table --table-name learn_orders \
  --query 'Table.{Status:TableStatus,GSI:GlobalSecondaryIndexes[*].IndexName}'

# Clean up
ddb delete-table --table-name learn_orders
```

---

## Gotchas / Docker notes

- **Only key attributes in `--attribute-definitions`.** Listing a non-key attribute there causes a `ValidationException`. DynamoDB is schema-free for everything except keys.
- **No altering the primary key.** There is no `ALTER TABLE` equivalent. If you need a different key structure, create a new table and migrate.
- **LSIs are permanent.** You cannot add or remove an LSI after `create-table`. If you realize you need one later, you must recreate the table.
- **GSI consistency.** GSI reads are eventually consistent by default. `--consistent-read` is only accepted on the base table (and LSIs). Do not use `--consistent-read` with `--index-name` — it will error.
- **`PAY_PER_REQUEST` on Local.** Billing mode is accepted and stored but has no actual effect on Local — there are no capacity units to exhaust.
- **In production**, `TableStatus` starts as `CREATING` for GSI backfills. Poll `describe-table` until the index reaches `ACTIVE` before querying it.

---

## See also

- [00-connect.md](00-connect.md) — sidecar setup and `ddb` helper
- [02-crud-items.md](02-crud-items.md) — writing items into the table
- [03-query-scan.md](03-query-scan.md) — querying by table key or GSI
- [04-security.md](04-security.md) — locking down table and index access with IAM
