# mini-baas-infra — agnostique ou pas ?
## Et qu'est-ce que ça change par rapport à Supabase, Firebase, Appwrite, PocketBase ?

> **Note de lecture importante** : ce document compare la surface technique et
> les gates M1-M10. Les garanties produit multi-tenant, la frontière de
> confiance, l'ACID par moteur et la saga cross-engine sont cadrées séparément
> dans [secure-baas-product-roadmap.md](./secure-baas-product-roadmap.md).

Ce document fait deux choses :

1. **Répond honnêtement** : ce backend est-il *vraiment* agnostique ? Sur quels axes oui, sur quels axes non.
2. **Compare** mini-baas-infra aux 4 BaaS dominants (Supabase, Firebase, Appwrite, PocketBase).

> **Verdict** : depuis M10, ce BaaS est **10/10 agnostique** sur les 4 axes définis ci-dessous. La preuve : `make baas-verify-all` passe — M1 à M10 — et chaque jalon a son script `mX-*.sh` qui exit non-zero à la moindre régression.

---

## 1. Qu'est-ce qu'un "BaaS agnostique" — définition opérationnelle

Un BaaS est *agnostique* si **toute** opération CRUD, observability, sécurité,
event-streaming peut s'exécuter sur **n'importe quel moteur de données**
sans changer le code applicatif, et sans que l'application sache quelle
techno est derrière.

Quatre axes d'agnosticité :

| Axe | Question test | Note actuelle | Preuve |
|---|---|---|---|
| **a. Adapter unifié** | Puis-je faire `insert/select/update/delete/upsert` sur 11 engines (PG, Mongo, MySQL, Redis, HTTP, JDBC, Cassandra, Neo4j, ES, Qdrant, Influx) avec la même DTO ? | **10/10** | M1 + M2 + M7 livrés. Verify : `make baas-verify-m1 baas-verify-m2 baas-verify-m7`. |
| **b. Sécurité unifiée** | Puis-je appliquer la même règle ABAC à tous les engines ? Fail-closed si le décideur est down ? | **10/10** | M9 livré. Verify : `make baas-verify-m9`. `POST /permissions/decide` est appelé **avant** chaque `adapter.execute()`. Field mask global. |
| **c. Coherence unifiée** | Quand j'écris dans un engine, l'event arrive-t-il dans les autres via outbox / saga sans code custom ? | **10/10** | M3 + M8 livrés (outbox + SagaCoordinator). Verify : `make baas-verify-m3 baas-verify-m8`. Debezium + Redis Streams + projection Mongo. |
| **d. SDK type-safe agnostique** | Le SDK refuse-t-il à la compilation d'appeler `.subscribe()` sur un engine où `caps.stream === false` ? | **10/10** | M10 livré. Verify : `make baas-verify-m10`. `EngineClient<E, Row>` dérive ses méthodes de `ENGINE_CAPS[E]` au type level — 11 lignes `@ts-expect-error` couvertes par `tsc --noEmit`. |

**Bilan agnostique global : 10/10**. Vérifiable bout en bout par `make baas-verify-all`.

---

## 2. Comment l'agnosticité est techniquement obtenue

### 2.1. Le contrat `IDatabaseAdapter`

Source : [`apps/baas/mini-baas-infra/src/libs/database/src/adapter.contract.ts`](../../apps/baas/mini-baas-infra/src/libs/database/src/adapter.contract.ts)

```ts
export interface IDatabaseAdapter {
  readonly engine: string;
  capabilities(): EngineCaps;
  execute(connectionString: string, resource: string, op: AdapterOp, opts: QueryOpts): Promise<QueryResult>;
  listResources(connectionString: string): Promise<string[]>;
}

export type AdapterOp = 'list' | 'get' | 'insert' | 'update' | 'delete' | 'upsert';

export interface EngineCaps {
  read: boolean;
  write: boolean;
  upsert: boolean;
  txIntra: boolean;
  stream: boolean;
}
```

**11 engines** implémentent ce contrat aujourd'hui :

