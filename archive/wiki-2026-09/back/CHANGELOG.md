# Backend CHANGELOG — mini-baas-infra

Tous les changements significatifs apportés au backend, en ordre chronologique.
Le format est inspiré de [Keep a Changelog](https://keepachangelog.com/),
mais regroupé par **jalon** (M1 → M9) plutôt que par date — chaque jalon
représente un lot cohérent de livrables avec son propre gate de vérification.

---

## [M6-M9 — BaaS agnostique, sagas et ABAC] — 2026-05-31

Cible : passer du mini-BaaS multi-engine à un socle BaaS plus agnostique,
avec FDW optionnel, adapters étendus, outbox généralisée et décision ABAC
centralisée avant toute exécution adapter.

### Added — M6 FDW gateway

- **Image Postgres FDW manifestée** : versions/checksums déclarés pour les
  extensions FDW ciblées dans [`docker/services/postgres/Dockerfile`](../../apps/baas/mini-baas-infra/docker/services/postgres/Dockerfile).
- **Migration `020_fdw_servers.sql`** avec table tenant-scoped
  `fdw_external_resources` et helpers `ensure_fdw_extension`,
  `materialize_fdw_server`, `register_fdw_foreign_table`.
- **Adapter-registry `register_via_fdw`** : enregistrement optionnel d'un
  alias FDW au moment de la registration d'une base externe.
- **Gate `make baas-verify-m6`** ([`m6-fdw.sh`](../../apps/baas/mini-baas-infra/scripts/verify/m6-fdw.sh)).

### Added — M7 adapters étendus

- **Nouveaux `IDatabaseAdapter`** : JDBC sidecar, Cassandra, Neo4j,
  Elasticsearch, Qdrant, Influx.
- **`remote-engine-utils.ts`** factorise parsing connection JSON, validation
  resource, HTTP JSON, owner isolation et conversion `QueryResult`.
- **Migration `021_extend_engine_check.sql`** pour autoriser les nouveaux
  identifiants dans `tenant_databases.engine`.
- **Query-router registry via `ModuleRef`** : les engines sont enregistrés
  depuis une liste de providers, sans constructeur hypertrophié.
- **Gate `make baas-verify-m7`** ([`m7-adapters.sh`](../../apps/baas/mini-baas-infra/scripts/verify/m7-adapters.sh)).

### Added — M8 outbox/saga générique

- **Debezium Server** configuré pour lire `public.outbox_events` et publier
  vers Redis Streams.
- **Postgres logical WAL** activé via `wal_level=logical` dans Compose.
- **Migration `022_outbox_saga_fields.sql`** : `target_engine`,
  `target_resource`, `op`, `compensation_payload`, `idempotency_key`,
  `saga_state`, `next_attempt_at`.
- **`SagaCoordinatorService`** : dispatch Mongo direct ou streams
  `saga.<engine>.<resource>`, plus insertion d'événements de compensation.
- **Outbox relay backward-compatible** : détecte si les colonnes M8 existent
  avant de les sélectionner/mettre à jour.
- **Gate `make baas-verify-m8`** ([`m8-saga.sh`](../../apps/baas/mini-baas-infra/scripts/verify/m8-saga.sh)).

### Added — M9 ABAC centralisé

- **Permission-engine endpoint `POST /permissions/decide`**, protégé par
  `ServiceTokenGuard`, branché sur `public.has_permission()`.
- **Query-router fail-closed** : appelle le permission-engine avant
  `adapter.execute()`, renvoie `403` sur deny et `503` si la décision est
  indisponible.
- **Field masks** : policies peuvent renvoyer `conditions.mask` ou
  `conditions.field_mask` avec `hide` / `redact`, appliqués aux résultats.
- **Gate `make baas-verify-m9`** ([`m9-abac.sh`](../../apps/baas/mini-baas-infra/scripts/verify/m9-abac.sh)).

### Verified

- `make baas-verify-all` passe du M1 au M9.
- `npm --prefix apps/baas/mini-baas-infra/src run build:all` compile tous les
  services NestJS.

### Fixed

- **Common library exports** : `@mini-baas/common` exporte maintenant les
  modules observability, tracing, security, idempotency et audit utilisés par
  les apps.
- **M6 live gate** : la migration FDW est passée à `psql` via stdin au lieu
  d'un chemin `/work/...` non garanti dans le conteneur Postgres.
- **SCA high vulnerabilities mini-BaaS** : upgrade NestJS 11, `@nestjs/axios`
  compatible Nest 11, `@nestjs/config` 4, `@nestjs/swagger` 11, `@nestjs/cli`
  11 et `nodemailer` 8. `npm audit --audit-level=high` repasse à 0 finding.
- **Dependency metadata** : `package.json` déclare explicitement Helmet,
  ioredis, mysql2 et OpenTelemetry, déjà présents dans le lockfile et utilisés
  par les modules M4/M5/M7.

---

## [Vague de durcissement post-M5] — 2026-05-31 (soir)

Cible : amener les scanners vers 0 finding bloquant.

### Fixed — 8 Semgrep ERRORs → 0

- **Kong Dockerfile** : ajout `USER kong` explicite avant `ENTRYPOINT`
  (dockerfile.security.missing-user-entrypoint).
- **realtime-agnostic sandbox Dockerfile** : création d'un user `app` (uid 1001),
  `chown` des binaires copiés, `USER app` avant `CMD`.
- **opposite-osiris node Dockerfile** : `USER node` ajouté (UID 1000 built-in).
- **adapter-registry/crypto.service.ts** : `createDecipheriv` AES-256-GCM
  appelé avec `{ authTagLength: AUTH_TAG_LENGTH }` explicite (16 bytes,
  128 bits). Idem pour `createCipheriv`. Validation explicite des longueurs
  `iv`, `salt`, `tag` au decrypt pour empêcher des payloads forgés.
- **phase15-mongo-mvp-test.py** : `subprocess.run(cmd_list, ...)` était déjà
  safe (pas de `shell=True`) mais Semgrep ne peut pas le prouver
  statiquement → ajout d'un commentaire `# nosemgrep` documenté avec la
  raison.
- **wiki/.venv-translate/...pip/configuration.py** : ajout d'un
  [`.semgrepignore`](../../.semgrepignore) racine qui exclut tous les
  `.venv*`, `vendor/`, `node_modules/`, `dist/`, etc. — réduction du scope
  scan de 2487 → 1157 fichiers.

### Fixed — npm/pnpm audit vulns

- **`apps/opposite-osiris/package.json`** : bump `sanitize-html` ^2.17.3 →
  ^2.17.4 (CVE GHSA-rpr9-rxv7-x643, XSS via xmp passthrough, **critical**).
  Overrides ajoutées pour `devalue` ^5.8.1 (DoS) et `yaml` ^2.8.3 (stack overflow).
- **`apps/osionos/app/package.json`** : bump `mermaid` ^11.14.0 → ^11.15.0
  (4 CVEs HTML/CSS injection + DOM XSS). `pnpm.overrides` ajouté pour
  `qs` < 6.15.2 (DoS transitif via `@modelcontextprotocol/sdk` → `express`).

Note : `npm install` (ou `pnpm install`) doit être exécuté pour régénérer
les lockfiles et appliquer ces bumps. Les workspaces avec node_modules
owned par root après un docker run précédent doivent d'abord
`sudo chown -R $USER:$USER node_modules` ou lancer l'install dans Docker
avec `--user $(id -u):$(id -g)`.

### Added — ZAP DAST live + Kong header hardening

- **DAST initial** : 0 High-risk, 1 Medium (Permissions-Policy missing),
  4 Low (Server version leak, HSTS multiple entries, CSP unsafe-inline,
  banner info leak).
- **Kong response-transformer** durci :
  - **Ajouté** : `Permissions-Policy` (liste exhaustive avec defaults
    least-privilege), `Cross-Origin-Opener-Policy: same-origin`,
    `Cross-Origin-Resource-Policy: same-site`, HSTS bumped à 2 ans + preload.
  - **Retiré** : headers `Server`, `X-Powered-By`, `Via` (anti information
    leak).

### Dette identifiée — pas dans cette vague

- **WAF nginx** : ajoute toujours `Server: nginx/1.28.2` et son propre HSTS
  (1 an, vs Kong 2 ans). Kong ne peut pas supprimer un header que WAF a
  déjà ajouté. À fixer dans `docker/services/waf/conf/nginx.conf` avec
  `server_tokens off` + `more_clear_headers Server X-Powered-By;` (nécessite
  le module `headers-more` qui est compilé dans nginx-extras / OWASP CRS).
- **40 Semgrep WARNING** : surtout `generic.nginx.security.*`
  (dynamic-proxy-host, missing-ssl-version, request-host-used) sur les
  configs nginx WAF + `wildcard-postmessage-configuration` sur des bridges.
  Ces warnings sont configurables mais demandent un audit ligne par ligne
  des fichiers nginx — pas fait dans cette vague.

---

## [M5 — Sécurité durcie] — 2026-05-31

Cible : dimension **e** (sécurité & observabilité).

### Added

- **WAF en frontline** (nginx + ModSecurity v3 + OWASP CRS 4)
  - Dockerfile [`docker/services/waf/Dockerfile`](../../apps/baas/mini-baas-infra/docker/services/waf/Dockerfile)
    basé sur `owasp/modsecurity-crs:4-nginx-202604040104`.
  - Setup CRS dans [`docker/services/waf/conf/setup.conf`](../../apps/baas/mini-baas-infra/docker/services/waf/conf/setup.conf)
    avec `tx.crs_setup_version` (sinon CRS refuse de tourner — "fails closed").
  - HEALTHCHECK + cert TLS local avec `gid 101` (nginx) qui peut lire la clé
    privée sans tourner root.
- **Kong rate-limiting** sur chaque route critique (`/auth/v1`: 300/min,
  `/rest/v1`: 180/min, realtime: 120/min) — voir [`kong.yml`](../../apps/baas/mini-baas-infra/docker/services/kong/conf/kong.yml).
- **Security headers** ajoutés par Kong via le plugin `response-transformer` :
  `Strict-Transport-Security`, `X-Content-Type-Options`, `X-Frame-Options`,
  `Referrer-Policy`.
- **Vault** wired pour fournir `JWT_SECRET` et secrets long-lived (OAuth,
  SMTP) à GoTrue et aux services applicatifs ; pas de secret en clair dans
  Compose ou dans `.env` committés.
- **Stack scanner sécurité complète** (100 % Docker, zéro install host) —
  voir [`security.md`](./security.md) :
  - **SAST** : Semgrep avec rule packs OWASP Top 10 + TypeScript + Dockerfile + Node.js.
  - **SCA** : npm / pnpm audit sur tous les workspaces.
  - **Container** : Trivy filesystem + image scans (HIGH/CRITICAL bloquants).
  - **Secret** : TruffleHog sur l'historique git complet (`--only-verified`).
  - **DAST** : OWASP ZAP baseline contre le WAF live.
- **CI GitHub Actions** [`.github/workflows/mini-baas-security.yml`](../../.github/workflows/mini-baas-security.yml)
  qui orchestre les 7 stages : Semgrep, npm/pnpm audit (matrix par workspace),
  Snyk (gated sur token), Trivy fs+image, TruffleHog, ZAP (push main only),
  Security gate (agrégateur).
- **Gate `make baas-verify-m5`** ([`scripts/verify/m5-security.sh`](../../apps/baas/mini-baas-infra/scripts/verify/m5-security.sh))
  qui valide statiquement + (avec `--live`) :
  - WAF /waf-health 2xx
  - CRS bloque un SQLi probe avec 403
  - Rate-limit Kong renvoie 429 après burst de 320 requêtes
  - Headers de sécurité présents dans la réponse
  - Vault unsealed
- **Targets Makefile** : `baas-security-scan`, `baas-zap`, `baas-verify-m5`.

### Fixed

- **WAF tournait en root** → maintenant `USER nginx` (gid 101). La clé TLS
  est `chown root:101 chmod 640` pour que nginx puisse la lire sans
  privilèges.
- **CRS chargé mais inerte** : le fichier `setup.conf` n'incluait pas les
  rules CRS — corrigé en ajoutant les includes setup + crs-setup.
- **CRS "fail-closed"** : sans `SecAction "id:900990,phase:1,pass,nolog,setvar:tx.crs_setup_version=400"`,
  CRS refuse de démarrer → cette ligne a été ajoutée dans `crs-setup.conf`.

### Documented

- [`wiki/back/security.md`](./security.md) — référence complète de la stack
  sécurité avec exemples de commandes pour chaque scanner.

---

## [M4 — Observabilité] — 2026-05-31

Cible : dimensions **e** (observabilité) + **g** (auditabilité).

### Added

- **Stack observabilité** dans `docker-compose.yml` sous le profile
  `observability` : `prometheus`, `grafana`, `loki`, `promtail`.
- **Gate `make baas-verify-m4`** ([`scripts/verify/m4-observability.sh`](../../apps/baas/mini-baas-infra/scripts/verify/m4-observability.sh))
  qui valide statiquement + (avec `--live`) :
  - Prometheus `/-/ready` 200 + ≥ 1 target scrapé up
  - Grafana `/api/health.database == "ok"`
  - Loki `/ready` 200
- **Correlation IDs** : `CorrelationIdInterceptor` propage `X-Request-ID` sur
  toute la chaîne (Kong → services NestJS → audit_log). Permet de tracer une
  requête bout en bout.

### Dette connue (M4.b à livrer)

- `PrometheusModule.register()` n'est pas encore wired dans les
  `app.module.ts` — seuls les helpers (`makeHistogramProvider`,
  `InjectMetric`) sont importés. Tant que ce n'est pas fait, le endpoint
  `/metrics` n'est pas exposé. Le gate M4 a un check soft qui passe sur
  `@willsoto/nestjs-prometheus referenced` plutôt que sur
  `PrometheusModule.register()` (à durcir).
- Traces distribuées (OpenTelemetry + Tempo) : non livrées. C'est la
  prochaine étape M4.c.

---

## [M3 — Cohérence multi-engine] — 2026-05-31

Cible : dimensions **c** (cohérence cross-engine) + **g** (traçabilité).

### Added

- **Pattern outbox** : table `outbox_events` (migration 015) qui sert de
  "boîte aux lettres" transactionnelle dans PostgreSQL. Toute écriture qui
  doit se propager à un autre engine est insérée dans `outbox_events` dans
  la même transaction que la donnée métier.
- **Service `outbox-relay`** qui consomme `outbox_events`, publie dans
  Redis Streams, met à jour la projection Mongo (`orders_view` pour l'instant),
  et marque l'événement `published`.
- **Idempotency-Key middleware** : header `Idempotency-Key` accepté sur les
  mutations critiques → si la même clé revient, on retourne la réponse
  précédente plutôt que de doubler l'effet.
- **RLS unifiée** : passage de `current_setting('app.current_user_id')` (legacy)
  à `current_setting('request.jwt.claims', true)::jsonb->>'sub'` (compatible
  PostgREST/GoTrue).
- **Gate `make baas-verify-m3`** ([`scripts/verify/m3-coherence.sh`](../../apps/baas/mini-baas-infra/scripts/verify/m3-coherence.sh))
  qui rejoue un cycle complet PG INSERT → outbox → Redis Streams → Mongo
  projection + assert `status = 'published'`.

---

## [M2 — Vraie fédération multi-engine] — 2026-05-31

Cible : dimensions **b** (data federation) + **d** (API unifiée).

### Added

- **3 nouveaux engines** sous `query-router`, tous implements `IDatabaseAdapter`
  (le contrat défini en M1) :
  - [`MysqlEngine`](../../apps/baas/mini-baas-infra/src/apps/query-router/src/engines/mysql.engine.ts)
    : CRUD complet via `mysql2/promise`, upsert via `ON DUPLICATE KEY UPDATE`,
    txIntra supporté.
  - [`RedisEngine`](../../apps/baas/mini-baas-infra/src/apps/query-router/src/engines/redis.engine.ts)
    : KV/hash CRUD via `ioredis`, namespacing automatique `userId:resource:id`
    pour l'isolation tenant.
  - [`HttpEngine`](../../apps/baas/mini-baas-infra/src/apps/query-router/src/engines/http.engine.ts)
    : REST CRUD via `fetch` natif Node 20, accepte une `connection_string`
    JSON `{baseUrl, headers, routes}`.
- **Migration 014** ([`014_add_http_engine.sql`](../../apps/baas/mini-baas-infra/scripts/migrations/postgresql/014_add_http_engine.sql))
  étend le CHECK constraint `tenant_databases.engine` pour inclure `'http'`.
- **Endpoint `GET /engines`** ([`engines.controller.ts`](../../apps/baas/mini-baas-infra/src/apps/query-router/src/query/engines.controller.ts))
  pour introspection : retourne la liste des engines avec leurs capabilities.
- **DTO `idempotencyKey`** ajouté à `ExecuteQueryDto` (prépare M3).
- **Catalogs Trino** : [`mysql.properties`](../../apps/baas/mini-baas-infra/docker/services/trino/conf/catalog/mysql.properties)
  et [`iceberg.properties`](../../apps/baas/mini-baas-infra/docker/services/trino/conf/catalog/iceberg.properties)
  pour analytics cross-engine.
- **Compose extends** : `mysql:8.4`, `iceberg-rest:1.6.1`, `minio-iceberg-init`
  (bootstrap du bucket Iceberg sur MinIO).
- **SDK codegen pipeline** (100 % Docker) :
  - [`scripts/openapi-collect.sh`](../../apps/baas/mini-baas-infra/scripts/openapi-collect.sh)
    collecte les `/docs-json` des 13 services NestJS.
  - [`apps/baas/sdk/scripts/codegen.mjs`](../../apps/baas/sdk/scripts/codegen.mjs)
    génère des clients typés via `openapi-typescript-codegen`.
  - [`apps/baas/sdk/Dockerfile.codegen`](../../apps/baas/sdk/Dockerfile.codegen)
    + target `make baas-codegen` font tout le cycle sans node sur le host.
- **Gate `make baas-verify-m2`** ([`scripts/verify/m2-federation.sh`](../../apps/baas/mini-baas-infra/scripts/verify/m2-federation.sh)).

### Changed

- `query.service.ts` enregistre 5 engines via une `Map<string, IDatabaseAdapter>`
  (au lieu des 2 anciens). Plus aucun chemin `if (engine === 'postgresql')` —
  tout passe par la map.

### Important — sur Trino

Trino n'est **pas** un moteur OLTP universel. C'est un moteur **analytique
fédéré** : excellent pour les SELECTs cross-engine (joins PG ↔ Mongo ↔
Iceberg), mais write support varie connector par connector (limité pour
Mongo, read-only pour Redis/Elasticsearch). C'est pour ça que les CRUD
transactionnels passent par les `IDatabaseAdapter`, pas par Trino.

---

## [M1 — Hardening] — 2026-05-31

Cible : dimensions **a** (Docker-first), **f** (tooling), **g** (traçabilité light).

### Added

- **HEALTHCHECK** dans **17/17 Dockerfiles** (services externes +
  Dockerfile NestJS multi-app). Permet à `docker compose up --wait` de
  bloquer jusqu'à ce que chaque service réponde vraiment.
- **Contrat `IDatabaseAdapter`** dans [`src/libs/database/src/adapter.contract.ts`](../../apps/baas/mini-baas-infra/src/libs/database/src/adapter.contract.ts)
  avec `EngineCaps`, `QueryOpts`, `QueryResult`, `AdapterOp`. M2 a pu
  ajouter 3 nouveaux engines sans toucher au dispatcher.
- **DTO unifié `ExecuteQueryDto`** avec enum `op` (`list`/`get`/`insert`/
  `update`/`delete`/`upsert`) + back-compat `action` (deprecated).
- **OpenAPI sur les 13 services NestJS** : `SwaggerModule.setup('docs', app, doc)`
  + `.addBearerAuth()` sur chaque main.ts. Chaque service expose
  `/docs` (UI) et `/docs-json` (machine-readable, consommé par le SDK codegen).
- **Migration 013_audit_log** : table `audit_log` (request_id, actor_id,
  actor_role, action, resource, payload, ip, user_agent) + 3 index + RLS.
- **`AuditService` + `AuditInterceptor`** dans `libs/common/src/audit/`,
  wired dans 7 services qui mutent : `query-router`, `mongo-api`,
  `storage-router`, `permission-engine`, `gdpr-service`, `session-service`,
  `newsletter-service`. Toute requête POST/PATCH/PUT/DELETE écrit une ligne
  dans `audit_log` après succès.
- **Gate `make baas-verify-m1`** ([`scripts/verify/m1-hardening.sh`](../../apps/baas/mini-baas-infra/scripts/verify/m1-hardening.sh))
  qui chaîne ensuite tous les autres jalons.

### Changed

- `postgresql.engine.ts` et `mongodb.engine.ts` refactorés pour
  `implements IDatabaseAdapter` (au lieu de signatures divergentes).

---

## [Incident de récupération] — 2026-05-31

**43 fichiers critiques** (dont `docker-compose.yml`, `kong.yml`, tous les
Dockerfiles services, tous les `main.ts` NestJS, scripts d'init) ont été
vidés au cours d'une session — probablement par un crash IDE. Le contenu
était intact dans le dernier commit Git, restauration safe :

```bash
git diff --name-only apps/baas/mini-baas-infra/ \
  | xargs -I{} sh -c 'test -s "{}" || echo "{}"' \
  | xargs -r git restore --
```

Aucune perte de code. Les fichiers nouveaux (M5 verify, run-security-scans,
mini-baas-security.yml, zap-baseline) n'étaient pas affectés car non encore
committés.

---

## [Front-end — react-doctor on osionos] — 2026-05-31

### Added

- `apps/osionos/app/pnpm-workspace.yaml` avec `minimumReleaseAge: 10080`
  (7 jours) — protection supply-chain contre les packages npm fraîchement
  publiés qui peuvent contenir du malware avant d'être unpublished.
- `<MotionConfig reducedMotion="user">` dans [`main.tsx`](../../apps/osionos/app/src/app/main.tsx)
  pour respecter `prefers-reduced-motion` (WCAG 2.3.3).

### Fixed (3 errors react-doctor)

- [`LayoutBlockEditor.tsx`](../../apps/osionos/app/src/features/block-editor/ui/canvas/LayoutBlockEditor.tsx) :
  IntersectionObserver déplacé dans un ref-callback (au lieu d'un `useEffect`
  qui re-déclenchait sur `setShouldMount`).
- [`AgentConversationPage.tsx`](../../apps/osionos/app/src/widgets/agent-conversation/ui/AgentConversationPage.tsx) :
  reset du state au changement de `pageId` fait via pattern prev-prop
  comparison inline (au lieu d'un `useEffect` qui forçait un render
  intermédiaire avec UI stale).
- [`HomeKnowledgeGraph.tsx`](../../apps/osionos/app/src/widgets/home-variants/ui/HomeKnowledgeGraph.tsx) :
  cleanup explicit du tick handler d3-force (`simulation.on("tick", null)`
  en plus de `simulation.stop()`).

### Changed

- `.npmrc` (osionos + notion-database-sys) : `minimum-release-age` bumpé
  de `1440` (24h) à `10080` (7 jours).
