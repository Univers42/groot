# DynamoDB Local — CLI Learning Notes

DynamoDB Local runs as `mini-baas-dynamodb-local` inside the grobase backend stack; you reach it from the host at `http://localhost:8500` or, from inside the Docker network, at `http://mini-baas-dynamodb-local:8000`. There is no `aws` CLI inside the container — you spin up a disposable `amazon/aws-cli` sidecar joined to the same Docker network and aim it at the local endpoint.

---

## What kind of database is DynamoDB?

DynamoDB is a **key-value / wide-column NoSQL** store, not a relational database. There are no JOINs, no schemas beyond the primary key, and no SQL. Instead you design a single table whose key structure encodes your access patterns up front. The tradeoff: reads of known keys are single-digit milliseconds at any scale; reads that cross partition boundaries require either a **Global Secondary Index** or a full-table **scan** (expensive).

Core concepts at a glance:

| Concept | What it means |
|---|---|
| Partition key (HASH) | Determines the physical node; must be provided for every read/write |
| Sort key (RANGE) | Optional second dimension; enables range queries within a partition |
| Item | A row — a bag of typed attributes; no fixed schema beyond the key |
| GSI | A Global Secondary Index — a new key projection over the whole table |
| LSI | A Local Secondary Index — alternate sort key; must be declared at table creation |

---

## Connect pattern summary

Every command in these notes uses a disposable sidecar:

```bash
docker run --rm \
  --network mini-baas_mini-baas \
  -e AWS_ACCESS_KEY_ID=local \
  -e AWS_SECRET_ACCESS_KEY=local \
  -e AWS_DEFAULT_REGION=us-east-1 \
  amazon/aws-cli dynamodb <subcommand> \
  --endpoint-url http://mini-baas-dynamodb-local:8000
```

Define the `ddb` helper once per shell session to avoid repeating the prefix:

```bash
ddb() {
  docker run --rm -i \
    --network mini-baas_mini-baas \
    -e AWS_ACCESS_KEY_ID=local \
    -e AWS_SECRET_ACCESS_KEY=local \
    -e AWS_DEFAULT_REGION=us-east-1 \
    amazon/aws-cli dynamodb "$@" \
    --endpoint-url http://mini-baas-dynamodb-local:8000
}
```

Then: `ddb list-tables`, `ddb put-item ...`, etc. See [00-connect.md](00-connect.md) for the full rundown.

---

## Sample domain used throughout

All exercises use a shop modeled the DynamoDB way: a `learn_orders` table with **partition key `customer_id` (S)** and **sort key `order_id` (S)**, plus a GSI on `status`. This lets you fetch all orders for a customer in one query, or all orders in a given status via the index — without a relational schema.

**Always use scratch tables prefixed `learn_`.** Drop them when you're done; never touch the production tables `alerts`, `device_events`, `devices`.

---

## File index

| File | What it teaches |
|---|---|
| [00-connect.md](00-connect.md) | Sidecar pattern, `ddb` helper, connectivity checks, host vs network endpoints |
| [01-tables-indexes.md](01-tables-indexes.md) | `create-table`, key design, GSI/LSI, `update-table`, `delete-table` |
| [02-crud-items.md](02-crud-items.md) | `put-item`, `get-item`, `update-item` (SET/ADD/REMOVE), `delete-item`, `batch-write-item`, conditional writes |
| [03-query-scan.md](03-query-scan.md) | `query` vs `scan`, GSI queries, projections, pagination, `--consistent-read` |
| [04-security.md](04-security.md) | IAM model, least-privilege policies, resource ARNs, what Local ignores |
