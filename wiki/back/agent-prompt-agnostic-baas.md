# Agent prompt — finir l'agnostic BaaS jusqu'au bout

> Ce fichier est un **prompt d'ingénierie** destiné à un agent (Claude Code,
> Cursor, Copilot Workspace, ou un humain) pour livrer la fin de la vision
> agnostique du backend. Il s'appuie sur le draft conceptuel
> [`wiki/back/agnostic_back.md`](./agnostic_back.md) et sur ce qui a été
> livré dans les jalons M1 → M5 (voir [`milestones.md`](./milestones.md) et
> [`CHANGELOG.md`](./CHANGELOG.md)).
>
> **Le but** : passer d'un BaaS qui parle à 5 engines (PG / Mongo / MySQL /
> Redis / HTTP) à un BaaS qui parle à **n'importe quel engine** (SQL,
> document, KV, wide-column, graph, search, time-series, vector, lakehouse,
> SaaS HTTP), avec :
> - une **API client unique** (le SDK `@mini-baas/js`),
> - une **politique de sécurité homogène** appliquée au-dessus des engines
>   (parce que leurs modèles natifs sont incompatibles),
> - des **écritures fiables** via outbox + saga (parce qu'il n'existe pas
>   de transaction ACID cross-engine).

---

## 0. État courant — ce qui est DÉJÀ livré

L'agent ne doit **rien réécrire** de ce qui suit. C'est la base.

### Couche routing & contrats

- `IDatabaseAdapter` (contrat TS) dans [`src/libs/database/src/adapter.contract.ts`](../../apps/baas/mini-baas-infra/src/libs/database/src/adapter.contract.ts) — méthodes `execute(connectionString, resource, op, opts)`, `listResources()`, `capabilities()`.
- `AdapterOp` : `list | get | insert | update | delete | upsert`.
- `EngineCaps` : `{ read, write, upsert, txIntra, stream }`.
- `query-router` enregistre 5 engines via `Map<string, IDatabaseAdapter>` :
  - `PostgresqlEngine` (RLS via `SET LOCAL app.current_user_id`)
  - `MongodbEngine` (owner_id auto-injecté)
  - `MysqlEngine` (mysql2/promise, upsert via `ON DUPLICATE KEY UPDATE`)
  - `RedisEngine` (ioredis, namespace `userId:resource:id`)
  - `HttpEngine` (fetch natif, `connection_string` JSON `{baseUrl, headers, routes}`)
- Endpoint `GET /engines` (controller dédié, public) qui expose la liste +
  capabilities de chaque adapter mounté.

### Couche analytics fédérée

- `trino` 467 avec catalogs `postgresql`, `mongodb`, `mysql`, `iceberg`.
- `iceberg-rest:1.6.1` + bootstrap `minio-iceberg-init` du bucket S3.

### Couche cohérence (M3)

- Migration `015_outbox.sql` : table `outbox_events`.
- Service `outbox-relay` (NestJS) : poll PG → publish Redis Streams → projection Mongo.
- Header `Idempotency-Key` accepté sur mutations.

### Couche sécurité (M5)

- WAF nginx + ModSecurity v3 + OWASP CRS 4 (bloque SQLi → 403).
- Kong : rate-limit (300/min auth, 180/min rest, 120/min realtime), security headers (HSTS, X-CTO, X-FO, Referrer-Policy, Permissions-Policy, COOP, CORP), removal des headers leaking (`Server`, `X-Powered-By`, `Via`).
- Vault : `JWT_SECRET`, OAuth, SMTP, AES master key.
- AuditModule wired dans 7 services mutants → table `audit_log` avec `request_id` corrélé bout-en-bout.
- Scanner suite Docker-only : Semgrep (0 ERROR), npm/pnpm audit, Trivy, TruffleHog (0 verified secrets), ZAP (0 High-risk).
- CI `.github/workflows/mini-baas-security.yml` (7 jobs).

### Couche observabilité (M4)

