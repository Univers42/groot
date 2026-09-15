# Backend milestones — état détaillé

Le backend est piloté par 9 jalons. Chacun a un script `scripts/verify/mX-*.sh`
qui est la source de vérité — si le script passe vert, le jalon est livré.

## Vue d'ensemble

| ID | Jalon | Gate | Static | Live | Notes |
|---|---|---|---|---|---|
| M1 | Hardening | `make baas-verify-m1` | ✅ | ✅ | HEALTHCHECK + IDatabaseAdapter + OpenAPI + audit_log |
| M2 | Federation | `make baas-verify-m2` | ✅ | ✅ | 5 engines (PG/Mongo/MySQL/Redis/HTTP) + Trino catalogs + SDK codegen |
| M3 | Coherence | `make baas-verify-m3` | ✅ | ✅ | Outbox + idempotency + RLS unifiée |
| M4 | Observability | `make baas-verify-m4` | ✅ | ⚠️ | Prometheus/Grafana/Loki/Promtail declared ; PrometheusModule.register() en dette |
| M5 | Security | `make baas-verify-m5` | ✅ | ✅ | WAF + Kong rate-limit + headers + Vault + scanner suite |
| M6 | FDW gateway | `make baas-verify-m6` | ✅ | ⚠️ | FDW supply-chain pins + tenant-scoped foreign table aliases |
| M7 | Adapter expansion | `make baas-verify-m7` | ✅ | ⚠️ | JDBC, Cassandra, Neo4j, Elasticsearch, Qdrant, Influx adapters |
| M8 | Saga/outbox | `make baas-verify-m8` | ✅ | ⚠️ | Debezium + generic saga target/compensation metadata |
| M9 | Central ABAC | `make baas-verify-m9` | ✅ | ⚠️ | Permission decision endpoint fail-closed before adapter dispatch |

Chaque gate chaîne le précédent (`baas-verify-m2: baas-verify-m1`, etc.) donc
`make baas-verify-all` rejoue tout du M1 au M9.

---

## M1 — Hardening

**Cible** : dimensions a (Docker-first), f (tooling), g (auditabilité light).

### Livrables

| Livrable | Statut | Référence |
|---|---|---|
| HEALTHCHECK dans tous les Dockerfiles | ✅ 17/17 | `grep -l '^HEALTHCHECK' docker/services/*/Dockerfile src/Dockerfile` |
| Contrat `IDatabaseAdapter` | ✅ | [`src/libs/database/src/adapter.contract.ts`](../../apps/baas/mini-baas-infra/src/libs/database/src/adapter.contract.ts) |
| DTO unifié `ExecuteQueryDto` avec enum `op` | ✅ | [`src/apps/query-router/src/query/dto/query.dto.ts`](../../apps/baas/mini-baas-infra/src/apps/query-router/src/query/dto/query.dto.ts) |
| OpenAPI sur les 13 services NestJS | ✅ | `SwaggerModule.setup('docs', app, doc)` dans chaque main.ts |
| Migration `013_audit_log.sql` | ✅ | [`scripts/migrations/postgresql/013_audit_log.sql`](../../apps/baas/mini-baas-infra/scripts/migrations/postgresql/013_audit_log.sql) |
| AuditInterceptor wired dans 7 services | ✅ | query-router, mongo-api, storage-router, permission-engine, gdpr-service, session-service, newsletter-service |
| Gate `make baas-verify-m1` exit 0 | ✅ | [`scripts/verify/m1-hardening.sh`](../../apps/baas/mini-baas-infra/scripts/verify/m1-hardening.sh) |

### Pourquoi c'est important

Sans `IDatabaseAdapter`, M2 aurait dupliqué les signatures divergentes de
`postgresql.engine.ts` et `mongodb.engine.ts` à chaque nouveau moteur.
Sans OpenAPI, le SDK codegen de M2 n'aurait rien à consommer. Sans
`audit_log`, l'outbox de M3 n'a pas de surface de traçage.

---

## M2 — Federation réelle

**Cible** : dimensions b (data federation), d (API & SDK unifiés).

### Livrables