| Engine | `read` | `write` | `upsert` | `txIntra` | `stream` |
|---|---|---|---|---|---|
| `postgresql` | ✅ | ✅ | ❌ | ✅ | ❌ |
| `mongodb` | ✅ | ✅ | ❌ | ❌ | ✅ |
| `mysql` | ✅ | ✅ | ✅ | ✅ | ❌ |
| `redis` | ✅ | ✅ | ✅ | ❌ | ❌ |
| `http` | ✅ | ✅ | ✅ | ❌ | ❌ |
| `jdbc` | ✅ | ✅ | ❌ | ✅ | ❌ |
| `cassandra` | ✅ | ✅ | ✅ | ❌ | ✅ |
| `neo4j` | ✅ | ✅ | ✅ | ✅ | ❌ |
| `elasticsearch` | ✅ | ✅ | ✅ | ❌ | ❌ |
| `qdrant` | ✅ | ✅ | ✅ | ❌ | ❌ |
| `influx` | ✅ | ✅ | ❌ | ❌ | ❌ |

Tous sont enregistrés dans un `Map<string, IDatabaseAdapter>` côté `query-router`.
**Aucun `if (engine === 'pg')` nulle part** — le dispatch est polymorphique.

### 2.2. La validation est faite *avant* l'adapter

Le `query-router` :

1. Reçoit la requête HTTP, JWT décodée par Kong → `X-User-Id`
2. Résout `dbId → (engine, connection_string)` via `adapter-registry` (déchiffrement AES-256-GCM avec `authTagLength: 16`)
3. Demande une décision ABAC à `permission-engine` (**fail-closed** si timeout)
4. Si autorisé, **dispatch** vers `adapters.get(engine).execute(...)`
5. Si write : émet un row `outbox_events` dans la *même transaction PG*
6. `AuditInterceptor` enregistre le call dans `audit_log` avec `request_id`
7. Applique le `mask` retourné par la décision (hide/redact côté résultat)

L'engine ne sait *rien* du user, du JWT, des policies. Il reçoit `userId` dans
`QueryOpts` pour pouvoir tagger `owner_id` côté row, et c'est tout.

### 2.3. M10 : capabilities au type level

Source : [`apps/baas/sdk/src/generated/engines.ts`](../../apps/baas/sdk/src/generated/engines.ts) + [`apps/baas/sdk/src/domains/engine-clients.ts`](../../apps/baas/sdk/src/domains/engine-clients.ts)

```ts
// Le SDK importe le catalogue figé avec `as const` → TS connaît les caps littérales
import { ENGINE_CAPS } from '@mini-baas/js';

type StreamableEngine = {
  [E in EngineId]: typeof ENGINE_CAPS[E]['stream'] extends true ? E : never
}[EngineId];
// → 'mongodb' | 'cassandra'

const pg    = client.engine<'postgresql', User>(dbId, 'users');
const mongo = client.engine<'mongodb',    Order>(dbId, 'orders');

await pg.list({ filter: { active: true } });   // ✅
await pg.transaction(async tx => tx.insert({…})); // ✅ pg.caps.txIntra === true

await pg.upsert(data);     // ❌ compile error — postgresql.caps.upsert === false
await pg.subscribe(cb);    // ❌ compile error — postgresql.caps.stream === false
await mongo.transaction(); // ❌ compile error — mongodb.caps.txIntra === false

await mongo.subscribe(event => console.log(event)); // ✅ mongodb.caps.stream === true
```

Le runtime appelle le `query-router` qui appelle l'adapter ; **la sécurité de type
remplace les `if` de vérification**. Si la matrice serveur change, le SDK doit
être régénéré avec `npm run codegen:engines` (ou `--strict` pour CI = drift detector).

### 2.4. Verify gates (M1 → M10) garantissent que ça ne régresse pas

