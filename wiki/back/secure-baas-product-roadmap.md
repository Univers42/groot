# Secure BaaS Product Roadmap

**Status**: design roadmap, not an implementation claim  
**Scope**: `apps/baas/mini-baas-infra`, `apps/baas/sdk`, Kong, Compose, Rust realtime  
**Goal**: turn the current school-grade but serious backend into a defensible multi-tenant BaaS product.

This document is deliberately stricter than the milestone reports. The milestone gates prove that the current stack works. Productization asks a harder question: can unrelated customers safely run different apps on the same platform, with a unified data API, tenant isolation, predictable transactions, ABAC, realtime, observability, and clean module activation?

## Current Truth

The backend already has real building blocks:

| Area | Current code | Good part | Product gap |
|---|---|---|---|
| Gateway identity | [kong.yml](../../apps/baas/mini-baas-infra/docker/services/kong/conf/kong.yml) + [auth.guard.ts](../../apps/baas/mini-baas-infra/src/libs/common/src/guards/auth.guard.ts) | Kong verifies JWT on protected routes and injects identity headers | Upstreams trust unsigned headers; internal callers can forge `X-User-Id` |
| Tenant databases | [databases.service.ts](../../apps/baas/mini-baas-infra/src/apps/adapter-registry/src/databases/databases.service.ts) | BYO database registry exists and encrypts connection strings | Tenant is still often treated as `userId`; plaintext connection strings cross service boundaries |
| Data plane | [query.service.ts](../../apps/baas/mini-baas-infra/src/apps/query-router/src/query/query.service.ts) + [adapter.contract.ts](../../apps/baas/mini-baas-infra/src/libs/database/src/adapter.contract.ts) | Adapter map is already in place; ABAC is called before `adapter.execute()` | No pool registry, no transaction sessions, connection lookup per query |
| Per-engine operations | [postgresql.engine.ts](../../apps/baas/mini-baas-infra/src/apps/query-router/src/engines/postgresql.engine.ts), [mongodb.engine.ts](../../apps/baas/mini-baas-infra/src/apps/query-router/src/engines/mongodb.engine.ts) | CRUD works behind one DTO | Engines open clients per call; no pinned connection/session API |
| ABAC | [decisions.service.ts](../../apps/baas/mini-baas-infra/src/apps/permission-engine/src/decisions/decisions.service.ts) + [007_permissions_system.sql](../../apps/baas/mini-baas-infra/scripts/migrations/postgresql/007_permissions_system.sql) | Central PDP endpoint exists and fail-closed path exists | PDP is remote per query; conditions are mostly recorded, not fully evaluated locally |
| Cross-engine consistency | [outbox.service.ts](../../apps/baas/mini-baas-infra/src/apps/query-router/src/query/outbox.service.ts), [outbox-relay.service.ts](../../apps/baas/mini-baas-infra/src/apps/outbox-relay/src/outbox-relay.service.ts), [saga-coordinator.service.ts](../../apps/baas/mini-baas-infra/src/apps/outbox-relay/src/saga-coordinator.service.ts) | Transactional outbox and saga shell exist | Needs formal saga definitions, idempotency ledger, compensation contracts, replay semantics |
| Realtime | [realtime-client.ts](../../apps/baas/sdk/src/domains/realtime-client.ts), [server.rs](../../apps/baas/mini-baas-infra/docker/services/realtime/realtime-agnostic/crates/realtime-server/src/server.rs) | Rust realtime engine is a good kernel; SDK speaks `AUTH`/`SUBSCRIBE` | Topics need tenant/app namespace, ACL, quota, replay and product-level guarantees |
| Modules | [docker-compose.yml](../../apps/baas/mini-baas-infra/docker-compose.yml), [kong.yml](../../apps/baas/mini-baas-infra/docker/services/kong/conf/kong.yml) | Services are already split | Compose and Kong are static; optional modules still leave dead routes or manual edits |

## The Non-Negotiable Product Claims

These are the claims the product can safely make after the roadmap is implemented:

1. **Per-engine ACID**: one transaction touching one capable engine is ACID and uses that engine's native transaction semantics.
2. **Cross-engine consistency**: multi-engine workflows use saga + transactional outbox. They are observable, idempotent and compensatable, but not ACID unless every participant supports a real prepare/commit protocol.
3. **Engine agnosticism**: engines mount through a driver SPI with capability negotiation. Unsupported semantics are rejected before execution.
4. **Tenant isolation**: every request has a verified `tenant_id`, separate from `user_id`, and every control-plane table is tenant-scoped.
5. **Security kernel**: auth, tenant resolution, PDP, audit, idempotency, quotas and tracing are not optional modules.
6. **Feature modules**: analytics, newsletter, AI, storage, realtime, GDPR UI, etc. can be enabled/disabled by manifest without weakening the kernel.
7. **Realtime for many apps**: the event plane is tenant/app namespaced, quota-aware, authz-aware and supports multiple producer engines.