| Livrable | Statut | Référence |
|---|---|---|
| `MysqlEngine` (CRUD + upsert + txIntra) | ✅ | [`mysql.engine.ts`](../../apps/baas/mini-baas-infra/src/apps/query-router/src/engines/mysql.engine.ts) |
| `RedisEngine` (KV/hash avec namespace tenant) | ✅ | [`redis.engine.ts`](../../apps/baas/mini-baas-infra/src/apps/query-router/src/engines/redis.engine.ts) |
| `HttpEngine` (REST via fetch natif) | ✅ | [`http.engine.ts`](../../apps/baas/mini-baas-infra/src/apps/query-router/src/engines/http.engine.ts) |
| Dispatcher unifié `Map<string, IDatabaseAdapter>` | ✅ | [`query.service.ts`](../../apps/baas/mini-baas-infra/src/apps/query-router/src/query/query.service.ts) |
| Migration 014 (CHECK constraint includes 'http') | ✅ | [`014_add_http_engine.sql`](../../apps/baas/mini-baas-infra/scripts/migrations/postgresql/014_add_http_engine.sql) |
| Endpoint `GET /engines` (introspection) | ✅ | [`engines.controller.ts`](../../apps/baas/mini-baas-infra/src/apps/query-router/src/query/engines.controller.ts) |
| Trino catalogs `mysql` + `iceberg` | ✅ | [`conf/catalog/`](../../apps/baas/mini-baas-infra/docker/services/trino/conf/catalog/) |
| Compose : mysql:8.4 + iceberg-rest + minio-iceberg-init | ✅ | `docker-compose.yml` |
| SDK codegen pipeline Docker-only | ✅ | [`scripts/openapi-collect.sh`](../../apps/baas/mini-baas-infra/scripts/openapi-collect.sh) + [`apps/baas/sdk/scripts/codegen.mjs`](../../apps/baas/sdk/scripts/codegen.mjs) |
| Gate `make baas-verify-m2` exit 0 | ✅ | [`scripts/verify/m2-federation.sh`](../../apps/baas/mini-baas-infra/scripts/verify/m2-federation.sh) |

### Engines registry

```ts
this.adapters = new Map<string, IDatabaseAdapter>();
for (const adapter of [
  pgEngine,     // postgresql — CRUD via pg, RLS via SET LOCAL app.current_user_id
  mongoEngine,  // mongodb    — CRUD via MongoClient, owner_id injection
  mysqlEngine,  // mysql      — CRUD via mysql2/promise, ON DUPLICATE KEY upsert
  redisEngine,  // redis      — KV/hash via ioredis, userId:resource:id prefix
  httpEngine,   // http       — REST via fetch natif, JSON {baseUrl, headers, routes}
] as IDatabaseAdapter[]) {
  this.adapters.set(adapter.engine, adapter);
}
```

### Pourquoi Trino n'est PAS un moteur OLTP universel

Trino est un moteur **analytique fédéré**. Il sait lire avec une syntaxe SQL
commune dans PG, Mongo, MySQL, Iceberg, etc. — mais write support varie :