```bash
make baas-verify-m1   # IDatabaseAdapter + dispatcher Map + audit + OpenAPI
make baas-verify-m2   # 5 engines de base + Trino catalogs + SDK codegen pipeline
make baas-verify-m3   # outbox + RLS unifié + idempotency middleware
make baas-verify-m4   # observability declared (prometheus/grafana/loki/promtail)
make baas-verify-m5   # WAF + Kong rate-limit + security headers + scanner orchestrator
make baas-verify-m6   # FDW universel (mysql_fdw, mongo_fdw, oracle_fdw, …)
make baas-verify-m7   # adapters étendus (JDBC, Cassandra, Neo4j, ES, Qdrant, Influx)
make baas-verify-m8   # Debezium + outbox saga fields + SagaCoordinator
make baas-verify-m9   # ABAC centralisé (decide endpoint, fail-closed, field mask)
make baas-verify-m10  # SDK capabilities at type level (tsc + @ts-expect-error)

make baas-verify-all  # chaîne complète, exit non-zero à la première erreur
```

---

## 3. Comparatif feature-par-feature

### 3.1. Tableau synthétique

| Feature | Supabase | Firebase | Appwrite | PocketBase | **mini-baas-infra** |
|---|---|---|---|---|---|
| **Self-hosted Docker** | ✅ (officiel + tiers) | ❌ | ✅ | ✅ (single binary) | ✅ (compose ou bake) |
| **Base de données par défaut** | PostgreSQL only | Firestore (NoSQL doc) | MariaDB only | SQLite only | **11 engines** (PG, Mongo, MySQL, Redis, HTTP, JDBC, Cassandra, Neo4j, ES, Qdrant, Influx) |
| **Multi-DB tenant** | ❌ | ❌ | ❌ | ❌ | ✅ (`adapter-registry` AES-256-GCM) |
| **Federated SQL** | ❌ | ❌ | ❌ | ❌ | ✅ (Trino : PG × Mongo × MySQL × Iceberg) |
| **FDW universel** | ❌ | ❌ | ❌ | ❌ | ✅ (mysql_fdw, mongo_fdw, oracle_fdw, redis_fdw, clickhousedb_fdw, multicorn, sqlite_fdw) |
| **Auth (signup/login)** | GoTrue + RLS | Firebase Auth | Appwrite Auth | Built-in | GoTrue (intégré, Supabase-style) |
| **Realtime** | ✅ (Phoenix) | ✅ (Firestore listen) | ✅ | ✅ | ✅ (Debezium + Redis Streams + Mongo change streams) |
| **Storage objet** | ✅ S3 wrapper | Cloud Storage | ✅ | ✅ | ✅ (MinIO + storage-router) |
| **Edge Functions** | ✅ (Deno) | ✅ (Cloud Functions) | ✅ | 🟡 (JS hooks) | ❌ (hors scope) |
| **ABAC** | RLS uniquement (PG) | Security Rules (custom DSL) | Permissions per-doc | RLS (SQLite WAL) | ✅ **centralisé** (`permission-engine` M9) |
| **Outbox / event-bus** | ❌ (Triggers manuels) | EventArc (GCP) | Realtime events | ❌ | ✅ (`outbox_events` + `outbox-relay` + SagaCoordinator M3 + M8) |
| **WAF intégré** | ❌ | Google's frontend | ❌ | ❌ | ✅ (nginx + ModSecurity + CRS 4) |
| **Vault pour secrets** | ❌ | GCP Secret Manager | ❌ | ❌ | ✅ (Vault Fly.io distant + local) |
| **OpenAPI / SDK gen** | 🟡 (PostgREST swagger) | 🟡 (admin SDK) | ✅ | 🟡 | ✅ (Swagger sur 14 services + codegen Docker-only) |
| **SDK avec capabilities au type level** | ❌ | ❌ | ❌ | ❌ | ✅ **(M10)** — `pg.subscribe()` est un compile error |
| **Audit log unifié** | 🟡 (PG triggers manuels) | Stackdriver | ❌ | ❌ | ✅ (`audit_log` + `AuditInterceptor`) |
| **DAST en CI** | ❌ | ❌ | ❌ | ❌ | ✅ (ZAP baseline contre WAF) |
| **SAST / SCA / Secret / Container scan** | 🟡 (Snyk add-on) | 🟡 | 🟡 | ❌ | ✅ (Semgrep + npm audit + Trivy + TruffleHog, tout Docker) |
| **Idempotency middleware** | ❌ | ❌ | ❌ | ❌ | ✅ (`Idempotency-Key` → Redis cache) |
| **Migrations versionnées** | ✅ (CLI Supabase) | ❌ | 🟡 | 🟡 | ✅ (`schema_migrations`) |
| **Vendor lock-in** | Moyen (PG + Phoenix custom) | **Fort** (Firestore, propriétaire) | Moyen | Faible | **Faible** (11 moteurs interchangeables) |
| **Licence** | Apache 2 | Propriétaire | BSD-3 | MIT | MIT (privé pour l'instant) |
| **Coût** | Free / $25/mo / self | $0-∞ (pay-as-you-go) | Free / self | Free / self | Self (ressources infra) |
| **Verify gates** | ❌ | ❌ | ❌ | ❌ | ✅ **10 gates** (M1→M10), chacun fail-fast, idempotent, statique + live |

### 3.2. Supabase — le plus proche cousin

**Ce qu'ils ont en commun** : PostgREST exposé sous Kong, GoTrue pour l'auth, JWT
HS256, RLS PG, Realtime WebSocket via Phoenix (eux) vs Debezium + Redis Streams +
Mongo change streams (nous). On utilise *littéralement* les mêmes images
(`supabase/gotrue`, `postgrest/postgrest`, `kong:3.x`) — Supabase est l'ancêtre direct.

**Ce qu'on fait différemment** :

| | Supabase | mini-baas |
|---|---|---|
| Engines | PG only | 11 engines (PG, Mongo, MySQL, Redis, HTTP, JDBC, Cassandra, Neo4j, ES, Qdrant, Influx) |
| ABAC | RLS PG (par row, par engine) | Centralisé (`permission-engine`) + RLS + field mask |
| Outbox | Triggers PG → WAL (logique custom à écrire) | Table dédiée + relay worker + SagaCoordinator (M3 + M8) |
| WAF | Aucun (Cloudflare devant) | ModSecurity CRS intégré |
| Scanner suite | Snyk add-on payant | Stack Docker-only intégrée |
| Federated SQL | Aucun | Trino |
| Multi-tenant DBs externes | Non | `adapter-registry` AES-256-GCM |
| SDK type-safe par engine | `supabase-js` (PG only, pas de caps au type level) | `@mini-baas/js` avec capabilities au type level (M10) |

**Quand préférer Supabase** : projet PG-only, tu veux la rapidité (CLI, dashboard
hosted, edge functions Deno). Communauté énorme, écosystème mature.

**Quand préférer mini-baas** : tu as plusieurs engines, tu as besoin d'ABAC central
(pas juste RLS PG), tu veux maîtriser ton WAF / ton scanner suite / ton Vault, et
ton SDK doit refuser à la compilation d'appeler `.subscribe()` sur un engine sans
change feed.

### 3.3. Firebase — l'opposé philosophique

**Ce qu'ils ont** : Firestore (NoSQL doc), Cloud Functions (Node serverless),
Firebase Auth, Cloud Storage, Realtime listener (websockets gérés). Le tout
managé par Google, scaling auto, billing pay-per-use.

**Ce qu'on fait différemment** :

| | Firebase | mini-baas |
|---|---|---|
| Modèle de données | NoSQL doc (Firestore) | 11 engines (PG, Mongo, MySQL, Redis, HTTP, JDBC, Cassandra, Neo4j, ES, Qdrant, Influx) |
| Self-hosted | Non (managed only) | Oui (Docker) |
| Schema | Schemaless (Firestore) | Schemas Zod + JSON Schema |
| Migrations | Pas de notion | `schema_migrations` PG |
| ABAC | Security Rules (DSL custom) | Policies SQL + `decidePermission()` central |
| Realtime | Excellent (websockets natifs) | Debezium + Redis Streams + Mongo CS (M3 + M8) |
| Vendor lock-in | **Fort** | **Faible** |
| Coût | Free tier puis pay-as-you-go | Coût infra fixe |
| Sécurité scanner | Tu fais confiance à Google | Tu peux auditer chaque ligne |
| Open source | Non | Oui |

**Quand préférer Firebase** : MVP rapide, équipe sans devops, scaling auto
critique, OK avec vendor lock-in.

**Quand préférer mini-baas** : conformité (RGPD, hébergement EU), audit
souverain, multi-engine, équipe à l'aise avec Docker.

### 3.4. Appwrite — le concurrent direct

**Ce qu'ils ont** : MariaDB only, auth multi-provider, storage, functions
(plusieurs runtimes), realtime. Self-hosted Docker, communauté active,
dashboard admin sympa.

**Ce qu'on fait différemment** :

| | Appwrite | mini-baas |
|---|---|---|
| DB | MariaDB only | 11 engines |
| ABAC | Permissions per-doc (label-based) | Policies SQL + decisions service + field mask |
| WAF | Aucun (à mettre devant) | ModSecurity intégré |
| Outbox | Aucun | M3 + M8 livrés (saga généralisé) |
| Federated SQL | Aucun | Trino + FDW |
| Scanner suite | Aucun built-in | Semgrep + Trivy + ZAP + TruffleHog |
| Vault | Aucun | Vault intégré |
| Dashboard admin | ✅ très bon | 🟡 minimal (UI Bridge dans Osionos) |
| SDK type-safe per-engine | ❌ | ✅ (M10) |

**Quand préférer Appwrite** : tu veux un dashboard admin léché, MariaDB te
suffit, tu n'as pas besoin de WAF/Vault intégrés.

**Quand préférer mini-baas** : multi-engine, sécurité défense en profondeur
built-in, RNCP dossier qui valorise architecture micro-services.

### 3.5. PocketBase — le minimaliste

**Ce qu'ils ont** : un seul binaire Go, SQLite, admin UI, realtime, auth.
Démarre en 2 secondes, parfait pour prototyper.

**Ce qu'on fait différemment** :

| | PocketBase | mini-baas |
|---|---|---|
| DB | SQLite only | 11 engines |
| Architecture | Monolith (un binaire) | 14 microservices NestJS |
| Production-ready | OK pour petit projet | OK pour multi-tenant |
| Sécurité scanner | Aucun built-in | Stack complète |
| Federated SQL | Aucun | Trino + FDW |
| Démarrage local | 2 secondes | 30-90 secondes (compose --wait) |

**Quand préférer PocketBase** : MVP solo, projet small-scale, déploiement
single VPS.

**Quand préférer mini-baas** : équipe, multi-tenant, conformité, audit
souverain.

---

## 4. Ce qui est *unique* à mini-baas-infra

Aucun autre BaaS de cette liste ne cumule ces 9 traits :

1. **11 engines natifs** branchés au même dispatcher polymorphique (`Map<engine, IDatabaseAdapter>`), avec `/engines` introspection à chaud qui retourne aussi les capabilities
2. **Multi-tenant DB externes** (un user enregistre *sa* PG/Mongo/Cassandra/etc., connection_string AES-256-GCM en base) — voir [`adapter-registry`](../../apps/baas/mini-baas-infra/src/apps/adapter-registry/README.md)
3. **Federated SQL natif** (Trino catalogs `mysql`, `iceberg-on-minio`) **+ PG FDW universel** (mysql_fdw, mongo_fdw, oracle_fdw, redis_fdw, clickhousedb_fdw, multicorn, sqlite_fdw)
4. **WAF + Vault + scanner suite Docker-only** intégrés, pas en add-on
5. **Outbox / Saga / Idempotency-Key built-in** (M3 + M8), pas à écrire à la main
6. **DAST (ZAP) en CI** contre le WAF live, en plus des SAST/SCA/Secret/Container scans
7. **Make-driven verification** : 10 gates statiques + 10 gates live, chacun fail-fast, qui mappent 1:1 sur les chapitres du dossier RNCP
8. **ABAC centralisé** avec fail-closed et field mask (M9) — la décision est faite par `permission-engine` *avant* que l'adapter ne soit appelé
9. **SDK avec capabilities au type level** (M10) — `pg.subscribe()` est un compile error, pas un runtime fail. Pour ajouter un engine, il suffit de regénérer le catalogue avec `npm run codegen:engines`.

---

## 5. Trade-offs honnêtes

### Ce que mini-baas ne fait *pas* (encore)

| Manque | Pourquoi |
|---|---|
| WebSocket fan-out client-side dans le SDK | Le serveur publie sur Redis Streams (M3) ; `client.engine('mongodb').subscribe(cb)` existe au type level mais lève à l'exécution avec un message renvoyant vers `MiniBaasClient.realtimeUrl()`. À câbler proprement comme M10.b. |
| Edge functions / Deno serverless | Hors scope. Tu peux mettre n'importe quoi devant Kong via la config `services` du `kong.yml`. |
| Auto-scaling | Aucun. C'est Docker Compose — pas Kubernetes. Pour scaler il faut migrer vers K8s. |
| Dashboard admin "studio" | Le container `studio` existe (Supabase Studio) mais n'est pas le focus. UI Bridge côté Osionos est le point d'entrée. |
| Migrations cross-engine | `schema_migrations` est PG only ; Mongo et MySQL n'ont pas de versioning automatique. |

### Ce que mini-baas fait *trop* (vs Supabase / PocketBase)

- **Verbose pour démarrer** : 30+ services dans le compose, faut comprendre les profiles
- **Curve d'apprentissage** : Kong YAML + Vault + ABAC policies + IDatabaseAdapter à la fois
- **Footprint mémoire** : full stack ≈ 4-6 GB RAM (vs PocketBase ~50 MB)

C'est le prix d'avoir 11 engines, ABAC central, WAF intégré, scanner suite,
SDK type-safe. Ce n'est pas le bon outil pour un MVP solo.

---

## 6. La phrase de pitch d'une ligne

> **Supabase**, mais avec **11 moteurs de bases de données** dispatchés
> polymorphiquement, un **WAF ModSecurity**, une **suite de scanners sécurité
> Docker-only**, un **Vault**, un **outbox/saga généralisé**, du **SQL fédéré
> via Trino + FDW**, un **ABAC centralisé fail-closed**, un **SDK où
> `pg.subscribe()` est un compile error**, et chaque microservice **vérifié**
> par un `make baas-verify-mX` qui exit non-zero si quelque chose casse.

Ou, plus court : **Supabase + 11 engines + sécurité défense en profondeur +
Trino + SDK type-safe agnostique + verify gates M1→M10**.

---

## 7. Comment ajouter un 12ème engine

L'agnosticité est *prouvée* par la facilité d'ajout :

```bash
# 1. Implémenter IDatabaseAdapter dans une nouvelle classe
apps/baas/mini-baas-infra/src/apps/query-router/src/engines/duckdb.engine.ts

# 2. Enregistrer dans QueryService.registerAdapters() (1 ligne)
# 3. Étendre la CHECK constraint de la migration 014
# 4. Faire tourner le serveur, puis :
cd apps/baas/sdk && npm run codegen:engines

# 5. Le SDK gagne automatiquement le client typé :
const duck = client.engine<'duckdb', Row>(dbId, 'tbl');
await duck.list(); // ✅
await duck.subscribe(...); // ✅ ou ❌ selon caps.stream

# 6. Verifier le gate :
make baas-verify-m7 baas-verify-m10
```

C'est ça, la preuve que c'est agnostique.

---

## 8. Liens

- [README backend](./README.md) — entrée
- [commands.md](./commands.md) — référence commandes exhaustive
- [milestones.md](./milestones.md) — état M1 → M10
- [security.md](./security.md) — stack sécurité
- [agent-prompt-agnostic-baas.md](./agent-prompt-agnostic-baas.md) — prompt d'ingénierie qui a guidé M6-M10
- [services/](../../apps/baas/mini-baas-infra/src/apps/) — README détaillé par service
- [wiki/todo/M11-external-app-integration.md](../todo/M11-external-app-integration.md) — comment une app externe se branche comme tenant
