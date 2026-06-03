# Backend Runtime Migration: TypeScript → Go + Rust

**Status**: active migration  
**Rule**: TypeScript leaves the *backend runtime* and stays only as the *product surface* (SDK, dashboard, playground, docs tooling).

The current `mini-baas-infra` backend is 14 NestJS apps sharing one Node image
([src/Dockerfile](../../apps/baas/mini-baas-infra/src/Dockerfile)). Each app costs
~128 MB and ~900 ms cold start. The migration replaces that runtime with two
focused runtimes:

- **Rust** owns the data plane (anything that holds connections and moves data).
- **Go** owns the control plane (orchestration, registries, lifecycle).

TypeScript backend services are deleted **only after** their Go/Rust replacement
is live, contract-compatible, shadow-tested, and proven to reduce memory.

## Runtime Boundary

```text
TypeScript  →  product surface (SDK, dashboard, playground)   ← never holds DB connections
Go          →  control plane   (registries, lifecycle, admin) ← decides WHAT happens
Rust        →  data plane      (execution, pools, hot paths)  ← executes data operations
```

`Go may tell Rust what to execute. Go must not execute tenant data queries directly.`

## Migration Matrix

| TS service | Hotness | Target | Why | Replacement | Deletion gate |
|---|---|---|---|---|---|
| query-router | very high | **Rust** | per-op `new Client()`/`new MongoClient()`, hot path, needs pools + tx + local PDP | `data-plane-router` | parity + memory + Kong cutover |
| outbox-relay | high | **Rust** | background polling, retries, backpressure, data movement | `data-plane-relay` crate | parity + no event loss |
| query-router outbox writer | high | **Rust** | transactional outbox INSERT on hot path | `data-plane-outbox` crate | parity |
| saga-coordinator | medium-high | **Rust** | compensation execution = data movement | `data-plane-saga` crate | parity |
| mongo-api | medium | **Rust** | CRUD proxy = data movement | router mongo routes | parity |
| adapter-registry | medium | **Go** | CRUD + AES-GCM credential store, control plane | `control-plane/adapterregistry` | parity + crypto byte-compat |
| permission-engine (admin/bundles) | high | **Go** | policy CRUD + bundle publishing is control plane | `control-plane/policy` | parity |
| permission-engine (decision runtime) | high | **Rust** | per-row PDP belongs next to execution | `data-plane-policy` crate | parity |
| schema-service | medium | **Go** | DDL orchestration + text transform | `control-plane/schema` | parity |
| session-service | medium | **Go** | CRUD + TTL pruning | `control-plane/session` | parity |
| storage-router | low-med | **Go** | presign + metadata is orchestration (streaming stays out of Node) | `control-plane/storage` | parity |
| log-service | minimal | **Go** | buffer + flush | `control-plane/logsink` | parity |
| analytics-service | low | **Go** | event aggregation | `control-plane/analytics` | parity |
| email-service | low | **Go** | SMTP orchestration | `control-plane/email` | parity |
| newsletter-service | low | **Go** | batch orchestration | `control-plane/newsletter` | parity |
| gdpr-service | low | **Go** | deletion/export workflow | `control-plane/gdpr` | parity |
| ai-service | low | **Go** | LLM proxy orchestration | `control-plane/ai` | parity |
| libs/common, libs/database, libs/health | — | **delete last** | only after every app moved | — | no remaining NestJS app |
| apps/baas/sdk | — | **keep TypeScript** | product surface, not backend runtime | — | never |

## Order Of Operations

1. Stand up the Go control plane and Rust data plane **beside** NestJS (shadow profiles).
2. Replace control-plane services first (lower risk): `adapter-registry` → Go.
3. Replace data-plane hot path: `query-router` Postgres/Mongo execution → Rust pools.
4. Shadow-route, compare responses, compare `docker stats`.
5. Switch Kong upstream per route.
6. Remove the service from Compose / Kong / Makefile / `nest-cli.json` / `package.json`.
7. Delete the `src/apps/<service>` directory.
8. Delete shared `src/libs/*` and the Node `src/Dockerfile` only when no NestJS app remains.

## Why Not One Language

| Concern | TypeScript | Go | Rust |
|---|---|---|---|
| product iteration / SDK | best | ok | poor |
| control-plane orchestration | ok | best | ok |
| long-lived pools + tx handles | weak | ok | best |
| predictable latency (no GC pause) | no | partial | yes |
| per-row policy at hot path | weak | ok | best |
| memory per service | ~128 MB | ~32–40 MB | ~16–96 MB |

The split is aligned with system physics, not language preference.

## Where The New Code Lives

- Go control plane: [apps/baas/mini-baas-infra/go/control-plane](../../apps/baas/mini-baas-infra/go/control-plane)
- Rust data plane: [apps/baas/mini-baas-infra/docker/services/data-plane-router](../../apps/baas/mini-baas-infra/docker/services/data-plane-router)
- Rust realtime kernel (reused): [apps/baas/mini-baas-infra/docker/services/realtime/realtime-agnostic](../../apps/baas/mini-baas-infra/docker/services/realtime/realtime-agnostic)