| Engine | Trino READ | Trino WRITE |
|---|---|---|
| PostgreSQL | ✅ | ✅ partiel (INSERT, UPDATE limité) |
| MySQL | ✅ | ✅ partiel |
| MongoDB | ✅ | ⚠️ read-only dans la plupart des versions |
| Redis | ✅ | ❌ read-only |
| Elasticsearch | ✅ | ❌ read-only |
| Iceberg | ✅ | ✅ (cas d'usage principal) |

Donc CRUD transactionnel passe par `IDatabaseAdapter` (M1+M2), Trino sert
uniquement à l'analytique cross-engine.

---

## M3 — Cohérence multi-engine

**Cible** : dimensions c (cohérence cross-engine), g (traçabilité).

### Livrables

| Livrable | Statut | Référence |
|---|---|---|
| Migration `015_outbox.sql` (table outbox_events) | ✅ | [`scripts/migrations/postgresql/`](../../apps/baas/mini-baas-infra/scripts/migrations/postgresql/) |
| Service `outbox-relay` (PG WAL → Redis Streams → Mongo projection) | ✅ | [`src/apps/outbox-relay/`](../../apps/baas/mini-baas-infra/src/apps/outbox-relay/) |
| Idempotency-Key middleware | ✅ | DTO accepte `idempotencyKey`, middleware sur mutations critiques |
| RLS unifiée (`request.jwt.claims`) | ✅ | Migration de `app.current_user_id` legacy vers le format PostgREST/GoTrue |
| Gate `make baas-verify-m3` rejoue PG INSERT → outbox → Redis → Mongo | ✅ | [`scripts/verify/m3-coherence.sh`](../../apps/baas/mini-baas-infra/scripts/verify/m3-coherence.sh) |

### Garantie

C'est de la **cohérence eventually consistent**, pas atomique cross-engine
(qui est impossible sans transaction distribuée). Le pattern outbox garantit
qu'une écriture qui réussit en PG sera **finalement** propagée à Mongo, avec
audit et replay possibles.

---

## M4 — Observabilité

**Cible** : dimensions e (observabilité), g (traçabilité bout en bout).

### Livrables

| Livrable | Statut | Référence |
|---|---|---|
| Services compose (prometheus / grafana / loki / promtail) | ✅ | `docker-compose.yml` profile `observability` |
| `CorrelationIdInterceptor` propage X-Request-ID | ✅ | [`src/libs/common/src/interceptors/correlation-id.interceptor.ts`](../../apps/baas/mini-baas-infra/src/libs/common/src/interceptors/correlation-id.interceptor.ts) |
| audit_log carries request_id (cross-system trace) | ✅ | Migration 013 |
| Gate `make baas-verify-m4` static | ✅ | [`scripts/verify/m4-observability.sh`](../../apps/baas/mini-baas-infra/scripts/verify/m4-observability.sh) |
| `PrometheusModule.register()` dans app.module.ts | ⚠️ | **Dette** — seulement les helpers (`makeHistogramProvider`, `InjectMetric`) sont importés. `/metrics` endpoint pas exposé. |
| OpenTelemetry + Tempo (traces distribuées) | ⚠️ | Non livré — M4.c |

### Live mode

Le gate `--live` vérifie :
- Prometheus `/-/ready` 200 + ≥ 1 target scrapé up
- Grafana `/api/health.database == "ok"`
- Loki `/ready` 200

Pour que ça passe, il faut lancer le profile observability :

```bash
BAAS_VERIFY_SAFE_PORTS=1 BAAS_VERIFY_OBSERVABILITY=1 make baas-up
BAAS_VERIFY_LIVE=1 BAAS_VERIFY_SAFE_PORTS=1 make baas-verify-m4
```

---

## M5 — Sécurité durcie

**Cible** : dimension e (sécurité).

### Livrables

| Livrable | Statut | Référence |
|---|---|---|
| WAF nginx + ModSecurity v3 + OWASP CRS 4 | ✅ | [`docker/services/waf/`](../../apps/baas/mini-baas-infra/docker/services/waf/) |
| CRS setup avec `tx.crs_setup_version` (sinon fails closed) | ✅ | [`conf/crs-setup.conf`](../../apps/baas/mini-baas-infra/docker/services/waf/conf/crs-setup.conf) |
| Kong rate-limiting (auth: 300/min, rest: 180/min, realtime: 120/min) | ✅ | [`docker/services/kong/conf/kong.yml`](../../apps/baas/mini-baas-infra/docker/services/kong/conf/kong.yml) |
| Security headers (HSTS, X-CTO, X-FO, Referrer-Policy) | ✅ | Kong response-transformer plugin |
| Vault wired pour JWT_SECRET + secrets long-lived | ✅ | Compose + `vault-env.mjs` |
| SAST orchestrator (Semgrep) | ✅ | [`scripts/security/run-security-scans.sh`](../../apps/baas/mini-baas-infra/scripts/security/run-security-scans.sh) |
| SCA orchestrator (npm + pnpm audit) | ✅ | idem |
| Container scanner (Trivy fs + image) | ✅ | idem |
| Secret scanner (TruffleHog) | ✅ | idem |
| DAST baseline (ZAP) | ✅ | [`scripts/verify/zap-baseline.sh`](../../apps/baas/mini-baas-infra/scripts/verify/zap-baseline.sh) |
| GitHub Actions workflow (7 jobs) | ✅ | [`.github/workflows/mini-baas-security.yml`](../../.github/workflows/mini-baas-security.yml) |
| Gate `make baas-verify-m5` static + live | ✅ | [`scripts/verify/m5-security.sh`](../../apps/baas/mini-baas-infra/scripts/verify/m5-security.sh) |

### Live probes

Avec `--live` (stack up requis) :
- WAF `/waf-health` → 2xx
- CRS bloque un SQLi probe → 403
- Kong rate-limit fire → 429 après burst de 320 requêtes
- Headers de sécurité présents dans la réponse
- Vault unsealed

### Dette résiduelle

- **Snyk** integration CI conditionnelle (token à configurer dans Settings).
- **Trivy ignore policy** (`.trivyignore`) si certains CVEs ne sont pas
  patchables (transitive deps).
- **ZAP authenticated scan** — la baseline ne touche que les routes publiques.
- **SBOM (CycloneDX)** — à générer en CI pour conformité supply-chain.
- **Pre-commit TruffleHog hook** — recommandé pour bloquer les secrets avant
  qu'ils n'atteignent git.

---

## M6 — FDW gateway agnostique

**Cible** : dimension b (fédération data-plane), avec un plan PostgreSQL FDW
pour les sources que l'on veut exposer comme tables étrangères.

### Livrables

| Livrable | Statut | Référence |
|---|---|---|
| Image Postgres avec manifest FDW versionné + checksums | ✅ | [`docker/services/postgres/Dockerfile`](../../apps/baas/mini-baas-infra/docker/services/postgres/Dockerfile) |
| Migration `020_fdw_servers.sql` | ✅ | [`020_fdw_servers.sql`](../../apps/baas/mini-baas-infra/scripts/migrations/postgresql/020_fdw_servers.sql) |
| Table `fdw_external_resources` tenant-scoped | ✅ | Migration 020 |
| Helpers `ensure_fdw_extension`, `materialize_fdw_server`, `register_fdw_foreign_table` | ✅ | Migration 020 |
| `register_via_fdw` côté adapter-registry | ✅ | [`databases.service.ts`](../../apps/baas/mini-baas-infra/src/apps/adapter-registry/src/databases/databases.service.ts) |
| Gate `make baas-verify-m6` | ✅ | [`m6-fdw.sh`](../../apps/baas/mini-baas-infra/scripts/verify/m6-fdw.sh) |

### Garantie

Le FDW n'est pas utilisé comme contournement sécurité : l'alias est enregistré
par tenant, les options passent par JSONB, les identifiants SQL sont quotés, et
les extensions sont activées explicitement par allow-list d'engine.

---

## M7 — Extension adapters

**Cible** : dimension d (API unique sur moteurs hétérogènes).

### Livrables

| Livrable | Statut | Référence |
|---|---|---|
| `JdbcEngine` via sidecar REST `/execute` | ✅ | [`jdbc.engine.ts`](../../apps/baas/mini-baas-infra/src/apps/query-router/src/engines/jdbc.engine.ts) |
| `CassandraEngine` via API REST DataStax-style | ✅ | [`cassandra.engine.ts`](../../apps/baas/mini-baas-infra/src/apps/query-router/src/engines/cassandra.engine.ts) |
| `Neo4jEngine` via endpoint transactionnel HTTP | ✅ | [`neo4j.engine.ts`](../../apps/baas/mini-baas-infra/src/apps/query-router/src/engines/neo4j.engine.ts) |
| `ElasticsearchEngine` avec filtre obligatoire `ownerId` | ✅ | [`elasticsearch.engine.ts`](../../apps/baas/mini-baas-infra/src/apps/query-router/src/engines/elasticsearch.engine.ts) |
| `QdrantEngine` avec payload tenant-scoped | ✅ | [`qdrant.engine.ts`](../../apps/baas/mini-baas-infra/src/apps/query-router/src/engines/qdrant.engine.ts) |
| `InfluxEngine` v2 write/query API | ✅ | [`influx.engine.ts`](../../apps/baas/mini-baas-infra/src/apps/query-router/src/engines/influx.engine.ts) |
| Migration `021_extend_engine_check.sql` | ✅ | [`021_extend_engine_check.sql`](../../apps/baas/mini-baas-infra/scripts/migrations/postgresql/021_extend_engine_check.sql) |
| Gate `make baas-verify-m7` | ✅ | [`m7-adapters.sh`](../../apps/baas/mini-baas-infra/scripts/verify/m7-adapters.sh) |

### Garantie

Tous les nouveaux moteurs implémentent `IDatabaseAdapter` et sont enregistrés
dans `QueryModule`; le dispatcher reste un registry par capabilities, pas une
suite de branches spécifiques par engine.

---

## M8 — Outbox, Debezium et sagas génériques

**Cible** : dimension c (cohérence cross-engine) à l'échelle multi-adapter.

### Livrables

| Livrable | Statut | Référence |
|---|---|---|
| Debezium Server configuré sur `public.outbox_events` | ✅ | [`docker/services/debezium/application.properties`](../../apps/baas/mini-baas-infra/docker/services/debezium/application.properties) |
| Postgres `wal_level=logical` | ✅ | [`docker-compose.yml`](../../apps/baas/mini-baas-infra/docker-compose.yml) |
| Migration `022_outbox_saga_fields.sql` | ✅ | [`022_outbox_saga_fields.sql`](../../apps/baas/mini-baas-infra/scripts/migrations/postgresql/022_outbox_saga_fields.sql) |
| `SagaCoordinatorService` | ✅ | [`saga-coordinator.service.ts`](../../apps/baas/mini-baas-infra/src/apps/outbox-relay/src/saga-coordinator.service.ts) |
| Outbox relay compatible avant/après migration 022 | ✅ | [`outbox-relay.service.ts`](../../apps/baas/mini-baas-infra/src/apps/outbox-relay/src/outbox-relay.service.ts) |
| Query outbox enrichi `targetEngine`, `targetResource`, `compensationPayload`, `idempotencyKey` | ✅ | [`outbox.service.ts`](../../apps/baas/mini-baas-infra/src/apps/query-router/src/query/outbox.service.ts) |
| Gate `make baas-verify-m8` | ✅ | [`m8-saga.sh`](../../apps/baas/mini-baas-infra/scripts/verify/m8-saga.sh) |

### Garantie

La propagation reste eventually consistent, avec idempotency key et état de saga
dans l'outbox. Les colonnes M8 sont consommées seulement si la migration existe,
ce qui évite de casser un déploiement pendant la fenêtre de migration.

---

## M9 — ABAC centralisé avant dispatch

**Cible** : dimension e (sécurité) et g (auditabilité décisionnelle).

### Livrables

| Livrable | Statut | Référence |
|---|---|---|
| Endpoint `POST /permissions/decide` protégé par service token | ✅ | [`decisions.controller.ts`](../../apps/baas/mini-baas-infra/src/apps/permission-engine/src/decisions/decisions.controller.ts) |
| Décision ABAC basée sur `public.has_permission()` | ✅ | [`decisions.service.ts`](../../apps/baas/mini-baas-infra/src/apps/permission-engine/src/decisions/decisions.service.ts) |
| DTO de décision user/resource/op/attributes | ✅ | [`decision.dto.ts`](../../apps/baas/mini-baas-infra/src/apps/permission-engine/src/decisions/dto/decision.dto.ts) |
| Query-router fail-closed avant `adapter.execute()` | ✅ | [`query.service.ts`](../../apps/baas/mini-baas-infra/src/apps/query-router/src/query/query.service.ts) |
| Field masks `hide` / `redact` issus des policy conditions | ✅ | Permission engine + query-router |
| Gate `make baas-verify-m9` | ✅ | [`m9-abac.sh`](../../apps/baas/mini-baas-infra/scripts/verify/m9-abac.sh) |

### Garantie

Le point d'entrée query-router demande une décision au permission-engine avant
de toucher un adapter. Si le moteur ABAC est indisponible, la requête échoue en
`503` plutôt que de passer sans contrôle.

---

## Comment passer un jalon à "live green"

1. `BAAS_VERIFY_SAFE_PORTS=1 BAAS_VERIFY_NO_WAF=0 make baas-up` (ou inclure
   les profils requis).
2. Attendre que tous les `--wait` containers soient healthy.
3. `BAAS_VERIFY_LIVE=1 BAAS_VERIFY_SAFE_PORTS=1 make baas-verify-mX`.

Si un check échoue, le script affiche `[Mx] FAIL: <raison>` avec la ligne
exacte qui a planté. Tu corriges, tu re-relances. Pas de magie.
