# M2 — Real federation

**Targets:** dimensions **b** (data federation), **d** (unified API & SDK).
**Gate:** `make baas-verify-m2` returns `0`.
**Estimated effort:** 2–3 days.
**Risk:** medium — new engines pull in new drivers and a new Trino catalog.
**Depends on:** M1 (needs `IDatabaseAdapter` and OpenAPI).

## Why

The `tenant_databases.engine` CHECK constraint already accepts `'postgresql','mongodb','mysql','redis','sqlite'` (see [004_add_adapter_registry.sql](../../apps/baas/mini-baas-infra/scripts/migrations/postgresql/004_add_adapter_registry.sql)), but only pg + mongo are implemented. M2 makes the constraint truthful and adds analytical reach via Trino + Iceberg.

## Deliverables

### 1. New engines under `query-router`

All conform to `IDatabaseAdapter` from M1.

| Engine | File | Driver | Capabilities |
|---|---|---|---|
| `MysqlEngine` | `src/apps/query-router/src/engines/mysql.engine.ts` | `mysql2/promise` | read, write, upsert, txIntra |
| `RedisEngine` | `src/apps/query-router/src/engines/redis.engine.ts` | `ioredis` | read, write (KV/hash semantics, no SQL) |
| `HttpEngine` | `src/apps/query-router/src/engines/http.engine.ts` | `undici` | read, write — backed by adapter-registry endpoint config |

Update `tenant_databases.engine` CHECK to include `'http'`:

```sql
ALTER TABLE public.tenant_databases DROP CONSTRAINT tenant_databases_engine_check;
ALTER TABLE public.tenant_databases ADD CONSTRAINT tenant_databases_engine_check
  CHECK (engine IN ('postgresql','mongodb','mysql','redis','sqlite','http'));
```

Migration file: `scripts/migrations/postgresql/014_add_http_engine.sql`.

### 2. Adapter registry resolver

In `query.service.ts`, build a `Map<string, IDatabaseAdapter>` keyed by engine name. Single dispatch path:

```ts
const adapter = this.adapters.get(engine);
if (!adapter) throw new BadRequestException(`Unsupported engine: ${engine}`);
return adapter.execute(connection_string, resource, dto.op, { ...dto, userId });
```

No more `if (engine === 'postgresql') ... else if (engine === 'mongodb')`.

### 3. Trino catalogs

New files under `apps/baas/mini-baas-infra/docker/services/trino/conf/catalog/`:

- `mysql.properties` — connector `mysql`, env-injected creds, pointing at a sample MySQL container added to compose.
- `iceberg.properties` — connector `iceberg`, REST or JDBC catalog, warehouse on MinIO via S3-compatible endpoint.

Add to `docker-compose.yml`:

- `mysql:8` service (extras profile).
- Iceberg REST catalog (`tabulario/iceberg-rest` or equivalent) wired to MinIO.

### 4. SDK codegen

In `apps/baas/sdk/`, add a `pnpm` script:

```json
"scripts": {
  "codegen": "openapi-typescript-codegen --input ../../baas/mini-baas-infra/openapi/query-router.json --output src/generated/query-router"
}
```

Aggregate every service's `/docs-json` at build time into `apps/baas/mini-baas-infra/openapi/` with a small script `scripts/openapi-collect.sh`.

Expose the user-facing surface:

```ts
baas.from('crm_contacts').select('id,name').eq('city', 'Paris').limit(50);
baas.from('crm_contacts').insert({ name: 'X' });
```

The implementation routes to the generated client based on the resource's registered engine.

### 5. PostgreSQL FDW bonus (optional but cheap)

Bake into `docker/services/postgres/Dockerfile`:

```dockerfile
RUN apk add --no-cache mysql-client \
 && cd /tmp \
 && apk add --no-cache --virtual .build-deps build-base postgresql-dev \
 && # build mysql_fdw and mongo_fdw extensions ...
```

This unlocks "any engine readable through PostgREST + RLS" with zero additional code — the cheapest path to dimension **b** completeness.

## Make gate

New file `scripts/verify/m2-federation.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "[M2] checking new engine modules registered"
for engine in postgresql mongodb mysql redis http; do
  curl -fsS "http://localhost:${QUERY_ROUTER_PORT}/engines" \
    | jq -e --arg e "$engine" '.engines | index($e)' >/dev/null \
    || { echo "[M2] FAIL: engine $engine not registered"; exit 1; }
done

echo "[M2] roundtrip insert+read on MySQL via query-router"
db_id=$(curl -fsS -X POST "${REGISTRY_URL}/databases" \
  -H "Authorization: Bearer ${ADMIN_JWT}" \
  --data '{"engine":"mysql","name":"m2-mysql","connection_string":"mysql://root:secret@mysql:3306/test"}' \
  | jq -r .id)

curl -fsS -X POST "https://localhost:8443/query/${db_id}/users" \
  -H "Authorization: Bearer ${USER_JWT}" \
  --data '{"op":"insert","data":{"name":"m2-probe"}}' >/dev/null

curl -fsS "https://localhost:8443/query/${db_id}/users?op=list&filter[name]=m2-probe" \
  -H "Authorization: Bearer ${USER_JWT}" \
  | jq -e '.rowCount >= 1' >/dev/null

echo "[M2] Trino catalogs reachable"
docker compose exec -T trino trino --execute "SHOW CATALOGS" \
  | grep -E '^(postgresql|mongodb|mysql|iceberg)$' | wc -l | grep -q '^[4-9]'

echo "[M2] Iceberg write via Trino"
docker compose exec -T trino trino --execute \
  "CREATE TABLE iceberg.default.m2_probe (id int, v varchar);
   INSERT INTO iceberg.default.m2_probe VALUES (1, 'm2');
   SELECT count(*) FROM iceberg.default.m2_probe;" \
  | grep -q '^1$'

echo "[M2] SDK codegen output exists"
test -f apps/baas/sdk/src/generated/query-router/index.ts

echo "[M2] OK"
```

## Done when

- `MysqlEngine`, `RedisEngine`, `HttpEngine` registered and reachable.
- A tenant database of each new engine type accepts a write and returns it on read via `query-router`.
- Trino lists ≥ 4 catalogs and successfully writes to Iceberg on MinIO.
- SDK exposes generated typed clients consumed by both frontends.
- `make baas-verify-m2` exits `0`.

## Out of scope

- Cassandra / Neo4j / Elasticsearch engines (M6).
- Cross-engine transactions (M3 handles eventual consistency only).