- prometheus + grafana + loki + promtail (profile `observability`).
- `CorrelationIdInterceptor` propage `X-Request-ID` partout.
- `audit_log.request_id` corrèle traces & logs cross-system.

---

## 1. Mission — ce qui reste à livrer

Pour atteindre **"BaaS agnostique entièrement, tous les engines, sécurité by design"**, il manque 5 chantiers découpés en jalons M6 → M10.

| Jalon | Objet | Effort | Risque |
|---|---|---|---|
| **M6** | PostgreSQL FDWs — multiplier la surface "lecture/écriture via PostgREST" à coût zéro | 1-2 j | faible |
| **M7** | Adapters supplémentaires (JDBC, graph, search, vector, wide-column, time-series) | 3-5 j | moyen |
| **M8** | Outbox → Debezium → Redis Streams + sagas (généralisation à tous engines secondaires) | 2-3 j | moyen-élevé |
| **M9** | Centralized ABAC (extraction du modèle ABAC actuel en service dédié + intégration policy avant chaque write) | 2 j | moyen |
| **M10** | Codegen SDK depuis l'`adapter-registry` (types TypeScript par resource, capabilities à la compilation) | 1-2 j | faible |

Chaque jalon a un script `scripts/verify/mX-*.sh` qui exit 0 quand le livrable est défensible.

---

## 2. Le prompt à donner à l'agent

> Copie-colle ce bloc à l'agent. Tout ce dont il a besoin est dedans.

