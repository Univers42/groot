# Runtime Language Split And Rust Migration

**Status**: migration plan plus first scaffold  
**Decision**: TypeScript, Go and Rust are allowed, but each runtime owns a different layer.

This is not a rewrite plan. The current NestJS backend remains alive while the hot data plane is extracted into Rust. Go is introduced only where it gives clear orchestration value and only after contracts are stable enough to avoid duplicating business logic.

## Boundary Rule

```text
TypeScript = product surface
Go = control plane
Rust = data plane
```

The product should never mix languages randomly. Each runtime gets one job:

| Layer | Runtime | Owns | Must not own |
|---|---|---|---|
| Product surface | TypeScript | SDK, dashboard, playground, docs tooling, developer-facing APIs | hot query execution, pool ownership, tenant isolation enforcement |
| Control plane | Go | tenant lifecycle, billing, config distribution, service orchestration, lightweight internal APIs | direct database execution for tenant data |
| Data plane | Rust | query execution, adapter SPI, pools, transaction sessions, local PDP, realtime, hot path metrics | billing, product UI, dashboard workflows |

## Why This Fits This BaaS

The current TypeScript/NestJS services were useful to bootstrap M1-M10 quickly. They are less ideal for the next product phase because the data plane now needs long-lived pools, low memory overhead, predictable latency, local policy decisions, transaction handles, backpressure and tenant quotas.

Rust is the best target for that part because the BaaS already has a Rust realtime kernel and because the query path is infrastructure work, not product CRUD glue. Go can become the control-plane runtime later because it is simpler than Rust for orchestration services and cheaper than NestJS for long-running internal APIs.

## Do Not Migrate Everything At Once

The migration must stay boring and reversible:

1. Keep the current NestJS services as the source of truth for existing routes.
2. Add the Rust `data-plane-router` beside the Nest `query-router` in shadow mode.
3. Define request/response contracts before moving execution.
4. Implement Postgres and Mongo pools first.
5. Add local PDP bundle enforcement in Rust.
6. Add transaction sessions in Rust.
7. Route a small subset through Rust, compare behavior, then increase traffic.
8. Move Go control-plane pieces only after the Rust data-plane contract stabilizes.

## Migration Phases

| Phase | Runtime | Work | Exit criteria |
|---|---|---|---|
| R0 | Docs | language ownership, migration guardrails | roadmap says where TypeScript, Go and Rust belong |
| R1 | Rust | scaffold `data-plane-router` with health, capabilities, query and tx contracts | `m18-rust-data-plane.sh` passes |
| R2 | Rust | implement `EngineAdapter`, `EnginePool`, `TxHandle`, `PoolRegistry` traits | Postgres/Mongo pool tests pass without per-query client creation |
| R3 | Rust | Postgres and Mongo execution adapters | read/write parity against Nest query-router for selected resources |
| R4 | Rust | local PDP bundle evaluator | permission-engine outage does not create allow-by-default behavior |
| R5 | Rust | transaction session API | commit/rollback/reaper tests pass per engine |
| R6 | Rust + Kong/Nest | shadow routing and gradual cutover | Rust and Nest responses match for promoted operations |
| R7 | Go | extract stable orchestration/control APIs if needed | Go owns orchestration only, not data execution |
| R8 | Rust or Go | migrate outbox/saga only if profiling justifies it | latency and memory metrics improve measurably |

## First Scaffold

The first Rust service lives at:

```text
apps/baas/mini-baas-infra/docker/services/data-plane-router
```

It exposes:

| Route | Purpose | Current behavior |
|---|---|---|
| `GET /v1/health` | liveness for Compose and smoke checks | returns service/version/mode |
| `GET /v1/capabilities` | advertises Rust router and engine capability contracts | returns Postgres and Mongo descriptors |
| `POST /v1/query` | future normalized data operation entrypoint | validates contract, then returns `501` |
| `POST /v1/transactions` | future transaction session entrypoint | validates contract, then returns `501` |
| `POST /v1/transactions/:tx_id/commit` | future commit endpoint | returns `501` |
| `POST /v1/transactions/:tx_id/rollback` | future rollback endpoint | returns `501` |

Returning `501` is intentional at R1. The service proves the boundary and contract without silently executing incomplete data-plane logic.

## Go Comes Later

Go should not be introduced just because it is efficient. It should enter when there is a stable orchestration contract to own:

- tenant provisioning workflow,
- config distribution,
- key rotation orchestration,
- module manifest rendering,
- saga orchestration if Rust does not need to own it.

The rule is strict:

```text
Go may tell Rust what to execute.
Go must not execute tenant data queries directly.
```

That keeps the product from splitting security semantics across two execution engines.

## Verification

Run:

```bash
make verify-rust-data-plane
```

or directly:

```bash
bash apps/baas/mini-baas-infra/scripts/verify/m18-rust-data-plane.sh
```

The gate verifies the docs, the Rust workspace, the Compose shadow service, core contracts and `cargo check`.
