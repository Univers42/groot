# M3 — Cross-engine coherence

**Targets:** dimensions **c** (cross-engine coherence), **g** (auditability).
**Gate:** `make baas-verify-m3` returns `0`.
**Estimated effort:** 3–4 days.
**Risk:** medium-high — introduces Debezium and a new daemon service.
**Depends on:** M1 (audit_log), M2 (multiple engines to coordinate).

## Why

Cross-engine ACID is physically impossible. The industry pattern is **outbox + CDC + idempotent consumers + sagas**. Without it, dimension **c** is stuck at 4/10 no matter how many engines we add.

## Deliverables

### 1. `outbox_events` migration

New file `scripts/migrations/postgresql/015_outbox_events.sql`:

```sql
-- UP
CREATE TABLE IF NOT EXISTS public.outbox_events (
  id            BIGSERIAL PRIMARY KEY,
  aggregate     TEXT NOT NULL,
  aggregate_id  TEXT NOT NULL,
  event_type    TEXT NOT NULL,
  payload       JSONB NOT NULL,
  request_id    UUID,
  actor_id      UUID,
  status        TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','published','failed','dead')),
  attempts      INT NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  published_at  TIMESTAMPTZ,
  last_error    TEXT
);
CREATE INDEX outbox_pending_idx ON public.outbox_events (status, created_at)
  WHERE status = 'pending';

INSERT INTO public.schema_migrations (version, name) VALUES (15, '015_outbox_events')
  ON CONFLICT (version) DO NOTHING;
```

### 2. Unified RLS model

Migration `016_unify_rls.sql` standardises every policy to read the JWT claim, so PostgREST and query-router behave identically:

```sql
CREATE OR REPLACE FUNCTION auth.current_user_id() RETURNS UUID
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'sub',
    NULLIF(current_setting('app.current_user_id',  true), '')
  )::uuid;
$$;
```

Rewrite every policy to use `auth.current_user_id()` and drop the divergent `current_setting('app.current_user_id')` path.

### 3. `outbox-relay` service

New micro-service `src/apps/outbox-relay/`, NestJS, same layout as the others.

Responsibilities:
- Subscribe to Postgres logical replication (or poll `outbox_events WHERE status='pending'` if Debezium is excluded).
- For each event, publish to **Redis Streams** key `outbox.<aggregate>` (Redis already in the stack — no new infra).
- Mark `published` on success, increment `attempts` and back off on failure, move to `dead` after N attempts.
- Idempotent: deduplicates by `id` in a Redis `SET` with TTL.

Dockerfile mirrors the other NestJS apps (pinned base image, non-root user, `HEALTHCHECK`).

### 4. Idempotency middleware

New file `src/libs/common/src/middleware/idempotency.middleware.ts`:

- Reads `Idempotency-Key` header on mutating requests (`POST`/`PATCH`/`PUT`/`DELETE`).
- Stores `(key, actor_id) → response hash` in Redis with 24h TTL.
- Replays the cached response if the same key arrives again, instead of re-executing.

Wire it globally in `query-router`, `mongo-api`, `storage-router`.

### 5. Outbox helper in `query-router`

When `query-router` performs a write on a non-PG engine but the same logical event should reach PG (or vice versa), it inserts a row in `outbox_events` **in the same transaction** as the PG-side change. Cross-engine consistency becomes "eventual + auditable + replayable".

Helper signature:

```ts
await this.pg.tx(async (client) => {
  await client.query('INSERT INTO orders ...');
  await this.outbox.emit(client, {
    aggregate: 'order',
    aggregate_id: orderId,
    event_type: 'order.created',
    payload: { ... },
    request_id: req.requestId,
    actor_id: req.user.id,
  });
});
```

### 6. Consumer example: Mongo projection

To prove the pattern end-to-end, add one consumer that subscribes to `outbox.order` on Redis Streams and writes a denormalised projection into Mongo `orders_view`. This is the canonical demo for the jury.

## Make gate

New file `scripts/verify/m3-coherence.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "[M3] outbox + unified RLS migrations applied"
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d postgres -tAc \
  "SELECT COUNT(*) FROM public.schema_migrations WHERE version IN (15,16)" | grep -q '^2$'

echo "[M3] outbox-relay healthy"
curl -fsS "http://localhost:${OUTBOX_RELAY_PORT}/health" | jq -e '.status == "ok"' >/dev/null

echo "[M3] idempotency middleware deduplicates"
key="$(uuidgen)"
r1=$(curl -fsS -X POST "https://localhost:8443/query/${DB_ID}/mock_orders" \
  -H "Authorization: Bearer ${USER_JWT}" -H "Idempotency-Key: ${key}" \
  --data '{"op":"insert","data":{"name":"m3-idem"}}')
r2=$(curl -fsS -X POST "https://localhost:8443/query/${DB_ID}/mock_orders" \
  -H "Authorization: Bearer ${USER_JWT}" -H "Idempotency-Key: ${key}" \
  --data '{"op":"insert","data":{"name":"m3-idem"}}')
[[ "$r1" == "$r2" ]] || { echo "[M3] FAIL: idempotency broken"; exit 1; }

docker compose exec -T postgres psql -U "$POSTGRES_USER" -d postgres -tAc \
  "SELECT COUNT(*) FROM public.mock_orders WHERE name='m3-idem'" | grep -q '^1$'

echo "[M3] outbox: PG write produces Mongo projection within 5s"
oid="$(uuidgen)"
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d postgres -c \
  "INSERT INTO public.orders (id, name) VALUES ('${oid}', 'm3-out');
   INSERT INTO public.outbox_events (aggregate, aggregate_id, event_type, payload)
   VALUES ('order','${oid}','order.created','{\"name\":\"m3-out\"}');"

for i in $(seq 1 25); do
  found=$(docker compose exec -T mongo mongosh --quiet --eval \
    "db.getSiblingDB('app').orders_view.countDocuments({_id:'${oid}'})")
  [[ "$found" == "1" ]] && break
  sleep 0.2
done
[[ "$found" == "1" ]] || { echo "[M3] FAIL: projection not propagated"; exit 1; }

echo "[M3] outbox row marked published"
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d postgres -tAc \
  "SELECT status FROM public.outbox_events WHERE aggregate_id='${oid}'" | grep -q '^published$'

echo "[M3] OK"
```

## Done when

- `outbox_events` exists and is written transactionally.
- `outbox-relay` publishes pending events to Redis Streams and updates status correctly.
- A PG write provably triggers a Mongo projection in < 5 seconds.
- Replaying the same `Idempotency-Key` returns the cached response without re-executing.
- RLS uses one model only (`auth.current_user_id()`).
- `make baas-verify-m3` exits `0`.

## Out of scope

- Saga compensations (M6).
- Full Debezium deployment (the poll-based relay is sufficient at this scale; document the Debezium upgrade path as `Perspectives d'évolution`).