```text
You are working on a multi-database BaaS called mini-baas-infra (NestJS + Docker Compose, 13 services, 5 engines already wired via IDatabaseAdapter).

CONTEXT — already shipped, do NOT rewrite:
  • M1 hardening: HEALTHCHECK on every Dockerfile, IDatabaseAdapter contract, unified ExecuteQueryDto (op: list|get|insert|update|delete|upsert), audit_log table (013), AuditInterceptor wired in 7 mutating services, OpenAPI on every NestJS app.
  • M2 federation: 5 engines (PostgresqlEngine, MongodbEngine, MysqlEngine, RedisEngine, HttpEngine) all implements IDatabaseAdapter, dispatched via Map<string, IDatabaseAdapter> in query.service.ts. Trino catalogs postgresql/mongodb/mysql/iceberg. SDK codegen pipeline via Docker.
  • M3 coherence: outbox_events table (015), outbox-relay service (PG WAL → Redis Streams → Mongo projection), Idempotency-Key middleware, RLS via current_setting('request.jwt.claims').
  • M4 observability: prometheus/grafana/loki/promtail declared, CorrelationIdInterceptor propagates X-Request-ID, audit_log carries request_id.
  • M5 security: WAF nginx+ModSecurity+OWASP CRS 4 (blocks SQLi → 403), Kong rate-limit + hardened response headers, Vault for JWT_SECRET, scanner suite (Semgrep/npm-audit/Trivy/TruffleHog) Docker-only, ZAP DAST, CI workflow mini-baas-security.yml.

MISSION — deliver M6 through M10 such that the BaaS can read AND write to ANY database engine (SQL, document, KV, wide-column, graph, search, time-series, vector, lakehouse, SaaS HTTP) behind a single client SDK, with security enforced at the gateway (not at the engine).

NON-NEGOTIABLE INVARIANTS (security by design):
  1. Every write request passes ABAC evaluation at the gateway BEFORE reaching any engine. Native engine ACLs are not relied upon for tenant isolation — those models are incompatible across engines, so they cannot be the source of truth.
  2. Every adapter receives `userId` in QueryOpts and is REQUIRED to apply tenant isolation: PG uses RLS via `SET LOCAL`, Mongo injects owner_id, Redis namespaces keys with `userId:`, HTTP forwards `X-Owner-Id`. New adapters MUST follow this pattern.
  3. No secret is read from compose env directly when Vault is available — `vault-env.mjs` is the source of truth.
  4. Every mutating route writes to `audit_log` with the request_id (the AuditInterceptor already does this; new services MUST import AuditModule).
  5. ALL new engines must declare `capabilities()` HONESTLY. If an engine cannot do `upsert` natively, return `{ upsert: false }` and throw NotImplementedException — never silently degrade to insert.
  6. Schema validation (Zod or class-validator) MUST happen at the gateway before payloads reach engines. Per-engine validation is a defense-in-depth bonus, never the only check.
  7. Connection strings to user-registered external databases are stored AES-256-GCM with explicit `authTagLength: 16` (the pattern is in adapter-registry/crypto.service.ts).

DELIVERABLES, in order — each jalon has its own verify gate that must exit 0:

──────────────────────────────────────────────────────────────────────────────
M6 — PostgreSQL FDW universal gateway (1-2 days, low risk)
──────────────────────────────────────────────────────────────────────────────
GOAL: extend PostgREST's reach to MySQL, MSSQL, MongoDB, Oracle, Redis, ES, ClickHouse, SQLite, CSV, HTTP — all behind the existing RLS + GoTrue + JWT chain. The client uses PostgREST as usual; tables live elsewhere.

WORK:
  1. Bake FDW extensions into docker/services/postgres/Dockerfile:
       • mysql_fdw, mongo_fdw, tds_fdw (MSSQL), oracle_fdw,
       • redis_fdw, clickhousedb_fdw,
       • multicorn (Python-based FDW framework — unlocks HTTP/GraphQL/ES via small adapters),
       • file_fdw + sqlite_fdw (built-in / lightweight).
     Use multi-stage build: compile each FDW in a builder stage, copy .so files only.
  2. Create migration 020_fdw_servers.sql that declares CREATE EXTENSION for each, and seeds CREATE SERVER + CREATE USER MAPPING templates as PL/pgSQL functions callable from adapter-registry.
  3. Extend adapter-registry: when a tenant registers an external DB with `register_via_fdw: true`, the registry calls the PL/pgSQL helper to materialize a Foreign Table that aliases the external resource. RLS automatically applies because the foreign table inherits the workspace.
  4. New verify script scripts/verify/m6-fdw.sh:
       • CREATE EXTENSION succeeds for each FDW in a fresh PG.
       • SELECT through a sample mysql_fdw foreign table returns expected rows + applies `auth.uid() = owner_id` predicate (RLS pushdown OR application-side filter).
       • INSERT through mongo_fdw foreign table appears in the source Mongo.
       • The ACTUAL connector versions are pinned in the Dockerfile via known SHAs/checksums (supply chain hardening, mandatory).
  5. Update wiki/back/CHANGELOG.md with a "M6 — FDW universal gateway" section.

──────────────────────────────────────────────────────────────────────────────
M7 — New IDatabaseAdapter implementations (3-5 days, medium risk)
──────────────────────────────────────────────────────────────────────────────
GOAL: cover everything that FDW can't or shouldn't handle (Neo4j, Cassandra, Elasticsearch, Qdrant, InfluxDB, generic JDBC fallback).

WORK — one adapter per concern, each implements IDatabaseAdapter:
  • src/apps/query-router/src/engines/jdbc.engine.ts
      Generic JDBC adapter (uses `node-jdbc` or shell out to a Java sidecar — choose the lighter path). Covers Oracle, DB2, Snowflake, Aurora, CockroachDB. capabilities = {read:true, write:true, upsert:engine-dependent, txIntra:true, stream:false}.
  • src/apps/query-router/src/engines/cassandra.engine.ts
      Use `cassandra-driver`. Tenant isolation via mandatory partition key prefix = userId. Capabilities = {read:true, write:true, upsert:true (INSERT == upsert in CQL), txIntra:false, stream:true via CDC}.
  • src/apps/query-router/src/engines/neo4j.engine.ts
      Use `neo4j-driver`. Adapter maps `op`:
        - list → MATCH (n:Resource {ownerId:$u}) RETURN n LIMIT ...
        - insert → CREATE (n:Resource $data) SET n.ownerId = $u
        - update → MATCH (n {id:$id, ownerId:$u}) SET n += $patch
        - delete → MATCH (n {id:$id, ownerId:$u}) DETACH DELETE n
        - upsert → MERGE (n {id:$id, ownerId:$u}) ON CREATE/MATCH SET ...
      capabilities = {read:true, write:true, upsert:true, txIntra:true, stream:false}.
  • src/apps/query-router/src/engines/elasticsearch.engine.ts
      Use `@elastic/elasticsearch`. Tenant filter is a mandatory `term {ownerId:$u}` injected into every query. Capabilities = {read:true, write:true, upsert:true (index w/ id == upsert), txIntra:false, stream:false}.
  • src/apps/query-router/src/engines/qdrant.engine.ts
      Use `@qdrant/js-client-rest`. Vector store — resource maps to a collection, point.payload.ownerId carries tenant. Capabilities = {read:true, write:true, upsert:true, txIntra:false, stream:false}.
  • src/apps/query-router/src/engines/influx.engine.ts
      Use `@influxdata/influxdb-client`. Time-series — list maps to a Flux query, insert to a write API call. Tag every point with `ownerId` for tenant isolation. Capabilities = {read:true, write:true, upsert:false, txIntra:false, stream:false}.

  For each adapter:
    a. Register it in QueryService constructor + add to this.adapters Map.
    b. Add its driver dependency to apps/baas/mini-baas-infra/src/package.json.
    c. Bump the tenant_databases.engine CHECK constraint via a new migration.
    d. Document its capabilities + tenant isolation strategy in wiki/back/agent-prompt-agnostic-baas.md (this file).
    e. Add a section in scripts/verify/m7-adapters.sh that round-trips insert → list → delete via the live query-router for each adapter.

──────────────────────────────────────────────────────────────────────────────
M8 — Outbox / Debezium / Saga generalization (2-3 days, medium-high risk)
──────────────────────────────────────────────────────────────────────────────
GOAL: any write to PG can be reliably propagated to any other engine, with compensating transactions on failure.

WORK:
  1. Add the Debezium service to docker-compose.yml (profile: data-plane) with the PostgreSQL connector. Configure it to publish onto Redis Streams (existing) — topic per resource. Reuse the existing outbox-relay as the consumer skeleton; specialize one consumer per target engine.
  2. Extend the outbox_events row to carry: target_engine, target_resource, op, payload, compensation_payload (for sagas).
  3. Create a SagaCoordinator service (or extend outbox-relay) that:
       • Reads outbox_events in order per aggregate.
       • For each event, dispatches to the relevant adapter via IDatabaseAdapter.execute.
       • On failure beyond N retries, executes the compensation_payload (reverse op) on PG so the system stays eventually consistent.
  4. Idempotency-Key middleware (already present in M3) must propagate to consumers so a replayed event does not double-write.
  5. Verify script scripts/verify/m8-saga.sh:
       • Insert in PG with cross-engine target → assert it lands in Mongo + Cassandra within N seconds, audit_log shows the request_id chain.
       • Force the Mongo consumer to fail → assert compensation executes on PG within N seconds.

──────────────────────────────────────────────────────────────────────────────
M9 — Centralized ABAC service (2 days, medium risk)
──────────────────────────────────────────────────────────────────────────────
GOAL: extract the ABAC logic from the current ad-hoc places (RolesGuard + AccessRule in object_database + has_permission() PL/pgSQL) into a single permission-engine endpoint that EVERY mutating request consults.

WORK:
  1. permission-engine already exists. Extend it to expose a single decision endpoint:
       POST /permissions/decide
         body: { user, resource_type, resource_name, op, attributes }
         response: { allow: bool, reason: string, mask: {...optional field-level mask...} }
  2. Implement the policy resolution in this order:
       a. Static deny rules (role blacklist, hour-of-day, IP allowlist) — DB-backed in resource_policies.
       b. Attribute match (resource owner, workspace member, JWT claim).
       c. Conditions JSONB (e.g. `{owner_only: true}` from migration 007 already in the codebase).
       d. Default deny if nothing matched.
     Use the deny-first / priority-DESC ordering already in has_permission() — promote that SQL function to be the in-PG evaluator and expose it via the HTTP endpoint.
  3. Wire EVERY adapter's execute() to call permission-engine.decide() BEFORE dispatching the op:
       const decision = await this.permissions.decide(userId, this.engine, resource, op, ctx);
       if (!decision.allow) throw new ForbiddenException(decision.reason);
  4. Verify script scripts/verify/m9-abac.sh:
       • A user with role=member writes to a resource where deny rule exists → 403, no row in audit_log past the decision.
       • A user with role=admin overrides via priority — passes.
       • A field-level mask applied to a read response actually hides forbidden fields.

──────────────────────────────────────────────────────────────────────────────
M10 — SDK codegen from adapter-registry (1-2 days, low risk)
──────────────────────────────────────────────────────────────────────────────
GOAL: the SDK client gets typed surfaces per registered resource, including capabilities at the type level — so calling `.upsert()` on a Redis-backed resource doesn't compile if the engine doesn't declare upsert support.

WORK:
  1. Extend scripts/openapi-collect.sh to also dump adapter-registry's /resources endpoint (it already lists tenant_databases + schema_registry).
  2. Extend apps/baas/sdk/scripts/codegen.mjs to:
       a. For each registered resource, generate a typed Builder class:
            class CrmContactsBuilder { select(...), eq(...), insert(...), ... }
       b. Conditional methods based on capabilities: insert/update/delete only present if {write:true}, upsert only if {upsert:true}, on() only if {stream:true}.
       c. The top-level baas.from('crm_contacts') returns the typed builder.
  3. Document in apps/baas/sdk/README.md (create if absent) with the supabase-like example:
       const db = baas.from('crm_contacts');
       await db.select('id,name,email').eq('city', 'Paris').limit(50);
       await db.insert({ name: 'X' });
       db.on('INSERT', (payload) => { ... });
  4. Verify script scripts/verify/m10-sdk.sh runs `pnpm typecheck` on a tiny consumer that uses the generated client and asserts that a write to a {write:false} engine fails AT COMPILE TIME, not runtime.

──────────────────────────────────────────────────────────────────────────────

GLOBAL ACCEPTANCE — when ALL of the following are green, the agnostic vision is "shipped":

  • make baas-verify-all           → exit 0 (M1..M10 chained)
  • make baas-security-scan        → 0 ERROR Semgrep, 0 verified TruffleHog secret, 0 HIGH/CRITICAL Trivy
  • make baas-zap                  → 0 High-risk findings
  • GET /engines                   → returns ≥ 10 engines with capabilities
  • A round-trip test that inserts into PG, lets the saga propagate to Mongo + Cassandra + ES + Qdrant + Influx, and verifies the projection in each — completes in < 5 seconds with idempotent retries.
  • SDK consumer that tries .upsert() on a Redis-backed resource with {upsert:false} → compile error.

WORKFLOW INSTRUCTIONS for the agent:
  1. Read wiki/back/CHANGELOG.md and wiki/back/milestones.md before starting.
  2. Pick ONE jalon (M6 → M10) per session. Don't try to ship two at once.
  3. Write the verify script FIRST (TDD-ish) — the script tells you when you're done.
  4. Use Docker for every new tool. Never install on the host.
  5. Run `make baas-verify-m{previous}` before starting a new jalon — never build on a broken predecessor.
  6. Update the CHANGELOG in the same commit as the code.
  7. If a deliverable requires a NEW dep in apps/baas/mini-baas-infra/src/package.json, also add it to .github/workflows/mini-baas-security.yml's matrix so the SCA gate audits it.
  8. Honour the non-negotiable invariants list. If you find a place where they're violated, fix it BEFORE adding new functionality.

When done, the BaaS satisfies the user-facing promise:
  > One SDK call. Any engine. ABAC checked at the gate. Audit row written.
  > Cross-engine writes are eventually consistent with compensations.
  > Cross-engine reads (analytics) go through Trino. Streams are unified
  > on Redis Streams. The client knows nothing about the underlying engine.
```

