# 01 — Architecture

Mini-BaaS is a multi-tenant Backend-as-a-Service split across three planes:

```
                ┌────────────────────────────────────────────────────┐
                │  Gateway: Kong / nginx (HTTPS, rate limit, signed  │
                │  identity envelope injection)                      │
                └────────────────────────────────────────────────────┘
                                          │
        ┌─────────────────┬───────────────┼───────────────┬──────────────────┐
        ▼                 ▼               ▼               ▼                  ▼
  control-plane      data-plane       outbox-relay    realtime           background
  (Go + Nest TS)     (Rust + Nest)     (Nest TS)      (Nest TS, opt-in)  (Nest TS)
  ─────────────      ──────────────    ─────────────  ─────────────      ──────────
  adapter-           query-router   →  PG outbox      WebSocket fan-out  email,
   registry-go        (NestJS shim) →   → Redis        for client SDKs    GDPR,
  permission-          data-plane-      Streams                           AI,
   engine               router-rust   → Mongo                             analytics,
  webhook-              (engine pools                                     newsletter,
   dispatcher           per tenant)                                       session,
  pg-meta                                                                 log
  studio
```

## Plane responsibilities

**Control plane** — owns tenant metadata: encrypted connection strings
(`tenant_databases`), policies (`abac_*`), webhook subscriptions, schema migrations.
Owns no per-request data. Mostly Go now; the NestJS pieces that remain
(`permission-engine`, `query-router`) are HTTP shims that delegate the hot path.

**Data plane** — every request that touches user data goes through the Rust
`data-plane-router`. It owns per-tenant connection pools, executes against the
correct engine adapter (PG, Mongo, MySQL, Redis, HTTP), and enforces ABAC field
masks. Single-process, single binary, distroless image, ~6 MB.

**Background plane** — async work: outbox relay (PG → Redis Streams), webhook
delivery, email send, audit/GDPR/analytics jobs. These can all be scaled
horizontally; nothing here is on the critical-path of a user request.

## Why this shape

The original architecture was 17 NestJS apps. We cut the hot path to Rust
because per-request cold-start + JSON parse + GC pauses cost ~3-5× more CPU
than the Rust router. The control plane stays in higher-level languages
(Go for new code, Nest TS for legacy) because metadata mutations are
infrequent and the development velocity matters more than per-request latency.

## What's tenant-scoped vs global

- **Tenant-scoped**: every row in `public.*` is RLS-gated on
  `auth.current_tenant_id()`. The Rust router sets `app.current_tenant_id`
  via `set_config('app.current_tenant_id', $1, true)` at the start of every
  transaction.
- **Global / admin**: schema migrations, policy bundles, adapter-registry
  encryption key, the inline DSN map for `DATA_PLANE_MOUNTS` (bypass mode).

## Where to look next

- Operations (start/stop/lean profile): `02_operations.md`
- Permissions (ABAC vs RBAC): `03_abac.md`
- Multi-statement transactions: `04_transactions.md`
- Admin raw SQL + per-tenant migrate: `05_admin_endpoints.md`
- Webhooks: `06_webhooks.md`
- Backups: `07_backups.md`
- Edge Functions: `08_edge_functions.md`
