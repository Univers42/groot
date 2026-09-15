# 03 — Query and Scan

`query` and `scan` are the two ways to read multiple items. Understanding their difference is fundamental to DynamoDB performance: `query` is targeted and cheap; `scan` reads every item and is expensive. This file explains both, covers GSI queries, projections, pagination, and read consistency.

Assumes the `ddb` helper from [00-connect.md](00-connect.md) is defined. Run the setup block below before the examples.

---

## Setup: seed data

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

ddb batch-write-item --request-items '{
  "learn_orders": [
    {"PutRequest":{"Item":{
      "customer_id":{"S":"cust#001"},"order_id":{"S":"ord#2026-001"},
      "product":{"S":"Mechanical Keyboard"},"qty":{"N":"2"},
      "status":{"S":"shipped"},"total_usd":{"N":"179.98"},"shipped":{"BOOL":true}
    }}},
    {"PutRequest":{"Item":{
      "customer_id":{"S":"cust#001"},"order_id":{"S":"ord#2026-002"},
      "product":{"S":"USB-C Hub"},"qty":{"N":"1"},
      "status":{"S":"pending"},"total_usd":{"N":"49.99"},"shipped":{"BOOL":false}
    }}},
    {"PutRequest":{"Item":{
      "customer_id":{"S":"cust#002"},"order_id":{"S":"ord#2026-003"},
      "product":{"S":"Ergonomic Chair"},"qty":{"N":"1"},
      "status":{"S":"shipped"},"total_usd":{"N":"389.00"},"shipped":{"BOOL":true}
    }}},
    {"PutRequest":{"Item":{
      "customer_id":{"S":"cust#002"},"order_id":{"S":"ord#2026-004"},
      "product":{"S":"Standing Desk"},"qty":{"N":"1"},
      "status":{"S":"cancelled"},"total_usd":{"N":"599.00"},"shipped":{"BOOL":false}
    }}},
    {"PutRequest":{"Item":{
      "customer_id":{"S":"cust#003"},"order_id":{"S":"ord#2026-005"},
      "product":{"S":"Monitor 4K"},"qty":{"N":"1"},
      "status":{"S":"shipped"},"total_usd":{"N":"649.00"},"shipped":{"BOOL":true}
    }}}
  ]
}'
```

---

## `query` — the right tool for most reads

`query` requires the **partition key** (HASH) of the base table or of a GSI. DynamoDB directs the request to the single partition that holds the data — it reads only what it returns.

### All orders for one customer

```bash
ddb query \
  --table-name learn_orders \
  --key-condition-expression "customer_id = :cid" \
  --expression-attribute-values '{":cid":{"S":"cust#001"}}'
```

Expected: 2 items, `Count: 2`, `ScannedCount: 2`.

### Narrow by sort key range — `begins_with`

```bash
ddb query \
  --table-name learn_orders \
  --key-condition-expression "customer_id = :cid AND begins_with(order_id, :pfx)" \
  --expression-attribute-values '{":cid":{"S":"cust#001"},":pfx":{"S":"ord#2026"}}'
```

Other sort key functions: `between(:lo, :hi)`, `< :val`, `<= :val`, `> :val`, `>= :val`.

### Return only selected attributes — `--projection-expression`

```bash
ddb query \
  --table-name learn_orders \
  --key-condition-expression "customer_id = :cid" \
  --expression-attribute-values '{":cid":{"S":"cust#001"}}' \
  --projection-expression "order_id, product, #s, total_usd" \
  --expression-attribute-names '{"#s":"status"}'
```

Projection reduces response size and read cost. The key attributes (`customer_id`, `order_id`) are always returned whether projected or not.

### Filter within a partition — `--filter-expression`

`--filter-expression` is applied **after** the read; it does not reduce the data DynamoDB must scan. Use it only for secondary filtering within a partition, never as a primary selection mechanism.

```bash
ddb query \
  --table-name learn_orders \
  --key-condition-expression "customer_id = :cid" \
  --filter-expression "total_usd > :min" \
  --expression-attribute-values '{":cid":{"S":"cust#001"},":min":{"N":"100"}}'
```

`Count` shows matched items; `ScannedCount` shows how many items were read from storage. If `Count < ScannedCount`, the filter discarded some items — you are paying for those reads.

### Sort order — `--scan-index-forward false`

Items are returned in ascending sort key order by default. Reverse with:

```bash
ddb query \
  --table-name learn_orders \
  --key-condition-expression "customer_id = :cid" \
  --expression-attribute-values '{":cid":{"S":"cust#001"}}' \
  --scan-index-forward false
```

---

## Querying a GSI — `--index-name`

```bash
ddb query \
  --table-name learn_orders \
  --index-name status-order-index \
  --key-condition-expression "#s = :s" \
  --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":s":{"S":"shipped"}}'
```

Expected: 3 items (orders from cust#001, cust#002, cust#003 that are shipped).

You must provide the GSI's partition key (`status` in this case). The sort key (`order_id`) is optional and accepts the same range functions as a base-table query.

**Note:** GSI reads are eventually consistent. Do not use `--consistent-read` with `--index-name` — the CLI will reject it.

---

## `scan` — full table reads

`scan` reads every item in the table (or index), then applies any `--filter-expression`. On a large table this is slow and expensive regardless of how many items the filter matches. Use it only when:

- You genuinely need to process all items (e.g., data export, admin backfill).
- The table is small and you have no access-pattern-based key design.

```bash
ddb scan --table-name learn_orders
```

### Filter during a scan

```bash
ddb scan \
  --table-name learn_orders \
  --filter-expression "total_usd > :min" \
  --expression-attribute-values '{":min":{"N":"200"}}' \
  --projection-expression "customer_id, order_id, product, total_usd"