---

## 3. Diagramme cible (post-M10)

```
                              ┌──────────────────────────┐
                              │  Client (osionos / SDK)  │
                              └────────────┬─────────────┘
                                           │ HTTPS + JWT
                                           ▼
                                ┌──────────────────────┐
                                │ WAF (CRS)            │ ◄ M5 done
                                ├──────────────────────┤
                                │ Kong (rate-limit,    │
                                │ JWT, security headers│
                                └──────────┬───────────┘
                                           │
        ┌──────────────────────────────────┼──────────────────────────────────┐
        ▼                                  ▼                                  ▼
   PostgREST                       query-router                          Trino (R/O)
   (RLS, auth.uid)                 (Map<eng, IDatabaseAdapter>)          catalogs:
   + FDWs (M6)                                                           PG / Mongo /
   ───────────────                                                       MySQL / Iceberg
   tables externes :                                                     + (M7 catalogs)
   mysql / mongo / es                ABAC decision @ M9
   redis / clickhouse                       │
   oracle / mssql                           ▼
                                  ┌─────────────────────┐
                                  │ Engines (M2+M7)     │
                                  │ ─ postgresql        │
                                  │ ─ mongodb           │
                                  │ ─ mysql             │
                                  │ ─ redis             │
                                  │ ─ http              │
                                  │ ─ jdbc (M7)         │
                                  │ ─ cassandra (M7)    │
                                  │ ─ neo4j (M7)        │
                                  │ ─ elasticsearch (M7)│
                                  │ ─ qdrant (M7)       │
                                  │ ─ influx (M7)       │
                                  └──────────┬──────────┘
                                             │
                              ┌──────────────┴──────────────┐
                              │ outbox_events (PG, M3)      │
                              │ + Debezium (M8)             │
                              │ → Redis Streams             │
                              │ → Saga consumers (per eng)  │
                              │ → audit_log (M1 corrélation)│
                              └─────────────────────────────┘
```

