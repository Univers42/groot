# 02 — CRUD Operations on Items

DynamoDB items are schemaless bags of typed attributes. You declare only the key attributes in the table definition; everything else is free-form per item. This file covers writing, reading, updating, and deleting items in the `learn_orders` table.

Assumes the `ddb` helper from [00-connect.md](00-connect.md) is defined and `learn_orders` was created per [01-tables-indexes.md](01-tables-indexes.md).

---

## DynamoDB attribute type notation

Every attribute value in the CLI wire format is wrapped in a type tag:

| Tag | Type | Example |
|---|---|---|
| `S` | String | `{"S": "cust#001"}` |
| `N` | Number (stored as string) | `{"N": "49.99"}` |
| `BOOL` | Boolean | `{"BOOL": true}` |
| `NULL` | Null | `{"NULL": true}` |
| `L` | List (ordered, mixed types) | `{"L": [{"S":"a"}, {"N":"1"}]}` |
| `M` | Map (nested object) | `{"M": {"city": {"S":"Paris"}}}` |
| `SS` | String set (unique) | `{"SS": ["a","b"]}` |
| `NS` | Number set (unique) | `{"NS": ["1","2"]}` |
| `BS` | Binary set | (rare) |

---

## Setup: create `learn_orders`

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

---

## `put-item` — write or replace an item

`put-item` is a full replace — if the key exists, the old item is overwritten completely.

```bash
ddb put-item --table-name learn_orders --item '{
  "customer_id": {"S": "cust#001"},
  "order_id":    {"S": "ord#2026-001"},
  "product":     {"S": "Mechanical Keyboard"},
  "qty":         {"N": "2"},
  "status":      {"S": "pending"},
  "total_usd":   {"N": "179.98"},
  "tags":        {"L": [{"S":"electronics"}, {"S":"periph"}]},
  "shipped":     {"BOOL": false}
}'
```

`put-item` returns nothing by default (HTTP 200, empty body). Use `--return-values ALL_OLD` to get the item that was overwritten (if any).

### Prevent accidental overwrites with `attribute_not_exists`

```bash
ddb put-item --table-name learn_orders \
  --item '{"customer_id":{"S":"cust#001"},"order_id":{"S":"ord#2026-001"},"product":{"S":"Mouse"}}' \
  --condition-expression "attribute_not_exists(customer_id)"
```

This fails with `ConditionalCheckFailedException` if the item already exists — a safe insert-only guard.

---

## `get-item` — read a single item by primary key

You must supply the complete primary key (partition key + sort key if the table has one).

```bash
ddb get-item \
  --table-name learn_orders \
  --key '{"customer_id":{"S":"cust#001"},"order_id":{"S":"ord#2026-001"}}'
```

Expected output:

```json
{
    "Item": {
        "product":     {"S": "Mechanical Keyboard"},
        "shipped":     {"BOOL": false},
        "qty":         {"N": "2"},
        "total_usd":   {"N": "179.98"},
        "customer_id": {"S": "cust#001"},
        "order_id":    {"S": "ord#2026-001"},
        "status":      {"S": "pending"},
        "tags":        {"L": [{"S":"electronics"},{"S":"periph"}]}
    }
}
```

If the item does not exist, the response is `{}` (no `Item` key) — not an error.

### Fetch only specific attributes

```bash
ddb get-item \
  --table-name learn_orders \
  --key '{"customer_id":{"S":"cust#001"},"order_id":{"S":"ord#2026-001"}}' \
  --projection-expression "product, #s, total_usd" \
  --expression-attribute-names '{"#s":"status"}'
```

`status` is not a reserved word, but the pattern of using `#name` aliases is good practice — it avoids any collision with DynamoDB reserved words like `name`, `size`, `data`.

---

## `update-item` — modify individual attributes

`update-item` is a partial update — attributes not mentioned are untouched.

### `SET` — write or overwrite attributes

```bash
ddb update-item \
  --table-name learn_orders \
  --key '{"customer_id":{"S":"cust#001"},"order_id":{"S":"ord#2026-001"}}' \
  --update-expression "SET #s = :s, shipped = :sh" \
  --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":s":{"S":"shipped"},":sh":{"BOOL":true}}' \
  --return-values ALL_NEW
```

`--return-values ALL_NEW` returns the full item after the update. Options: `NONE` (default), `ALL_OLD`, `UPDATED_OLD`, `ALL_NEW`, `UPDATED_NEW`.

### `ADD` — increment a number or add to a set

```bash
ddb update-item \
  --table-name learn_orders \
  --key '{"customer_id":{"S":"cust#001"},"order_id":{"S":"ord#2026-001"}}' \
  --update-expression "ADD qty :inc" \
  --expression-attribute-values '{":inc":{"N":"1"}}' \
  --return-values UPDATED_NEW
```

### `REMOVE` — delete an attribute

```bash
ddb update-item \
  --table-name learn_orders \
  --key '{"customer_id":{"S":"cust#002"},"order_id":{"S":"ord#2026-004"}}' \
  --update-expression "REMOVE tags" \
  --return-values ALL_NEW
```

### Combine `SET`, `ADD`, and `REMOVE` in one call

```bash
ddb update-item \
  --table-name learn_orders \
  --key '{"customer_id":{"S":"cust#001"},"order_id":{"S":"ord#2026-001"}}' \
  --update-expression "SET #s = :s, shipped = :sh ADD qty :inc REMOVE tags" \
  --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":s":{"S":"shipped"},":sh":{"BOOL":true},":inc":{"N":"1"}}' \
  --return-values ALL_NEW
```

---

## `delete-item` — remove an item

