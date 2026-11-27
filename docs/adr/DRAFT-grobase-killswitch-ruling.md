# DRAFT: a grobase connection is switched off by its owner at the registry, and payload copies leave by retention and a guarded purge

- Status: draft, untracked. Ruled by devil 2026-11-24. Full ruling: `/mnt/storage/dlesieur/scratch/grobase-killswitch/RULING.md`.
- Scope: grobase CONNECT mode. U1 adds a per-connection enable switch. U2 adds retention and purge of payload copies. Code read: grobase `origin/main` 5cfcae06.

## Context

- **One choke point.** Every routed request resolves its mount through `GET /databases/{id}/connect` (`adapterregistry/handler.go:54`, `connection.go:35`):
  - query-router: `query.service.ts:367`
  - Rust `/data/v1`: `data-plane-server/src/auth.rs:161`
  - schema-service: `schemas.service.ts:69`
- **Static and nano mounts bypass the registry:** `query.service.ts:319`, `routes/state.rs:235`.
- **Caches** (30 s TTL in both planes):
  - The Rust mount cache uses `DATA_PLANE_VERIFY_CACHE_TTL_MS`, default 30000 (`config.rs:385`, `state.rs:241`). `rotate` clears it and drains the pool (`state_ops.rs:35-48`).
  - The query-router DSN cache (`query.service.ts:248`) has no eviction hook.
- **Who can act today:**
  - The registry trusts the `X-Baas-*` headers by default (`requser.go:25-55`).
  - The tenant self-serve PATCH/DELETE exists at `/v1/tenants/me/mounts/{id}` with scope `write` (`builder.go:83-87`). It is mounted only when `BUILDER_ENABLED=1`, which defaults to 0 (`control-plane.yml:276`).
  - The osionos bridge holds the service key and sets the tenant headers (`bridge-api.mjs:674-690`).
- **Outbox rows have no mount id:**
  - Schema: `015_outbox_events.sql:30`.
  - Writers: `outbox.service.ts:83-93`, `outbox.rs:96-109`.
  - Streams are `outbox.<table>`, shared across tenants. The webhooks and functriggers consumer groups read them (`webhooks/streams.go:52`, `functriggers/dispatcher_streams.go:55`).
  - `saga.*` streams also exist (`saga.go:48`).
- **The relay** locks an event `FOR UPDATE SKIP LOCKED` (`outboxrelay/sql.go:53`). It retries `failed` rows and compensates `dead` ones.
- **Audit stores request bodies.** `audit_log.payload` keeps the body (up to 8 KB) of every mutating request, reads via `POST /execute` included (`audit.interceptor.ts:59`, `query.controller.ts:67`). Its purge floor is 30 days (`095_audit_log_retention.sql:84`).
- **Mongo projection.** Resources named `order` are projected into grobase Mongo `orders_view` (`publish.go:31-35`, `mongoprojector.go:29`, `control-plane.yml:465`).
- **Backups and WAL** hold `outbox_events` and `audit_log` (`ops.yml:35`, `pg-backup/scripts/wal-archive.sh`).
- **Unknown when this was written:**
  - Live flags, TTL overrides and replica counts.
  - Size of `outbox_events` and of the streams, and consumer group lag.
  - Whether the query-router TS adapters hold their own source pools.
  - Where the realtime replay buffer is stored.
  - Whether logs hold bodies.
  - Live backup retention and PITR settings.
  - How consumers handle an entry that was XDEL'd while still pending for a consumer.
  - Whether live osionos data rides a CONNECT mount.

## Decision

- **The switch.**
  - A connection carries `enabled` (default true).
  - It is refused in `GetConnection` after tenant scoping, with `423 connection_disabled`.
  - It is toggled by a tenant admin-scope key or an owner/admin JWT, and recorded in `tenant_audit_log`.
  - Every replica evicts its cache and drains the mount's pools on a cut.
- **Payload copies** leave in two ways:
  - Time retention over terminal outbox rows, trimmed streams by consumer-group-safe `MINID`, and metadata-only audit on data routes.
  - A per-connection purge of rows stamped with `db_id` once the connection's pending events have drained.
- **Each cut** produces an append-only cut record sealed to the audit chain.

## Alternatives considered