---

## 4. Pourquoi cette architecture tient la route (et où sont ses vraies limites)

### Ce qui rend l'approche défendable

- **Le contrat est dans la doc, pas dans la marque.** Le client tape sur la
  même API qu'il fasse de la lecture relationnelle ou un upsert dans Qdrant.
  Le couplage est dans `adapter-registry`, pas dans le code applicatif.
- **La sécurité est centralisée au-dessus des engines** : ABAC au gateway,
  pas dans Redis ACL + Mongo roles + PG RLS séparément. C'est testable,
  auditable, et il n'y a qu'un seul endroit à durcir.
- **Les écritures cross-engine sont eventually consistent** via outbox +
  saga, ce qui est le seul modèle physiquement réaliste.
- **Lectures fédérées analytiques** = Trino, qui est conçu pour ça.
- **Lectures fédérées transactionnelles** = FDW PostgreSQL (M6) qui réutilise
  la chaîne PostgREST + RLS + JWT déjà testée.

### Les limites physiques qu'on doit assumer

- **Pas d'ACID cross-engine natif.** C'est un théorème, pas un manque
  d'effort. La saga est la réponse industrielle (Stripe, Uber, AWS Step
  Functions font ça depuis 10 ans).
- **Performance ≠ driver natif.** Passer par un adapter ajoute 1-10 ms.
  Pour du high-throughput direct, le client doit utiliser le driver natif
  — le BaaS est pour la productivité et l'uniformité, pas pour la perf max.
