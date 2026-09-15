# Realtime Multi-App Event Plane

**Design goal**: turn the Rust realtime service into a multi-tenant, multi-app event plane with durable integration to outbox/saga and strict topic authorization.

## Current State

The realtime kernel is a strong starting point:

- The SDK opens WebSocket and speaks `AUTH`, `SUBSCRIBE`, `UNSUBSCRIBE` in [realtime-client.ts](../../apps/baas/sdk/src/domains/realtime-client.ts).
- The Rust server exposes `/ws`, `/v1/publish`, `/v1/publish/batch`, `/v1/health` in [server.rs](../../apps/baas/mini-baas-infra/docker/services/realtime/realtime-agnostic/crates/realtime-server/src/server.rs).
- Compose config wires Postgres and Mongo producers in [docker-compose.yml](../../apps/baas/mini-baas-infra/docker-compose.yml).
- Outbox relay mirrors durable outbox rows into realtime via `/v1/publish` in [outbox-relay.service.ts](../../apps/baas/mini-baas-infra/src/apps/outbox-relay/src/outbox-relay.service.ts).

The product gap is namespace and authorization. Topics like `mongo/orders/*` are useful internally but not enough for many tenants and apps.

## Topic Model

Internal topics should always include tenant/project/app context:

```text
tenant/<tenant_id>/project/<project_id>/engine/<engine>/db/<database_id>/resource/<resource>/<event>
tenant/<tenant_id>/project/<project_id>/outbox/<aggregate>/<event_type>
tenant/<tenant_id>/project/<project_id>/module/<module>/<event>
```

The SDK can expose friendly aliases:

```ts
client.engine('mongodb', dbId, 'orders').subscribe(...)
```

but it should resolve to a tenant-scoped topic on the wire.

## Realtime Auth Claims

Realtime tokens must include topic permissions:

```json
{
  "sub": "user-id",
  "tenant_id": "tenant-id",
  "project_id": "project-id",
  "app_id": "app-id",
  "can_subscribe": true,
  "can_publish": false,
  "namespaces": [
    "tenant/<tenant>/project/<project>/engine/mongodb/db/<db>/resource/orders/*"
  ],
  "exp": 1770000000
}
```

Tenant service tokens may publish to selected namespaces. Browser tokens usually subscribe only.

## Event Envelope

Normalize all producers into one envelope:

```ts
interface RealtimeEnvelope<T = unknown> {
  eventId: string;
  tenantId: string;
  projectId: string;
  appId?: string;
  databaseId?: string;
  engine: string;
  resource: string;
  eventType: 'insert' | 'update' | 'delete' | 'upsert' | 'saga' | 'custom';
  sequence: number;
  timestamp: string;
  idempotencyKey?: string;
  payload: T;
}
```

Adapters and outbox relay can map native CDC payloads into this envelope before publishing.

## Delivery Classes

Realtime should declare what it guarantees:

| Class | Meaning | Use case |
|---|---|---|
| ephemeral | best-effort live fan-out, no replay | UI presence, typing indicators |
| durable-outbox | event is backed by `outbox_events` and can be replayed | data mutations, saga state |
| cdc | sourced from database change feed; replay depends on source retention | DB sync |

Do not claim exactly-once WebSocket delivery. Claim at-least-once with idempotent event IDs for durable streams.

## Replay API

Add replay for durable events:

```http
GET /realtime/v1/events?topic=...&after_sequence=123&limit=500
```

Back this with outbox/event log storage. The WebSocket `SUBSCRIBE` frame can accept `resume_from`:

```json
{
  "type": "SUBSCRIBE",
  "sub_id": "orders",
  "topic": "tenant/.../orders/*",
  "resume_from": 123
}
```

## Multi-App Quotas

Quota dimensions:

- connections per tenant/project/app
- subscriptions per connection
- publish rate per tenant/project/app
- event size
- fan-out target count
- replay read rate

Expose metrics:

- active connections by tenant/project/app
- subscription count
- publish/drop/error counts
- fan-out duration
- backpressure queue length

## ABAC Integration

Realtime is a data path. It must call or embed PDP decisions for:

- subscribe to a topic pattern
- publish to a topic
- replay durable event history

The Rust auth provider already supports namespace authorization. The platform should mint tokens from the same policy model used by query-router so data and realtime do not drift.

## Producer Model

Use multiple producers:

| Producer | Source | Notes |
|---|---|---|
| outbox-relay | `public.outbox_events` | preferred durable product events |
| Postgres CDC | LISTEN/NOTIFY or Debezium | table-level changes |
| Mongo change streams | replica set | document changes |
| custom publish | `/v1/publish` | server-side tenant integrations only |

The product API should prefer outbox-backed events for important data mutations because they are replayable and tied to saga/idempotency state.

## SDK Shape

```ts
const sub = await client
  .engine<'mongodb', Order>(dbId, 'orders')
  .subscribe({
    onEvent(event) { ... },
    resumeFrom: lastSeenSequence,
  });
```

The SDK should expose capability discovery so apps know whether realtime, replay and CDC are available for a given engine/resource.

## Migration Plan

1. Add tenant/project/database/resource fields to outbox realtime publish payloads.
2. Change SDK topic generation to tenant-scoped aliases returned by the server, not hard-coded `mongo/<channel>/*` only.
3. Add topic authorization to realtime token minting.
4. Add durable replay store/API for outbox-backed events.
5. Add per-tenant/app quotas and metrics.
6. Add end-to-end test: two tenants subscribe to same resource name and receive only their own events.

## Acceptance Criteria

- Tenant A cannot subscribe to Tenant B's topics even with guessed topic strings.
- Browser tokens cannot publish unless explicitly allowed.
- Outbox-backed events can be replayed after WebSocket reconnect.
- One noisy tenant cannot exhaust all realtime connections or subscriptions.
- SDK hides topic complexity while preserving exact capabilities.