- **U2 as worded (a per-connection purge plus a blind MAXLEN): BLOCK.**
  - Rows carry no mount id (`015_outbox_events.sql:30`), so a "per-connection" purge deletes either a whole tenant's events or other tenants' events.
  - A MAXLEN below the lag of a consumer group deletes webhooks and function triggers that were never delivered.
- **Disable answers 503: rejected.**
  - The bridge turns any status ≥500 into "try again" (`bridge-error-sentences.mjs:35`), and clients retry.
  - A deliberate cut is not an outage.
- **Gate on api-key scope `write` or on trusted headers: rejected.** Data keys live inside apps, and the bridge is one of them. That is a confused deputy that can cut a connection for every user of the app.
- **No cache for the enabled bit (a registry hit on every request): not chosen.** The 30 s cache exists because decrypting on `/connect` was CPU-bound under fan-out (`adapterregistry/service.go:68`). Push eviction with the TTL as a ceiling keeps that win.
- **An UNLOGGED outbox to keep payloads out of WAL and backups: rejected.** A crash loses undelivered events.

## Consequences

The verdict is **PROCEED-WITH-CONDITIONS** on U1 and U2′. The conditions are acceptance criteria:

| Condition | Acceptance criterion |
|---|---|
| KS1 | `enabled NOT NULL DEFAULT true`, idempotent migration. Every existing row reads enabled. NULL never means disabled. |
| KS2 | The refusal comes after the tenant-scoped `loadMountRow`. A cross-tenant id stays 404. |
| KS3 | 423 `connection_disabled`, no Retry-After. Every caller maps it. Tested end to end on `/query/v1` and `/data/v1`. |
| KS4 | Toggled with admin scope or an owner/admin JWT. `write` and trusted headers are refused. Mounted when `BUILDER_ENABLED=0`. |
| KS5 | Platform mounts refuse a disable. Static and nano mounts are documented as outside the switch. |
| KS6 | Toggles use compare-and-swap on `revision`. |
| KS7 | A cut pushes eviction to every replica of query-router, Rust and schema-service. The TTL ceiling carries a `Caveat:` line. |
| KS8 | Pools are drained in both planes. The source sees 0 grobase sessions within the SLA, per engine. |
| KS9 | In-flight requests are bounded by the request timeout, as stated in the cut record. |
| KS10 | Every toggle is in `tenant_audit_log`, metadata only. |
| KS11 | One gate over pg, mysql, mongo and http: disable gives 423 within the SLA with 0 source queries; enable gives 200 with no re-registration. |
| KS12 | Both writers stamp `db_id`. Its index is built `CONCURRENTLY`, outside the migration transaction. |
| KS13 | Legacy rows leave only through time retention. |
| KS14 | Retention deletes only terminal rows, in batches, rate-limited, after a headroom check. |
| KS15 | No purge touches `pending` or `failed` rows. The purge runs again after the tail window. |
| KS16 | Streams are trimmed by `MINID` set at or below the oldest un-ACKed id. A test shows a lagging group loses 0 entries. Covers `saga.*` too. |
| KS17 | The XDEL purge is tolerated by both consumer groups (tested). |
| KS18 | The copy inventory is closed (outbox, streams, Mongo projection, audit, realtime, logs) before any claim. |
| KS19 | Data-route audit stores metadata only. Historic payloads are nulled. `tenant_audit_log` is never rewritten. |
| KS20 | The cut record is append-only, sealed with `audit_seq`, and readable by the tenant. |
| KS21 | Every claim names the backup expiry date. |
| KS22 | Ordered rollout on develop. Each live deploy gets its own go and a rollback script. The osionos bridge maps `connection_disabled` first. |
| KS23 | Read-only measurement of the outbox, streams, lag and audit volume before retention goes live. |

- **Marketing.**
  - After U1: owners switch connections off and on themselves; no queries reach the source within the measured N s; every switch is audited.
  - After U1 and U2′: event copies are kept at most R and deleted on a cut, with a cut record and a backup expiry date.
  - Never: "nothing of yours is ever kept".
- **Separate issues this ruling opens:**
  - F1: `orders_view` `_id` collides across tenants.
  - F2: the saga target is read from user row data.
  - F3: the audit's "only the operator can cut" misses the self-serve DELETE.
