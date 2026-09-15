# Transactions, ACID And Saga Design

**Design goal**: provide complete and honest transaction semantics: native ACID inside one capable engine, explicit 2PC only where supported, and saga/outbox for heterogeneous cross-engine workflows.

## Hard Boundary

There is no universal ACID transaction across arbitrary database engines. Product wording must be precise:

> Per-engine ACID transactions with a unified API, plus saga-based cross-engine consistency.

Cross-engine atomicity exists only when all participants support a compatible prepare/commit protocol and the platform accepts the coordinator failure modes. Otherwise the correct model is saga: eventual consistency with compensation, idempotency and observability.

## Current State

Single operations are wrapped in short engine-local logic. PostgreSQL begins and commits around one `execute()` when `userId` is present in [postgresql.engine.ts](../../apps/baas/mini-baas-infra/src/apps/query-router/src/engines/postgresql.engine.ts). MongoDB creates a `MongoClient` per call and does not use `ClientSession` in [mongodb.engine.ts](../../apps/baas/mini-baas-infra/src/apps/query-router/src/engines/mongodb.engine.ts).

Outbox and saga foundations exist in [outbox.service.ts](../../apps/baas/mini-baas-infra/src/apps/query-router/src/query/outbox.service.ts), [outbox-relay.service.ts](../../apps/baas/mini-baas-infra/src/apps/outbox-relay/src/outbox-relay.service.ts), and [saga-coordinator.service.ts](../../apps/baas/mini-baas-infra/src/apps/outbox-relay/src/saga-coordinator.service.ts). The gap is a first-class transaction/session API and formal saga definitions.

## HTTP Transaction Session API

Expose transaction sessions for engines with `transactions: true`:

```http
POST /query/v1/tx
{
  "database_id": "...",
  "isolation": "serializable",
  "timeout_ms": 30000,
  "idempotency_key": "..."
}

POST /query/v1/tx/:txId/ops
{
  "op": "insert",
  "resource": "orders",
  "data": { ... }
}

POST /query/v1/tx/:txId/commit
POST /query/v1/tx/:txId/rollback
```

The `txId` references a pinned engine transaction handle. It must route to the same query-router instance unless the transaction coordinator is externalized.

## Sticky Routing Constraint

Open transactions hold a pinned connection/session in one process. Options:

| Option | Pros | Cons |
|---|---|---|
| Single query-router coordinator | easiest for MVP | no horizontal scale for tx API |
| Kong consistent hash on `txId` | scales horizontally | needs route config and txId affinity |
| External transaction coordinator | strongest model | more infrastructure and failure handling |

For the next milestone, use sticky routing by `txId` or keep the tx API behind one coordinator instance. Document this explicitly.

## Idle Transaction Reaper

Every transaction must have:

- `created_at`
- `last_activity_at`
- `deadline_at`
- `tenant_id`
- `user_id`
- `database_id`
- `engine`
- current state: `open`, `committing`, `committed`, `rolling_back`, `rolled_back`, `expired`

A reaper auto-rolls back transactions idle beyond `TX_IDLE_TIMEOUT_MS`. This protects the pool from clients that open transactions and disappear.

## Transaction State Table

Even when the handle lives in memory, record state durably:

```sql
CREATE TABLE public.transaction_sessions (
  id uuid primary key,
  tenant_id uuid not null,
  project_id uuid not null,
  database_id uuid not null,
  engine text not null,
  router_instance_id text not null,
  isolation text,
  state text not null,
  idempotency_key text,
  created_at timestamptz not null default now(),
  last_activity_at timestamptz not null default now(),
  deadline_at timestamptz not null,
  committed_at timestamptz,
  rolled_back_at timestamptz
);
```

This table enables debugging, reaper coordination and future distributed coordinator work.

## Per-Engine ACID Semantics

| Engine | Per-engine transaction claim |
|---|---|
| PostgreSQL | full ACID using pinned `PoolClient`, isolation levels, optional savepoints |
| MySQL/InnoDB | full ACID with pinned connection, isolation levels, optional savepoints |
| MongoDB replica set | multi-document transactions using `ClientSession.withTransaction()` with snapshot semantics |
| Redis | atomic command/Lua/MULTI blocks, not general ACID transactions |
| Cassandra | no general ACID; logged batch is not a relational transaction |
| HTTP/JDBC remote | only if remote mount advertises tx protocol |

Capabilities must reflect this precisely.

## Cross-Engine Coordinator

For a workflow touching multiple mounts:

1. Resolve all participants and capabilities.
2. If every participant supports `twoPhaseCommit: true`, run 2PC only if the tenant/project enables that mode.
3. Otherwise create a saga instance.
4. Execute each step with idempotency key.
5. Write outbox events in the local transaction of each step where possible.
6. On failure, run compensations in reverse order.
7. Expose saga state to the tenant.

## Saga Definition Contract

```ts
interface SagaDefinition {
  name: string;
  tenantId: string;
  version: number;
  steps: Array<{
    name: string;
    databaseId: string;
    op: DataOp;
    compensation?: DataOp;
    retry: { maxAttempts: number; backoffMs: number };
  }>;
}
```

Persist saga runs:

```sql
saga_instances(id, tenant_id, name, version, state, idempotency_key, created_at, updated_at)
saga_steps(id, saga_id, step_name, state, attempts, result, last_error, compensated_at)
```

## Idempotency Ledger

Idempotency cannot live only in Redis for product-grade workflows. Use durable storage:

```sql
idempotency_keys (
  tenant_id uuid not null,
  key text not null,
  request_hash text not null,
  status text not null,
  response jsonb,
  expires_at timestamptz not null,
  primary key (tenant_id, key)
)
```

Redis can remain a fast cache; Postgres is the source of truth for mutation replay.

## ACID Claim Matrix

Every public route should declare its consistency class:

| Route | Consistency class |
|---|---|
| `/query/v1/:db/:resource` single write | atomic within one adapter call; outbox best-effort unless wrapped in engine-local transaction |
| `/query/v1/tx/*` | ACID per engine where supported |
| `/query/v1/saga/*` | eventual consistency with compensation |
| `/rest/v1/*` PostgREST | Postgres-only request transaction, not cross-engine, not router ABAC unless explicitly integrated |

This avoids the current dual data-plane ambiguity between PostgREST and query-router.

## Migration Plan

1. Implement adapter SPI V2 with `begin`, `commit`, `rollback` for PostgreSQL.
2. Add `transaction_sessions` table and in-memory handle registry.
3. Add tx API endpoints in query-router.
4. Add idle reaper and pool metrics.
5. Implement MongoDB transaction sessions for replica-set mounts.
6. Add saga definition tables and API.
7. Add durable idempotency ledger.
8. Decide whether PostgREST remains an optional Postgres read fast-path or is hidden behind the router for coherent semantics.

## Acceptance Criteria

- `insert A`, `insert B`, `commit` can span multiple HTTP calls on one Postgres mount.
- Idle transactions are auto-rolled back and release their pinned connection.
- A cross-engine request clearly reports `consistency: saga`, not `acid`.
- Retrying the same mutation idempotency key does not double-apply side effects.
- A crashed outbox relay can resume without losing or duplicating published saga intent.