- **`capabilities()` doivent être honnêtes.** Un `JOIN` sur Redis ou un
  `WHERE LIKE` sur DynamoDB n'a pas le même coût qu'en SQL. Exposer les
  caps permet au client (et au codegen M10) de refuser le mauvais usage à
  la compile.
- **Schémas non-uniformes.** Le SDK ne peut pas magiquement transformer
  un document Mongo profondément imbriqué en table relationnelle plate.
  La normalisation est la responsabilité de l'auteur de la `resource`,
  documentée dans son `schema_registry` row.

---

## 5. Fichiers que l'agent doit créer (par jalon)

| Jalon | Fichiers à créer ou modifier |
|---|---|
| M6 | `docker/services/postgres/Dockerfile` (multi-stage FDW build) ; `scripts/migrations/postgresql/020_fdw_servers.sql` ; `scripts/verify/m6-fdw.sh` ; Makefile target `baas-verify-m6` |
| M7 | `src/apps/query-router/src/engines/{jdbc,cassandra,neo4j,elasticsearch,qdrant,influx}.engine.ts` (6 fichiers) ; `src/apps/query-router/src/query/query.module.ts` (providers) ; `src/apps/query-router/src/query/query.service.ts` (Map registration) ; `src/package.json` (drivers) ; `scripts/migrations/postgresql/021_extend_engine_check.sql` ; `scripts/verify/m7-adapters.sh` |
| M8 | `docker-compose.yml` (debezium service) ; `src/apps/outbox-relay/` (extend with SagaCoordinator) ; `scripts/migrations/postgresql/022_outbox_saga_fields.sql` ; `scripts/verify/m8-saga.sh` |
| M9 | `src/apps/permission-engine/src/decisions/decisions.controller.ts` ; integration in every adapter's execute() ; `scripts/verify/m9-abac.sh` |
| M10 | `apps/baas/sdk/scripts/codegen.mjs` (extend) ; `apps/baas/sdk/src/typed-resource-builder.ts` ; `apps/baas/sdk/README.md` ; `scripts/verify/m10-sdk.sh` |

