# Verification And Migration Plan

**Design goal**: convert the secure BaaS roadmap into executable gates so the product claim is continuously proven, not manually argued.

## Verification Philosophy

Each architecture claim needs a gate:

| Claim | Gate type |
|---|---|
| signed identity cannot be forged | live negative test |
| tenant isolation works | live two-tenant test |
| query-router uses pools | static + live metric test |
| transaction sessions are ACID per engine | integration test with rollback/commit assertions |
| cross-engine saga is not ACID but compensates | integration test with injected failure |
| ABAC is mandatory | static order check + live deny test |
| realtime topics are tenant-isolated | live two-subscriber test |
| module manifests drive routes | generated config diff test |
| runtime ownership is respected | static architecture gate + Rust/Go build gates |

## New Verify Scripts

Add scripts under `apps/baas/mini-baas-infra/scripts/verify/`:

| Script | Purpose |
|---|---|
| `m11-trust-boundary.sh` | signed headers, rejected forged internal identity, scoped service tokens |
| `m12-tenancy.sh` | tenant/project/app context, RLS tenant separation, per-tenant keys |
| `m13-adapter-spi.sh` | V2 adapter interfaces, pool registry, no per-query `new Client` in hot path |
| `m14-transactions.sh` | tx API, idle reaper, rollback/commit, capability rejection |
| `m15-abac-local-pdp.sh` | policy bundle cache, fail-closed, local decisions |
| `m16-realtime-plane.sh` | tenant topics, realtime ACL, replay, quotas |
| `m17-modules.sh` | manifests generate Kong/Compose/capabilities consistently |
| `m18-rust-data-plane.sh` | TypeScript/Go/Rust boundary docs, Rust data-plane scaffold, shadow Compose service, cargo check |
| `m19-go-control-plane.sh` | Go control-plane scaffold, adapter-registry parity guardrails, shadow Compose service, Go tests |

Keep existing M1-M10 gates, but treat them as foundation gates. M11+ are productization gates.

Current implemented productization gates:

- `make verify-trust-boundary` runs M11 static checks, TypeScript typecheck, a signed-envelope positive probe, and a forged raw-header negative probe in strict mode.
- `make verify-tenancy` runs M12 — checks migration `030_tenancy_isolation.sql`, confirms `tenant_databases` RLS now uses `auth.current_tenant_id()` (not `current_user_id`), and in `--live` mode proves two tenants with the same DB name and same user cannot see each other's rows.
- `make verify-rust-data-plane` runs M18 for the Rust data-plane shadow scaffold. **R2 done**: `/v1/query` now dispatches through `PoolRegistry` + `EnginePool::execute` when `DATA_PLANE_ROUTER_PRODUCT_MODE=enabled`; default `shadow` mode keeps the 501 contract.
- `make verify-go-control-plane` runs M19 for the Go control-plane shadow scaffold.
- `make verify-productization` runs all four productization gates in one chain (M11 + M12 + M18 + M19).

## Critical Negative Tests

Do not only test success. Product security mostly lives in negative tests.

### Forged Header Test

```bash
docker exec some-internal-container curl -sS \
  -H 'X-User-Id: victim-user' \
  http://query-router:4001/query/v1/databases/.../resources/...
```

Expected: `401` or `403` because no valid signed identity envelope is present.

### Cross-Tenant Database Test

1. Tenant A registers database `orders`.
2. Tenant B tries `GET /databases/<A-db-id>`.
3. Tenant B tries query-router with `<A-db-id>`.

Expected: both denied, with audit rows for failed access.

### ABAC Fail-Closed Test

1. Stop permission-engine or invalidate PDP bundle.
2. Attempt a write.

Expected: deny unless a fresh signed local bundle is available.

### Transaction Reaper Test

1. Begin transaction.
2. Insert row.
3. Do not commit.
4. Wait beyond idle timeout.
5. Assert row absent and connection released.

### Saga Failure Test

1. Step 1 writes Postgres.
2. Step 2 targets Mongo and is forced to fail.
3. Compensation for Step 1 is scheduled.
4. Saga state becomes `compensating` or `compensated`, not `committed`.

## Product Metrics

Expose metrics that prove behavior:

| Metric | Meaning |
|---|---|
| `baas_identity_verification_fail_total` | forged/expired/replayed internal identity attempts |
| `baas_pool_active_connections` | active connections by tenant/engine/mount |
| `baas_pool_wait_seconds` | pool pressure |
| `baas_tx_open_total` | open tx count |
| `baas_tx_reaped_total` | idle tx rollback count |
| `baas_pdp_decision_total` | allow/deny decisions |
| `baas_saga_state_total` | saga lifecycle states |
| `baas_realtime_connections` | tenant/app realtime connections |
| `baas_realtime_dropped_events_total` | backpressure/drop visibility |
| `baas_module_enabled` | enabled modules by tenant/project |

## Migration Phases

### Phase 1: Secure Boundary

- Add signed identity envelope.
- Add tenant/project/app context.
- Add scoped internal service tokens.
- Add negative tests for forged headers.

Exit criteria: no service accepts raw `X-User-Id` in production mode.

### Phase 2: Tenant Model

- Add tenant/project scope to control-plane tables.
- Backfill existing rows.
- Split `current_user_id` and `current_tenant_id` in RLS.
- Introduce per-tenant keys and quotas.

Exit criteria: two tenants with same resource names cannot see each other.

### Phase 3: Adapter SPI V2

- Introduce the Rust `data-plane-router` in shadow mode.
- Introduce mount descriptors and pool registry.
- Implement PostgreSQL and MongoDB V2 pools in Rust.
- Add metrics and registry cache.
- Deprecate connection-string-per-call interface.

Exit criteria: hot query path reuses pools and does not decrypt on every operation.

### Phase 4: Transactions

- Add tx session API.
- Add idle reaper.
- Add durable tx state.
- Add Mongo sessions where available.

Exit criteria: multi-call single-engine commit/rollback works and is tested.

### Phase 5: ABAC Local PDP

- Compile policy bundles.
- Evaluate locally in query-router.
- Extend ABAC to schema, storage and realtime.

Exit criteria: permission-engine outage does not create allow-by-default behavior.

### Phase 6: Saga And Realtime Productization

- Add saga definition registry.
- Add durable idempotency ledger.
- Tenant-scope realtime topics.
- Add replay API for outbox-backed events.

Exit criteria: cross-engine workflows are observable, retry-safe and explicitly marked `saga`.

### Phase 7: Modules

- Add manifests.
- Generate Kong/Compose/capabilities.
- Add tenant module table.

Exit criteria: enabling/disabling a feature module is one config change plus generated artifacts.

### Phase 8: Runtime Migration

- Keep TypeScript for SDK, dashboard, playground and product-facing developer APIs.
- Move hot data-plane execution to Rust: adapter pools, transaction sessions, local PDP and realtime integration.
- Introduce Go only for stable control-plane orchestration after Rust contracts are proven.
- Keep NestJS query-router alive until shadow comparisons pass.

Exit criteria: `m18-rust-data-plane.sh` passes, Rust and Nest query-router can run side by side, and no Go service is allowed to bypass the Rust data plane for tenant data queries.

## README Claim Updates

Any public README should use this language after migration starts:

```text
mini-BaaS provides a unified, tenant-isolated data plane for multiple engines.
It supports ACID transactions inside engines that provide native transactions
and saga-based cross-engine consistency with durable outbox, idempotency and
compensating actions. Security primitives are non-disableable: signed identity,
tenant isolation, ABAC, audit and quotas are enforced before feature modules run.
```

Avoid:

```text
ACID across any database.
```

## Definition Of Done

- M1-M10 still pass.
- M11-M17 pass in static mode, and their `--live` modes pass before production cutover.
- M18 passes and proves the Rust migration scaffold stays parallel, typed and reversible.
- M19 passes and proves Go control-plane services stay orchestration-only and shadowed during migration.
- Docs no longer claim universal ACID.
- Threat-boundary tests prove forged internal headers fail.
- Tenant tests prove cross-customer isolation.
- Transaction tests prove per-engine ACID.
- Saga tests prove compensation and idempotency.
- Realtime tests prove topic isolation and replay.
- Module tests prove generated config matches enabled capabilities.