## Recommended Document Order

Read these as one architecture pack:

1. [secure-baas-trust-boundary.md](./secure-baas-trust-boundary.md) - signed identity, service-to-service auth, key model.
2. [secure-baas-tenancy-isolation.md](./secure-baas-tenancy-isolation.md) - `tenant_id`, plan tiers, BYO DB, schema/db isolation.
3. [secure-baas-adapter-spi.md](./secure-baas-adapter-spi.md) - hexagonal data-plane, pools, capability matrix.
4. [secure-baas-transactions-acid-saga.md](./secure-baas-transactions-acid-saga.md) - transaction sessions, per-engine ACID, 2PC/saga boundary.
5. [secure-baas-abac-pdp-rls.md](./secure-baas-abac-pdp-rls.md) - local PDP cache, RLS defense-in-depth, policy compilation.
6. [secure-baas-realtime-event-plane.md](./secure-baas-realtime-event-plane.md) - multi-tenant realtime topics, fan-out, replay, quotas.
7. [secure-baas-module-system.md](./secure-baas-module-system.md) - kernel + module manifests, generated Kong/Compose/SDK capability discovery.
8. [secure-baas-verification-plan.md](./secure-baas-verification-plan.md) - gates, migration plan, acceptance criteria.
9. [secure-baas-runtime-migration.md](./secure-baas-runtime-migration.md) - TypeScript/Go/Rust ownership and Rust data-plane migration.

## Product Architecture Target

```text
Client SDK
  |
  | tenant-scoped anon/service key + JWT
  v
Kong / WAF
  | verifies JWT or API key
  | signs identity envelope
  v
Security Kernel Middleware
  | verifies signed headers or JWT
  | resolves tenant_id + user_id + app_id
  | enforces quota + idempotency + audit context
  v
Query Router / Transaction Coordinator
  | local PDP decision
  | adapter SPI
  | tx sessions and pool registry
  v
Engine Adapters
  | Postgres / MongoDB / MySQL / Redis / HTTP / JDBC / Cassandra / ...
  | native tx where available
  v
Outbox + Saga + Realtime
  | durable event log
  | compensations
  | tenant/app namespaced fan-out
```

## Implementation Priority

| Priority | Work | Why first |
|---|---|---|
| P0 | Signed identity envelope and real `tenant_id` propagation | Without this, every other security feature rests on forgeable headers |
| P0 | Control-plane tenant model and scoped keys | Prevents one customer/app from becoming the whole trust domain |
| P1 | Adapter SPI v2 with pools and transaction handles | Eliminates per-query connection setup and unlocks ACID sessions |
| P1 | Rust data-plane-router in shadow mode | Starts the hot-path migration without replacing NestJS routes prematurely |
| P1 | Transaction session API | Makes the data plane a real BaaS instead of single-operation proxy |
| P1 | Local PDP cache in query-router | Makes ABAC mandatory without adding one network hop per row operation |
| P2 | Saga definition registry and idempotency ledger | Makes cross-engine workflows retry-safe and explainable |
| P2 | Realtime namespace/ACL/replay model | Allows many tenant apps to share the realtime kernel safely |
| P2 | Go control-plane extraction only after Rust contracts stabilize | Keeps orchestration efficient without duplicating data-plane security logic |
| P3 | Module manifest renderer | Turns modularity into product behavior, not hand-edited Compose/YAML |

## Runtime Strategy

The product should use a three-runtime split, not a full rewrite into one language:

| Runtime | Product role |
|---|---|
| TypeScript | SDK, dashboard, playground, developer-facing surface and fast product iteration |
| Go | future control-plane orchestration such as tenant lifecycle, config distribution, billing and module rendering |
| Rust | data-plane execution, adapter pools, transaction sessions, local PDP, realtime and other hot paths |

The current NestJS services stay alive during migration. Rust starts beside the existing query-router in shadow mode, then earns traffic through parity tests and M18+ gates.

## Claim Policy

Do not say:

> ACID across any database.

Say:

> Unified data API with per-engine ACID transactions where the engine supports them, plus saga-based cross-engine consistency with durable outbox, idempotency and compensating actions.

This is honest, technically defensible, and much stronger than pretending heterogeneous distributed ACID exists without 2PC.