```

Expected: `ScannedCount: 5` (all items read), `Count: 3` (items matching the filter).

### Counting without fetching items

```bash
ddb scan --table-name learn_orders --select COUNT
```

Returns `{"Count": 5, "ScannedCount": 5}` — all items are read server-side but not transferred.

---

## Pagination — `--max-items` and `--starting-token`

Both `query` and `scan` return a `NextToken` when more items exist beyond `--max-items`. Pass it back as `--starting-token` to fetch the next page.

```bash
# Page 1
ddb scan --table-name learn_orders --max-items 2
```

```json
{
    "Items": [ ... 2 items ... ],
    "Count": 5,
    "ScannedCount": 5,
    "NextToken": "eyJFeGNsdXNpdmVTdGFydEtleSI6..."
}
```

```bash
# Page 2
ddb scan --table-name learn_orders \
  --max-items 2 \
  --starting-token "eyJFeGNsdXNpdmVTdGFydEtleSI6..."
```

**Important:** `Count` in the response reflects the total items DynamoDB found before pagination, not the items on this page — the actual returned items are in the `Items` array.

### Low-level `LastEvaluatedKey` (raw API)

The `--max-items` / `--starting-token` pair is a CLI convenience that wraps the raw API's `Limit` + `LastEvaluatedKey` / `ExclusiveStartKey`. If you are using an SDK (boto3, the Go SDK, etc.) directly, you work with `LastEvaluatedKey` instead.

---

## `--consistent-read`

DynamoDB replicates writes across nodes. A read immediately after a write may return the old value (eventually consistent). Use `--consistent-read` when you need the latest data.

```bash
ddb query \
  --table-name learn_orders \
  --key-condition-expression "customer_id = :cid" \
  --expression-attribute-values '{":cid":{"S":"cust#002"}}' \
  --consistent-read
```

Constraints:
- Only available on the base table and LSIs — **not on GSIs**.
- Costs twice the read capacity of an eventually consistent read in production.
- On Local the distinction has no effect (single process, no replication lag).

---

## ExpressionAttributeNames and ExpressionAttributeValues

Every expression (key condition, filter, projection, update, condition) shares the same aliasing conventions:

| Alias prefix | Purpose |
|---|---|
| `#name` | Placeholder for an attribute name — required for reserved words, optional elsewhere |
| `:value` | Placeholder for a value — always required; never embed literals directly |

Both are passed as JSON maps. The CLI merges them across all expressions in a single call.

```bash
--expression-attribute-names '{"#s":"status","#p":"product"}'
--expression-attribute-values '{":s":{"S":"shipped"},":min":{"N":"100"}}'
```

---

## Scenario: two access patterns, no scan

**Pattern 1:** List all orders for `cust#001`, newest (by `order_id`) first.

```bash
ddb query \
  --table-name learn_orders \
  --key-condition-expression "customer_id = :cid" \
  --expression-attribute-values '{":cid":{"S":"cust#001"}}' \
  --projection-expression "order_id, product, #s, total_usd" \
  --expression-attribute-names '{"#s":"status"}' \
  --scan-index-forward false
```

**Pattern 2:** List all orders with `status = shipped` across all customers.

```bash
ddb query \
  --table-name learn_orders \
  --index-name status-order-index \
  --key-condition-expression "#s = :s" \
  --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":s":{"S":"shipped"}}' \
  --projection-expression "customer_id, order_id, product, total_usd"
```

Both patterns read only the items they return. Neither touches items they don't care about.

---

## Cleanup

```bash
ddb delete-table --table-name learn_orders
```

---

## Gotchas / Docker notes

- **`query` without a partition key errors.** The API returns `ValidationException: Either the KeyConditions or KeyConditionExpression parameter must specify a partition key element`. You cannot query a table "broadly" — that is what scan is for.
- **Filter is post-read.** A filter on a scanned 1 M-item table still reads all 1 M items. Design your keys and indexes to avoid this.
- **`--max-items` is a CLI-level limit**, not a raw DynamoDB `Limit`. The underlying API may return fewer items per network round-trip; the CLI aggregates pages up to `--max-items`. This is why `Count` may be larger than the number of `Items` returned.
- **GSI `--consistent-read` throws.** `ValidationException: Consistent reads are not supported on global secondary indexes`. Use the base table if you need strong consistency.
- **`--scan-index-forward` only works on `query`.** Scan has no inherent sort order — items arrive in arbitrary partition order.
- **Parallel scan.** For large table exports you can run multiple scan workers concurrently with `--total-segments N --segment K` (where K = 0..N-1). Each segment covers a disjoint subset of the table.

---

## See also

- [00-connect.md](00-connect.md) — sidecar setup and `ddb` helper
- [01-tables-indexes.md](01-tables-indexes.md) — table design and GSI creation
- [02-crud-items.md](02-crud-items.md) — writing the items you query
- [04-security.md](04-security.md) — IAM conditions that restrict which partition keys a caller can query
