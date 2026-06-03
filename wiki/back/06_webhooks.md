# 06 — Webhooks

Tenants subscribe to outbox events (`orders.created`, `users.updated`, …)
and receive HMAC-signed HTTP POSTs at a URL of their choice. Implemented
by `webhook-dispatcher` (Go service in
`apps/baas/mini-baas-infra/go/control-plane/cmd/webhook-dispatcher/`).

## Schema

Migration `031_webhooks.sql`:

- `webhook_subscriptions` — tenant-scoped (RLS), one row per subscription.
- `webhook_deliveries` — per-attempt ledger with status pending/success/failed/dead.

Both have `tenant_id` indexes + RLS policies; the dispatcher uses the admin
pool for retries (no tenant context available from a background scan).

## REST API

```http
POST   /v1/webhooks                       # create
GET    /v1/webhooks                       # list (tenant-scoped)
GET    /v1/webhooks/:id                   # fetch (secret never returned)
PATCH  /v1/webhooks/:id                   # update fields
DELETE /v1/webhooks/:id                   # remove + cascade deliveries
GET    /v1/webhooks/:id/deliveries        # recent delivery attempts
```

Tenant identity is taken from `X-Baas-Tenant-Id` (post-M11 signed
envelope) with fallbacks for legacy clients.

### Create example

```sh
curl -X POST http://localhost:3025/v1/webhooks \
  -H "X-Baas-Tenant-Id: t-acme" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "orders-to-slack",
    "url": "https://example.com/incoming-hook",
    "secret": "whsec_xxx_replace_me",
    "event_types": ["orders.created", "orders.refunded"],
    "aggregates": ["orders"],
    "max_attempts": 8,
    "timeout_ms": 5000
  }'
```

`event_types: ["*"]` or `aggregates: ["*"]` subscribe to everything.

## Delivery flow

```
PG outbox row  ─►  outbox-relay XADD  ─►  Redis stream  outbox.<aggregate>
                                              │
                                              ▼
                                  webhook-dispatcher XREADGROUP
                                              │
                          ┌───────────────────┼──────────────────┐
                          ▼                   ▼                  ▼
                  match subscriptions   insert delivery     POST + HMAC
                  (tenant-scoped)        row (pending)      retry on fail
                                                            DLQ on max attempts
```

## HMAC signature

The dispatcher signs the raw POST body with HMAC-SHA256 using the
subscription's `secret`:

```
X-Baas-Signature: sha256=<hex>
X-Baas-Event-Id: <outbox event id>
X-Baas-Subscription-Id: <subscription uuid>
```

Receiver verification (pseudocode):

```python
expected = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
got = request.headers["X-Baas-Signature"].removeprefix("sha256=")
assert hmac.compare_digest(expected, got)
```

## Retry + DLQ

- Failed attempts (network error, non-2xx response) reschedule with
  exponential backoff: 2^attempts seconds, capped at 5 minutes.
- After `max_attempts` failures the delivery row moves to `status = 'dead'`.
- DLQ inspection: `GET /v1/webhooks/:id/deliveries?limit=50` shows the
  most recent attempts including `last_error` and `last_status_code`.

To requeue a dead delivery:

```sql
UPDATE webhook_deliveries
   SET status = 'pending', next_attempt_at = now(), attempts = 0,
       last_error = NULL
 WHERE id = $1;
```

## Tenant scoping of outbox events

The dispatcher reads the `tenant_id` field out of the outbox payload to
decide which subscriptions to fan to. Events that don't include a
`tenant_id` are skipped (no broadcast). When producing outbox rows from
application code, always include `tenant_id` in the payload JSON.

## Operating notes

- The dispatcher uses Redis consumer group `webhook-dispatcher` by default;
  scale horizontally by setting unique `WEBHOOK_CONSUMER` values per
  replica (they share the group, partition the workload).
- `webhook_deliveries` grows unbounded — schedule a pruning job for rows
  older than 30 days unless you need the audit trail.
- The dispatcher uses the admin DB pool for retry scans; if you tighten
  pgbouncer pool sizes, raise the per-pool reservation accordingly.
