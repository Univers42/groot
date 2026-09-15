# TypeScript Substitution Audit — what dies, when, why

**Date**: 2026-06-02
**Trigger**: R3 (Mongo Rust adapter) landed; the Rust data-plane now executes
both PostgreSQL and MongoDB through long-lived per-mount pools.
**Question this answers**: which TypeScript code is now redundant, what kept
us from deleting it today, and what makes it safely deletable next.

This is the inverse of `agnostic-vs-incumbents.md`: that one tells you what
the BaaS does well. This one tells you which TS lines are scheduled for
demolition and why we did not pull the trigger yet.

## TL;DR

| Bucket | Lines | Status | Why not deleted today |
|---|---|---|---|
| `postgresql.engine.ts` + `mongodb.engine.ts` (TS) | **455** | Destruction unblocked | Need shadow-parity run with `RUST_DATA_PLANE_FORWARD=1` to prove behaviour matches before deleting |
| 6 sidecar engines (jdbc/cassandra/neo4j/elasticsearch/qdrant/influx) | 399 | **Keep** | Audited — they are not duplicated, each speaks a genuinely different remote protocol (Cypher, ES DSL, flux, REST). Template Method would add abstraction, not remove duplication |
| `remote-engine-utils.ts` | 117 | **Keep** | Every exported symbol has 5-28 call sites |

## What changed this slice

Two new components turned "speedup" from a wish into a flippable env flag:

### 1. Rust `MongoEngineAdapter` (R3)

[`apps/baas/mini-baas-infra/docker/services/data-plane-router/crates/data-plane-pool/src/mongo.rs`](../../apps/baas/mini-baas-infra/docker/services/data-plane-router/crates/data-plane-pool/src/mongo.rs)
— 393 lines. Implements `EngineAdapter` + `EnginePool`. Uses:

- `mongodb` 2.8 driver (rustls-native), which owns its own per-Client pool.
- One `Arc<mongodb::Client>` per `DatabaseMount::pool_key()` cached in
  `DefaultPoolRegistry` — connect cost paid once per (tenant, project, mount,
  credential_version).
- `futures::TryStreamExt` cursor draining → no full-collection materialisation.
- `bson::Document` via zero-copy `serde_json::Value ↔ Bson` round-trip.
- Server-side `owner_id` + `tenant_id` re-injection on every doc — a forged
  document body cannot leak across tenants even if it sets those fields.
- Fail-closed second line: pool rejects requests where `identity.tenant_id !=
  pool.tenant_id` even though the dispatcher already checked it.

Patterns: **Adapter** (GoF) for the engine surface, **Object Pool** (built
into the driver), **Strategy** in `DefaultPoolRegistry` (one `Arc<dyn
EngineAdapter>` per engine, no `match` in the dispatch path), **Template
Method** for `build_tenant_filter` / `build_owned_doc` shared across all
read/write code paths.

### 2. TS `RustDataPlaneProxy`

[`apps/baas/mini-baas-infra/src/apps/query-router/src/proxy/rust-data-plane.proxy.ts`](../../apps/baas/mini-baas-infra/src/apps/query-router/src/proxy/rust-data-plane.proxy.ts)
— 130 lines. Built so the Nest `QueryService` can hand off PG + Mongo work to
Rust without touching the in-process TS adapters. Wired as a **Strategy**:

```ts
if (this.rustProxy.shouldForward(engine)) {
  result = await this.rustProxy.execute(/* envelope */);
} else {
  const adapter = this.resolveAdapter(engine);
  result = await adapter.execute(connection_string, resource, op, opts);
}
```

`shouldForward` is true only when `RUST_DATA_PLANE_FORWARD=1` **and** the
engine is in `RUST_DATA_PLANE_FORWARD_ENGINES` (default
`postgresql,mongodb`). Default Compose ships with both unset → behaviour
identical to today.

## Why we did **not** delete TS PG/Mongo engines yet

Deletion is *unblocked*, not *executed*. Required gates before removal:

1. **`m18-rust-data-plane.sh --live`** must pass with
   `DATA_PLANE_ROUTER_PRODUCT_MODE=enabled` — proving the Rust router actually
   serves real queries end-to-end (currently only static checks + cargo
   build).
2. **Shadow parity**: same request through TS adapter and Rust proxy must
   return the same `rows` + `rowCount` for the canonical M3 fixtures.
3. **CI green** with `RUST_DATA_PLANE_FORWARD=1` set, so PRs cannot regress
   the forward path without us noticing.

Once those three are checked, deletion is purely mechanical:

```
git rm apps/baas/mini-baas-infra/src/apps/query-router/src/engines/postgresql.engine.ts
git rm apps/baas/mini-baas-infra/src/apps/query-router/src/engines/mongodb.engine.ts
# and the corresponding imports + providers in query.module.ts + query.service.ts
```

That deletion is **~455 lines of TypeScript** plus their entries in
`query.service.ts`'s adapter registry. Net effect on the hot path:

| Path | Before | After deletion |
|---|---|---|
| PG INSERT | `new pg.Client({…}).connect().query(…).end()` per call | persistent `deadpool-postgres` pool in Rust, RLS GUCs re-applied per checkout |
| Mongo READ | `new MongoClient(…).connect().find().toArray().close()` per call | persistent `mongodb::Client` pool in Rust, cursor streamed via `TryStreamExt` |

