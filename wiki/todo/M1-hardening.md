# M1 — Stack hardening

**Targets:** dimensions **a** (Docker-first micro-services), **f** (tooling), **g** (auditability, light).
**Gate:** `make baas-verify-m1` returns `0`.
**Estimated effort:** 1 day of focused work.
**Risk:** very low — no behavioural change, only scaffolding.

## Why this comes first

- `IDatabaseAdapter` must exist before M2 adds more engines, otherwise we lock in the current pg/mongo signature divergence.
- OpenAPI must exist before M2 generates the SDK.
- `audit_log` must exist before M3 wires the outbox so it has a target trace table.
- `HEALTHCHECK` in every Dockerfile is the cheapest reliability gain in the repo.

## Deliverables

### 1. Dockerfile `HEALTHCHECK` on every service

Add to every micro-service Dockerfile under `apps/baas/mini-baas-infra/docker/services/*/Dockerfile` and to every NestJS app image:

```dockerfile
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD wget -qO- http://localhost:${PORT}/health || exit 1
```

The `health.controller.ts` already exists in every NestJS app (`apps/baas/mini-baas-infra/src/apps/*/src/health.controller.ts`) and in `libs/health/`, so the HTTP target is guaranteed.

### 2. `IDatabaseAdapter` contract

New file `apps/baas/mini-baas-infra/src/libs/database/src/adapter.contract.ts`:

```ts
export interface EngineCaps {
  read: boolean;
  write: boolean;
  upsert: boolean;
  txIntra: boolean;
  stream: boolean;
}

export interface QueryOpts {
  data?: Record<string, unknown>;
  filter?: Record<string, unknown>;
  sort?: Record<string, 'asc' | 'desc'>;
  limit?: number;
  offset?: number;
  userId?: string;
  idempotencyKey?: string;
}

export interface QueryResult {
  rows: Record<string, unknown>[];
  rowCount: number;
}

export type AdapterOp = 'list' | 'get' | 'insert' | 'update' | 'delete' | 'upsert';

export interface IDatabaseAdapter {
  readonly engine: string;
  capabilities(): EngineCaps;
  execute(connectionString: string, resource: string, op: AdapterOp, opts: QueryOpts): Promise<QueryResult>;
  listResources(connectionString: string, dbName?: string): Promise<string[]>;
}
```

Then refactor:

- `apps/baas/mini-baas-infra/src/apps/query-router/src/engines/postgresql.engine.ts` → implements `IDatabaseAdapter`, internal `select`/`insert`/`update`/`delete` mapped from `AdapterOp`.
- `apps/baas/mini-baas-infra/src/apps/query-router/src/engines/mongodb.engine.ts` → same.
- `apps/baas/mini-baas-infra/src/apps/query-router/src/query/query.service.ts` → dispatches by `engine` field via a `Map<string, IDatabaseAdapter>`, no `if engine ===` chains.

No external behaviour change. All existing scripts in `apps/baas/mini-baas-infra/scripts/phase*.sh` must still pass.

### 3. Unified query DTO

Refactor `apps/baas/mini-baas-infra/src/apps/query-router/src/query/dto/query.dto.ts` to:

```ts
export class ExecuteQueryDto {
  @IsEnum(['list', 'get', 'insert', 'update', 'delete', 'upsert'])
  op!: AdapterOp;

  @IsOptional() data?: Record<string, unknown>;
  @IsOptional() filter?: Record<string, unknown>;
  @IsOptional() sort?: Record<string, 'asc' | 'desc'>;
  @IsOptional() @Min(1) @Max(500) limit?: number;
  @IsOptional() @Min(0) offset?: number;
}
```

Keep `action` as a back-compat alias for one minor version, then drop.

### 4. OpenAPI on every NestJS app

In every `apps/baas/mini-baas-infra/src/apps/*/src/main.ts`:

```ts
const config = new DocumentBuilder()
  .setTitle('<service-name>')
  .setVersion(process.env.SERVICE_VERSION ?? '0.0.1')
  .addBearerAuth()
  .build();
SwaggerModule.setup('docs', app, SwaggerModule.createDocument(app, config));
```

Add `@nestjs/swagger` to the workspace package, decorate every controller with `@ApiTags`, `@ApiBearerAuth`, `@ApiOperation`. The DTOs already use `class-validator` so most schemas are inferred.

### 5. `audit_log` migration

New file `apps/baas/mini-baas-infra/scripts/migrations/postgresql/013_audit_log.sql`:

```sql
-- UP
CREATE TABLE IF NOT EXISTS public.audit_log (
  id          BIGSERIAL PRIMARY KEY,
  request_id  UUID NOT NULL,
  actor_id    UUID,
  actor_role  TEXT,
  action      TEXT NOT NULL,
  resource    TEXT NOT NULL,
  payload     JSONB,
  ip          INET,
  user_agent  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS audit_log_actor_idx   ON public.audit_log (actor_id, created_at DESC);
CREATE INDEX IF NOT EXISTS audit_log_request_idx ON public.audit_log (request_id);

INSERT INTO public.schema_migrations (version, name) VALUES (13, '013_audit_log')
  ON CONFLICT (version) DO NOTHING;

-- DOWN
-- DROP TABLE IF EXISTS public.audit_log;
-- DELETE FROM public.schema_migrations WHERE version = 13;
```

### 6. Audit interceptor

New file `apps/baas/mini-baas-infra/src/libs/common/src/interceptors/audit.interceptor.ts` that writes one row to `audit_log` per mutating HTTP request (`POST`/`PATCH`/`PUT`/`DELETE`), using `req.requestId` from the existing `CorrelationIdInterceptor`, `req.user.id`/`req.user.role` from the existing `AuthGuard`.

Wire it as a global interceptor in services that touch data: `query-router`, `mongo-api`, `storage-router`, `permission-engine`, `gdpr-service`, `session-service`, `newsletter-service`.

## Make gate

New file `apps/baas/mini-baas-infra/scripts/verify/m1-hardening.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "[M1] checking Dockerfile HEALTHCHECK coverage"
missing=0
while IFS= read -r f; do
  if ! grep -q '^HEALTHCHECK' "$f"; then
    echo "  missing HEALTHCHECK: $f"
    missing=$((missing+1))
  fi
done < <(find apps/baas/mini-baas-infra/docker/services -name Dockerfile)
[[ $missing -eq 0 ]] || { echo "[M1] FAIL: $missing Dockerfiles without HEALTHCHECK"; exit 1; }

echo "[M1] checking docker compose health"
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml ps --format json \
  | jq -e 'all(.Health == "healthy" or .Health == "")' >/dev/null

echo "[M1] checking OpenAPI exposure on every NestJS app"
for svc in query-router mongo-api storage-router permission-engine gdpr-service \
           session-service log-service newsletter-service schema-service; do
  port=$(bash apps/baas/mini-baas-infra/scripts/resolve-ports.sh "$svc")
  curl -fsS "http://localhost:${port}/docs-json" >/dev/null \
    || { echo "[M1] FAIL: $svc has no OpenAPI at /docs-json"; exit 1; }
done

echo "[M1] checking IDatabaseAdapter contract is honoured"
node -e "
  const pg = require('./apps/baas/mini-baas-infra/dist/apps/query-router/engines/postgresql.engine').PostgresqlEngine;
  const mo = require('./apps/baas/mini-baas-infra/dist/apps/query-router/engines/mongodb.engine').MongodbEngine;
  for (const E of [pg, mo]) {
    const i = new E();
    for (const m of ['capabilities','execute','listResources']) {
      if (typeof i[m] !== 'function') { console.error('missing', m, 'on', E.name); process.exit(1); }
    }
  }
"

echo "[M1] checking audit_log migration applied"
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T postgres \
  psql -U "$POSTGRES_USER" -d postgres -tAc \
  "SELECT 1 FROM public.schema_migrations WHERE version = 13" | grep -q 1

echo "[M1] roundtrip: mutating request must produce an audit_log row"
req_id="$(uuidgen)"
curl -fsS -X POST "https://localhost:8443/query/<dbid>/mock_orders" \
  -H "Content-Type: application/json" \
  -H "X-Request-ID: ${req_id}" \
  -H "Authorization: Bearer ${USER_JWT}" \
  --data '{"op":"insert","data":{"name":"m1-audit-probe"}}' >/dev/null

docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T postgres \
  psql -U "$POSTGRES_USER" -d postgres -tAc \
  "SELECT 1 FROM public.audit_log WHERE request_id = '${req_id}'" | grep -q 1

echo "[M1] OK"
```

## Done when

- All Dockerfiles include `HEALTHCHECK`.
- `docker compose ps` reports `healthy` for every service.
- `/docs-json` returns a valid OpenAPI 3 document on every NestJS app.
- `PostgresqlEngine` and `MongodbEngine` implement `IDatabaseAdapter` (compile-time check + runtime probe).
- A mutating HTTP request produces exactly one `audit_log` row with the propagated `X-Request-ID`.
- `make baas-verify-m1` exits `0`.

## Out of scope (deferred to later milestones)

- New engines beyond pg/mongo → M2.
- Outbox / cross-engine consistency → M3.
- Prometheus / OTel / Loki → M4.
- WAF / rate-limit / SAST gates → M5.