```bash
ddb delete-item \
  --table-name learn_orders \
  --key '{"customer_id":{"S":"cust#003"},"order_id":{"S":"ord#2026-005"}}' \
  --return-values ALL_OLD
```

Returns the deleted item (under `Attributes`) when `ALL_OLD` is set. Returns `{}` if the item did not exist.

---

## `batch-write-item` — write or delete up to 25 items at once

Batch operations are more efficient than individual calls when loading seed data. Each request item is either a `PutRequest` or `DeleteRequest`.

```bash
ddb batch-write-item --request-items '{
  "learn_orders": [
    {"PutRequest": {"Item": {
      "customer_id": {"S": "cust#002"},
      "order_id":    {"S": "ord#2026-003"},
      "product":     {"S": "Ergonomic Chair"},
      "qty":         {"N": "1"},
      "status":      {"S": "shipped"},
      "total_usd":   {"N": "389.00"},
      "shipped":     {"BOOL": true}
    }}},
    {"PutRequest": {"Item": {
      "customer_id": {"S": "cust#002"},
      "order_id":    {"S": "ord#2026-004"},
      "product":     {"S": "Standing Desk"},
      "qty":         {"N": "1"},
      "status":      {"S": "cancelled"},
      "total_usd":   {"N": "599.00"},
      "shipped":     {"BOOL": false}
    }}},
    {"DeleteRequest": {"Key": {
      "customer_id": {"S": "cust#old"},
      "order_id":    {"S": "ord#legacy"}
    }}}
  ]
}'
```

Expected output when all items are processed:

```json
{ "UnprocessedItems": {} }
```

If `UnprocessedItems` is non-empty, retry those items — DynamoDB may throttle part of a batch in production.

---

## Conditional writes — `--condition-expression`

A condition expression is evaluated server-side before the write executes. If it evaluates to false, the operation is rejected with `ConditionalCheckFailedException` and nothing changes.

### State-machine guard: only advance if currently in the right state

```bash
ddb update-item \
  --table-name learn_orders \
  --key '{"customer_id":{"S":"cust#001"},"order_id":{"S":"ord#2026-001"}}' \
  --update-expression "SET #s = :new" \
  --condition-expression "#s = :expected" \
  --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":new":{"S":"delivered"},":expected":{"S":"shipped"}}' \
  --return-values ALL_NEW
```

If the current status is not `shipped`, the update is rejected — the item is unchanged. This is DynamoDB's optimistic concurrency pattern: no row locks, just atomic conditional writes.

### Confirm the failure case

```bash
# Status is now 'delivered' — this will fail
ddb update-item \
  --table-name learn_orders \
  --key '{"customer_id":{"S":"cust#001"},"order_id":{"S":"ord#2026-001"}}' \
  --update-expression "SET #s = :new" \
  --condition-expression "#s = :expected" \
  --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":new":{"S":"refunded"},":expected":{"S":"pending"}}'
# Output: An error occurred (ConditionalCheckFailedException)
```

---

## Scenario: order lifecycle with safe state transitions

```bash
# Seed an order
ddb put-item --table-name learn_orders --item '{
  "customer_id": {"S":"cust#001"},
  "order_id":    {"S":"ord#2026-001"},
  "product":     {"S":"Mechanical Keyboard"},
  "qty":         {"N":"2"},
  "status":      {"S":"pending"},
  "total_usd":   {"N":"179.98"},
  "shipped":     {"BOOL":false}
}'

# Advance pending -> shipped (atomic conditional)
ddb update-item \
  --table-name learn_orders \
  --key '{"customer_id":{"S":"cust#001"},"order_id":{"S":"ord#2026-001"}}' \
  --update-expression "SET #s = :s, shipped = :sh" \
  --condition-expression "#s = :cur" \
  --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":s":{"S":"shipped"},":sh":{"BOOL":true},":cur":{"S":"pending"}}' \
  --return-values UPDATED_NEW

# Advance shipped -> delivered
ddb update-item \
  --table-name learn_orders \
  --key '{"customer_id":{"S":"cust#001"},"order_id":{"S":"ord#2026-001"}}' \
  --update-expression "SET #s = :s" \
  --condition-expression "#s = :cur" \
  --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":s":{"S":"delivered"},":cur":{"S":"shipped"}}' \
  --return-values UPDATED_NEW

# Clean up
ddb delete-table --table-name learn_orders
```

---

## Gotchas / Docker notes

- **`put-item` is a full replace.** It will silently delete attributes not present in the new `--item` JSON. Use `update-item SET` when you only want to change specific fields.
- **Numbers are always strings on the wire.** `{"N": "49.99"}` — the JSON value is a string, not a float. DynamoDB stores it as a precise decimal.
- **Reserved words need aliases.** If an attribute name matches a DynamoDB reserved word (e.g., `name`, `status`, `size`, `data`, `type`) in an expression, wrap it with `#alias` in `--expression-attribute-names`. When in doubt, alias it — it never hurts.
- **`batch-write-item` does not support conditions.** For conditional bulk writes, issue individual `put-item` or `update-item` calls or use transactions (`transact-write-items`).
- **25-item limit per batch.** `batch-write-item` rejects requests over 25 items. Split larger loads into chunks.
- **`--return-values` on `put-item`.** Only `ALL_OLD` (or `NONE`) is accepted — not `ALL_NEW`, because the "new" item is exactly what you just sent.

---

## See also

- [00-connect.md](00-connect.md) — sidecar setup and `ddb` helper
- [01-tables-indexes.md](01-tables-indexes.md) — table creation and index design
- [03-query-scan.md](03-query-scan.md) — reading multiple items with query and scan
- [04-security.md](04-security.md) — restricting who can write to which items