---

## 6. Ce que ce prompt ne couvre PAS (volontairement)

- **Production hosting** (k8s, terraform, blue/green). Le BaaS reste
  docker-compose-first ; le port vers k8s est un jalon séparé (M11+).
- **Multi-région / multi-tenant cluster.** Suppose un déploiement
  single-region pour l'instant. M3's outbox est la fondation pour M11.
- **Backup / restore automatisé multi-engine.** Aujourd'hui chaque engine
  a son backup script (`tools/backup.sh`) ; un orchestrateur unique reste
  à écrire (M12).
- **Tarification / billing.** Hors scope BaaS technique.

---

## 7. Comment l'utilisateur valide chaque jalon

```bash
# Pour chaque jalon livré :
make baas-verify-mX                 # static (rapide)
BAAS_VERIFY_LIVE=1 make baas-verify-mX  # live (stack up requis)
make baas-security-scan             # le scanner suite doit rester verte

# Pour valider l'ensemble :
make baas-verify-all                # M1..M10 chainés
```

Si un des gates plante, le script affiche `[Mx] FAIL: <raison>` avec la
ligne exacte. L'agent corrige, re-lance, et ne marque le jalon livré que
quand le gate exit 0.

---

## 8. Référence aux autres docs

- [`agnostic_back.md`](./agnostic_back.md) — la vision conceptuelle
  d'origine (FDW + adapters + Trino + outbox + DX uniforme).
- [`milestones.md`](./milestones.md) — l'état des jalons M1-M5.
- [`security.md`](./security.md) — la stack sécurité et comment la lancer.
- [`verify-and-test.md`](./verify-and-test.md) — comment exécuter les gates.
- [`CHANGELOG.md`](./CHANGELOG.md) — historique chronologique des changements.

Quand un nouvel agent reprend le travail, il doit :
1. Lire `CHANGELOG.md` (l'état actuel),
2. Lire ce prompt (la mission),
3. Pick un jalon parmi M6-M10,
4. Suivre le workflow décrit en section 2.
