# Hexagonal Adapter SPI And Pool Registry

**Design goal**: make the query-router a real hexagonal data-plane where engines are mounted drivers, not request-time utility classes.

## Current State

The current adapter contract in [adapter.contract.ts](../../apps/baas/mini-baas-infra/src/libs/database/src/adapter.contract.ts) is already a good start: `IDatabaseAdapter` exposes `engine`, `capabilities()`, `execute()` and `listResources()`. The router registers adapters into a `Map<string, IDatabaseAdapter>` in [query.service.ts](../../apps/baas/mini-baas-infra/src/apps/query-router/src/query/query.service.ts).

The product gap is that `execute()` receives a plaintext connection string on each call and the engines create new clients per call. For example [postgresql.engine.ts](../../apps/baas/mini-baas-infra/src/apps/query-router/src/engines/postgresql.engine.ts) creates `new Client()` and [mongodb.engine.ts](../../apps/baas/mini-baas-infra/src/apps/query-router/src/engines/mongodb.engine.ts) creates `new MongoClient()` inside `execute()`.

## Target Hexagonal Shape

The core data-plane should know only ports and capabilities:

```ts
type IsolationLevel = 'read_committed' | 'repeatable_read' | 'serializable';

interface EngineCapabilities {
  read: boolean;
  write: boolean;
  upsert: boolean;
  stream: boolean;
  ddl: boolean;
  transactions: boolean;
  savepoints: boolean;
  isolationLevels: IsolationLevel[];
  twoPhaseCommit: boolean;
  nativeIdempotency: boolean;
  maxBatchSize: number;
  cost: {
    latencyClass: 'native' | 'adapter' | 'fdw' | 'remote';
    patternSearch: 'native' | 'indexed' | 'limited' | 'scan' | 'remote' | 'none';
    joins: 'native' | 'limited' | 'none';
  };
}

interface EngineAdapter {
  readonly engine: string;
  capabilities(): EngineCapabilities;
  openPool(mount: DatabaseMount): Promise<EnginePool>;
  healthCheck(pool: EnginePool): Promise<EngineHealth>;
}

interface EnginePool {
  readonly mountId: string;
  execute(op: DataOp, ctx: RequestContext): Promise<DataResult>;
  begin(opts: TxOptions, ctx: RequestContext): Promise<TxHandle>;
  close(): Promise<void>;
}

interface TxHandle {
  readonly txId: string;
  readonly mountId: string;
  execute(op: DataOp, ctx: RequestContext): Promise<DataResult>;
  commit(): Promise<void>;
  rollback(): Promise<void>;
  prepare?(): Promise<void>;
}
```

The router depends on `EngineAdapter`, not on Postgres/Mongo implementation details.

## Mounts Instead Of Connection Strings

A mount is the platform-owned description of an engine instance:

```ts
interface DatabaseMount {
  id: string;
  tenantId: string;
  projectId: string;
  engine: string;
  name: string;
  credentialRef: string;
  poolPolicy: {
    min: number;
    max: number;
    idleTtlMs: number;
    maxLifetimeMs: number;
  };
  capabilityOverrides?: Partial<EngineCapabilities>;
}
```

The adapter-registry should return a mount descriptor and a credential reference, not a raw connection string by default. The query-router's credential resolver can exchange that reference for a short-lived credential, ideally from Vault.

## Pool Registry

The query-router needs a per-process pool registry:

```ts
class PoolRegistry {
  getOrCreate(mount: DatabaseMount): Promise<EnginePool>;
  releaseIdle(): Promise<void>;
  closeMount(mountId: string): Promise<void>;
  stats(): PoolStats[];
}
```

Pool key:

```text
tenant_id/project_id/database_id/engine/credential_version
```

When credentials rotate, `credential_version` changes and a new pool is opened while the old one drains.

## Request Flow

```text
query request
  -> verified identity context
  -> registry resolves dbId to DatabaseMount
  -> capability gate rejects unsupported operation
  -> PDP authorizes op/resource
  -> poolRegistry.getOrCreate(mount)
  -> pool.execute(op)
  -> outbox/audit/idempotency hooks
```

This removes the expensive cycle of one HTTP registry call + decrypt + fresh DB connection for every operation. Registry lookups can be cached by `dbId` with a short TTL and invalidated on credential rotation.

## Adapter Implementation Notes

| Engine | Pool | Transaction handle | 2PC |
|---|---|---|---|
| PostgreSQL | `pg.Pool` | pinned `PoolClient` | possible only if prepared transactions are enabled and operationally accepted |
| MongoDB | long-lived `MongoClient` | `ClientSession` | no standard 2PC participant across arbitrary external engines |
| MySQL | `mysql2` pool | pinned `PoolConnection` | XA exists but must be explicitly capability-gated |
| Redis | shared client/pipeline | Lua/MULTI for limited atomicity | no general 2PC |
| HTTP | agent/keepalive | only if remote API exposes tx protocol | no by default |
| Cassandra | session pool | logged batch/lightweight transaction only | no general 2PC |

## Capability Gate

Never silently degrade semantics. If a caller asks for `serializable` and the engine does not support it, reject before execution:

```json
{
  "error": "unsupported_isolation_level",
  "engine": "mongodb",
  "requested": "serializable",
  "supported": ["snapshot"]
}
```

The same applies to joins, pattern searches, upserts, savepoints, streaming and DDL.

## DataOp Shape

The current DTO is enough for CRUD, but product-grade operations need an internal normalized operation:

```ts
interface DataOp {
  op: 'list' | 'get' | 'insert' | 'update' | 'delete' | 'upsert' | 'batch';
  resource: string;
  data?: Record<string, unknown>;
  filter?: Record<string, unknown>;
  sort?: Record<string, 'asc' | 'desc'>;
  limit?: number;
  offset?: number;
  idempotencyKey?: string;
  expectedVersion?: string | number;
  returning?: 'none' | 'changed' | 'full';
}
```

Adapters translate `DataOp` into engine-native commands.

## Migration Plan

1. Add the Rust `data-plane-router` as a shadow service beside the NestJS query-router.
2. Add `DatabaseMount`, `EnginePool`, `TxHandle`, `EngineAdapterV2` contracts in Rust first, then mirror only the stable public DTOs in TypeScript SDK codegen.
3. Implement V2 for PostgreSQL and MongoDB first.
4. Add `PoolRegistry` and registry cache to the Rust router.
5. Route single-operation `executeQuery()` through `pool.execute()` in shadow mode and compare with NestJS responses.
6. Deprecate `execute(connectionString, ...)` once V2 coverage is complete.
7. Expand `EngineCaps` to include transaction and isolation detail.
8. Add metrics: active pools, checked-out connections, idle tx count, pool wait time, registry cache hit rate.

The implementation target for the hot path is Rust. TypeScript remains the SDK/product surface. Go can later own control-plane orchestration, but it must not execute tenant data operations directly.

## Acceptance Criteria

- A hot query path does not decrypt the connection string or open a TCP connection per operation.
- Pool exhaustion returns a controlled 429/503 with tenant context, not a process crash.
- Capability mismatch is rejected before adapter execution.
- Adding a new engine requires registering one adapter provider and SDK capability entry, not editing router control flow.
- Each engine has a live health check through the SPI.
