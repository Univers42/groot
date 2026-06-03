# 04 — Multi-statement Transactions

The Rust data-plane exposes explicit transaction handles for PG and MySQL.
Mongo support is single-statement only today (multi-statement requires a
session-threading refactor — tracked as a follow-up).

## Lifecycle

```http
POST /v1/transactions
  { "mount_id": "...", "isolation": "read_committed" }
  -> 201 { "tx_id": "tx-…", "engine": "postgresql" }

POST /v1/transactions/:tx_id/execute
  { "operation": { "kind": "list", "resource": "orders" } }
  -> 200 { rows: [...] }

POST /v1/transactions/:tx_id/commit   -> 200 { committed: true }
POST /v1/transactions/:tx_id/rollback -> 200 { rolled_back: true }
```

Transactions are pinned to the connection that started them; the registry
in `crates/data-plane-server/src/routes.rs` evicts idle handles after
`TX_IDLE_TTL_SECS` (default 60s).

## Isolation levels

```text
read_uncommitted | read_committed | repeatable_read | serializable
```

Translated per engine:

| Engine | Mapping |
|---|---|
| PostgreSQL | `BEGIN ISOLATION LEVEL <level>` |
| MySQL | `SET TRANSACTION ISOLATION LEVEL <level>; START TRANSACTION` |
| Mongo | n/a (single-statement only) |

## RLS context inside transactions

PG and MySQL set tenant GUCs on the transaction's connection:

```sql
SELECT set_config('app.current_tenant_id', '<tenant>', true);
SELECT set_config('app.current_user_id',   '<user>',   true);
SELECT set_config('request.jwt.claims',    '<claims>', true);
```

These are scoped to the transaction (third arg `true`) so the connection
returning to the pool has no residual tenant context.

## Idempotency

The query-router middleware (`idempotency.middleware.ts`) checks the
`X-Idempotency-Key` header before forwarding. Replays return the cached
response and never reach the data plane. Set
`IDEMPOTENCY_TTL_SECS=86400` (default) to control retention.

## What can break

- **Long-running transactions** hold a connection out of the pool. Default
  per-tenant pool size is 10; a stuck tx is one fewer for everyone.
- **Crash during commit** — the registry doesn't persist tx handles. On
  router restart, all in-flight txs are rolled back implicitly when the
  connection is closed. Clients see a 502 and must retry with a new tx.
- **Mongo "transactions"** in the response shape are stubs that return
  `not_implemented`. Send single ops only until the session refactor lands.