This is the "fastest use" the user asked for. The mechanism is shipped today;
the cutover flag flip + deletion is one PR away.

## Why we did **not** Template-Method-refactor the 6 sidecar engines

[Earlier reasoning landed on a Template Method abstraction but a careful
read killed it.] The 6 sidecar engines look duplicated at the surface — same
imports, same NestJS decorators, same call to `fetchJson` — but each one
encodes a genuinely different remote protocol:

| Engine | Wire shape | Specific concerns |
|---|---|---|
| `jdbc` | `POST /execute` sidecar (custom) | Generic; dialect rejected at upsert |
| `cassandra` | REST: `/v2/keyspaces/{ks}/{table}` with `?where=…` | Requires `keyspace` in connection string |
| `neo4j` | Cypher via `/db/{db}/tx/commit`, `MATCH (n:label {…}) RETURN n` | Per-op statement template + custom `rowsFromNeo4j` |
| `elasticsearch` | ES Query DSL: `_search` with `{bool:{filter:[…]}}`, `_update/{id}` | Hit normalisation `{_id, _source}` → flat |
| `qdrant` | Vector REST: `/collections/{coll}/points/scroll` | Requires `data.vector`; payload-vs-vector split |
| `influx` | Flux query + line-protocol writes | Write-only via line-protocol; update/delete refused |

The shared scaffolding (NestJS injectable, `validateResourceName`,
`fetchJson`, owner injection) is already extracted into
`remote-engine-utils.ts` and is heavily used (28 call sites for
`fetchJson`). Pulling a base class out of the per-op switch statements would
add an indirection (subclass route table → `execute()` dispatch → fetchJson)
without removing real behaviour — every engine would still need its own
6-case switch because each one's URL and payload shape is different.

The Engineering rule we followed: **abstraction only when removing
duplication, not when hiding variation**.

## What dies in subsequent slices

| Slice | What dies | Trigger | Estimated TS lines killed |
|---|---|---|---|
| **Next (R6 shadow + cutover)** | `postgresql.engine.ts` + `mongodb.engine.ts` + their imports + 2 providers in `query.module.ts` | `RUST_DATA_PLANE_FORWARD=1` default + green shadow parity | **~470** |
| **R7 (MySQL Rust adapter)** | `mysql.engine.ts` | Add Rust `MysqlEngineAdapter`, register, then delete TS | **~281** |
| **R8 (Redis + HTTP Rust adapters)** | `redis.engine.ts`, `http.engine.ts` | Same pattern | **~534** |
| **R9 (sidecar engines)** | 6 sidecar engines remain (or get fully Rust-ported, depending on demand) | Only after R6-R8 stabilise — they're not on the hot path | ~399 conditional |

After R8 the TS query-router becomes a thin authentication + ABAC + outbox
shell that forwards every CRUD call to Rust. That's the right shape: TS for
business glue, Rust for the data plane.

## Verification

All gates green after this slice:

```bash
make baas-verify-all       # M1 → M10 (foundation) still green
make verify-productization # M11 + M12 + M18 + M19
```

`m18` now asserts:

- Rust workspace + 9 crate contracts + Mongo adapter exports
- `MongoEngineAdapter` + `MongoPool` implementations exist
- `execute_query` routes PG **and** Mongo through `PoolRegistry`
- TS `RustDataPlaneProxy` exists, has `shouldForward`, honours
  `RUST_DATA_PLANE_FORWARD`, forwards to `/v1/query`
- `QueryService` calls `rustProxy.shouldForward` then `rustProxy.execute`
- `QueryModule` registers `RustDataPlaneProxy` as a provider

## Files touched

| File | Action | Lines |
|---|---|---|
| `apps/baas/mini-baas-infra/docker/services/data-plane-router/Cargo.toml` | + `mongodb 2.8`, `bson 2.10`, `futures 0.3` | +3 |
| `…/crates/data-plane-pool/Cargo.toml` | + same as deps | +5 |
| `…/crates/data-plane-pool/src/mongo.rs` | **new** — MongoEngineAdapter + MongoPool | +393 |
| `…/crates/data-plane-pool/src/lib.rs` | export `MongoEngineAdapter` | +5 |
| `…/crates/data-plane-server/src/routes.rs` | add Mongo to registry list, drop pg-only guard | +6/-3 |
| `…/crates/data-plane-server/src/server.rs` | simplified, registry now built inside `AppState::new` | -10 |
| `apps/baas/mini-baas-infra/src/apps/query-router/src/proxy/rust-data-plane.proxy.ts` | **new** — RustDataPlaneProxy | +130 |
| `…/src/query/query.module.ts` | provider + import | +2 |
| `…/src/query/query.service.ts` | Strategy dispatch on `rustProxy.shouldForward` | +27/-2 |
| `apps/baas/mini-baas-infra/scripts/verify/m18-rust-data-plane.sh` | assert Mongo adapter + proxy class | +30 |

**Net**: ~600 TS+Rust lines added today, ~470 TS lines unblocked for deletion
next slice. The unblocking is more valuable than the addition — without the
proxy we could not safely flip the hot path.

## Related

- [`secure-baas-runtime-migration.md`](./secure-baas-runtime-migration.md) — full R0→R8 plan
- [`secure-baas-verification-plan.md`](./secure-baas-verification-plan.md) — gate catalogue (M1-M19 today)
- [`agnostic-vs-incumbents.md`](./agnostic-vs-incumbents.md) — what we claim publicly
