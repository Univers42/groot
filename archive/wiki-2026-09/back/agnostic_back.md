Compacted conversation# Plan pragmatique pour lire/écrire dans n'importe quelle DB depuis mini-baas-infra

Aucun outil unique ne couvre "vraiment toutes" les bases. La bonne réponse est une **stack en couches** où chaque couche fait ce qu'elle sait faire le mieux, avec un **contrat commun** au-dessus. Vous avez déjà 80 % des briques — il faut juste les arranger.

## La couche qui change tout : PostgreSQL comme passerelle universelle (FDW)

PostgreSQL a un système de **Foreign Data Wrappers** qui transforme n'importe quelle source en *table virtuelle*. C'est le meilleur ROI dans votre stack parce que **PostgREST + RLS + GoTrue continuent à fonctionner sans modification** — le client ne sait même pas qu'il tape sur Mongo ou MySQL.

| Engine | FDW disponible |
|---|---|
| MySQL/MariaDB | `mysql_fdw` |
| MongoDB | `mongo_fdw` |
| Redis | `redis_fdw` |
| Oracle | `oracle_fdw` |
| SQL Server / Sybase | `tds_fdw` |
| ClickHouse | `clickhousedb_fdw` |
| Elasticsearch | `multicorn` + `pg_es_fdw` |
| Kafka | `kafka_fdw` |
| SQLite, CSV, fichiers | `sqlite_fdw`, `file_fdw` |
| HTTP/REST/GraphQL | `multicorn` + adapter Python |
| **Tout le reste** | `multicorn` ou `jdbc_fdw` |

Bénéfice direct : un workspace osionos peut faire `SELECT * FROM external.crm_contacts WHERE owner_id = auth.uid()` et la RLS s'applique au-dessus du FDW. Les écritures FDW marchent en `INSERT/UPDATE/DELETE` sur la plupart (PG, MySQL, Mongo, Oracle, MSSQL).

**Limite** : pas de transactions distribuées, performance dépend du pushdown. À combiner avec les couches suivantes.

## La couche adapter-registry + query-router (déjà en place, à étendre)

Pour les engines où FDW est trop lent, instable, ou inexistant (Cassandra, Neo4j, DynamoDB, Firestore, APIs SaaS), c'est `query-router` qui prend le relais. Le pattern :

```
┌──────────────────────────────────────────────────────────┐
│  IDatabaseAdapter (contrat commun, langage-agnostic)     │
│  ─ list(resource, filters, projection, cursor)            │
│  ─ get(resource, id)                                      │
│  ─ insert(resource, payload, idempotencyKey?)             │
│  ─ update(resource, id, patch)                            │
│  ─ upsert(resource, key, payload)                         │
│  ─ delete(resource, id)                                   │
│  ─ stream(resource, filters)  ← CDC / change stream       │
│  ─ tx(fn)                     ← optionnel, intra-engine   │
│  ─ capabilities()             ← matrice de support        │
└──────────────────────────────────────────────────────────┘
```

Une implémentation par famille :

| Famille | Adapter | Engines couverts |
|---|---|---|
| SQL générique | `jdbc-adapter` | PG, MySQL, MSSQL, Oracle, CockroachDB, Aurora, DB2, Snowflake |
| Document | `mongo-adapter` | MongoDB, Cosmos DB (API Mongo), DocumentDB |
| KV | `kv-adapter` | Redis, DynamoDB, etcd, Memcached |
| Wide-column | `cql-adapter` | Cassandra, ScyllaDB, AstraDB |
| Search | `search-adapter` | Elasticsearch, OpenSearch, Meilisearch, Typesense |
| Graph | `graph-adapter` | Neo4j (Bolt), ArangoDB, Neptune |
| Time-series | `tsdb-adapter` | InfluxDB, TimescaleDB, QuestDB |
| Vector | `vector-adapter` | Qdrant, Weaviate, Milvus, pgvector |
| Object/Lakehouse | `lake-adapter` | Iceberg/Delta sur MinIO/S3 |
| HTTP | `http-adapter` | REST, GraphQL, gRPC (avec auth dans adapter-registry) |

Toutes vivent dans `query-router`, déclarent leurs **capabilities** (UPSERT ? streams ? transactions ?), et reçoivent l'identité utilisateur via JWT propagé par Kong.

## La couche Trino (analytique fédérée, déjà en place)

Garde son rôle actuel : **lectures cross-source**, BI, exports. Ajouter au minimum les catalogs `mysql`, `mssql`, `clickhouse`, `elasticsearch`, et surtout `iceberg` sur MinIO pour avoir un lakehouse write-capable.

Trino **ne sert pas** au CRUD applicatif (voir la réponse précédente).

## La couche CDC / outbox pour la cohérence multi-engine

Une écriture qui doit toucher PG + Mongo + ES atomiquement n'existera **jamais** nativement. Solution standard, à intégrer dans `query-router` :

1. **Outbox pattern dans PostgreSQL** : l'écriture applicative tape uniquement PG (donc reste transactionnelle + RLS). Une table `outbox_events` reçoit le delta.
2. **Debezium** lit le WAL PostgreSQL → publie sur **Redpanda/Kafka** (ou directement Redis Streams qui est déjà dans la stack).
3. **Consumers par adapter** rejouent l'event vers Mongo / ES / Cassandra / Redis / webhook externe.
4. **Sagas** pour les rollbacks compensatoires si un consumer échoue durablement.

Résultat : cohérence éventuelle garantie, audit gratuit, replay possible, et le client ne voit qu'**une seule API d'écriture transactionnelle** (PostgREST).

## Le contrat exposé au client (DX uniforme)

Le SDK `@mini-baas/js` doit cacher tout ça derrière une API à la Supabase, indépendante du moteur :

```ts
const db = baas.from('crm_contacts');           // resource logique
await db.select('id,name,email').eq('city', 'Paris').limit(50);
await db.insert({ name: 'X' });
await db.upsert({ id: '...', name: 'Y' });
await db.on('INSERT', payload => ...);          // realtime, fanout via Redis Streams
```

L'`adapter-registry` stocke pour chaque `resource` :
- l'engine cible (`postgres://...`, `mongodb://...`, `https://api.hubspot...`),
- les credentials AES-256-GCM,
- le schéma logique (pour codegen TypeScript),
- les capabilities,
- la policy de tenancy (`tenant_field=workspace_id`).

## La couche Realtime étendue

`realtime-agnostic` aujourd'hui watch PG (logical replication) + Mongo (change streams). À étendre :
- **Redis Streams** : déjà natif.
- **Cassandra/Scylla** : CDC commit log.
- **MySQL** : binlog via Debezium.
- **MSSQL** : Change Tracking via Debezium.
- **Elasticsearch** : polling avec `_seq_no`.
- **APIs externes** : webhooks entrants (déjà supporté par le pattern HTTP adapter).

Toutes les sources publient dans **un seul bus Redis Streams** consommé par `realtime-agnostic` → un seul protocole WebSocket pour le client.

## Schéma global cible

```
                          ┌─────────────────────────────────────┐
Client (osionos / opposite-osiris / SDK @mini-baas/js)          │
                          └──────────────┬──────────────────────┘
                                         │ HTTPS + JWT
                                         ▼
                                       Kong (WAF, rate-limit, JWT)
                                         │
       ┌─────────────────────────────────┼─────────────────────────────────┐
       ▼                                 ▼                                 ▼
  PostgREST                       query-router                         Trino
  (RLS, auth.uid)                 (adapters + caps)                    (federation R/O)
       │                                 │                                 │
       │ FDW                             │ native drivers                  │ catalogs
       ▼                                 ▼                                 ▼
  Postgres ◄──────── outbox ───► Debezium ──► Redis Streams ──► realtime-agnostic
       │                                 │                                 │
   ┌───┴───┐                  ┌──────────┼──────────┐                ┌─────┴────┐
   ▼       ▼                  ▼          ▼          ▼                ▼          ▼
 MySQL  Mongo               Cassandra  Neo4j     ES/OS         Iceberg/MinIO  CRMs API
 Oracle Redis               DynamoDB   Qdrant    InfluxDB
 MSSQL  Kafka               …          …         …
```

## Roadmap concrète (par étapes, sans tout casser)

1. **Court terme — élargir PostgREST sans coder** : installer `mysql_fdw`, `mongo_fdw`, `tds_fdw`, `multicorn` dans l'image Postgres. Premier gain énorme avec zéro nouveau service.
2. **Court terme — formaliser `IDatabaseAdapter`** dans `query-router`, refactorer l'adapter Mongo existant pour qu'il s'y conforme. Ajouter `capabilities()`.
3. **Moyen terme — outbox + Debezium** : table `outbox_events` en PG, déploiement Debezium connecté à Redis Streams, premier consumer Mongo.
4. **Moyen terme — adapters prioritaires** : `jdbc-adapter` (couvre MySQL/MSSQL/Oracle d'un coup), `http-adapter` (débloque tous les SaaS).
5. **Long terme — lakehouse Iceberg** sur MinIO via Trino pour analytics write-heavy.
6. **Long terme — codegen TS** depuis `adapter-registry` pour typer le SDK comme Supabase.

## Ce qu'il faut accepter (les vraies limites physiques)

- **Pas de transaction ACID cross-engine native** : c'est un théorème, pas un manque d'effort. La saga + outbox est la réponse industrielle.
- **Sémantique non-uniforme** : un `JOIN` sur Redis n'a pas de sens, un `WHERE LIKE` sur DynamoDB est une full-scan. Les `capabilities()` doivent être exposées au client pour qu'il sache ce qui est efficient.
- **Performance ≠ Postgres natif** : passer par FDW ou un adapter ajoute toujours 1–10 ms ; ce n'est pas un remplaçant des drivers natifs pour du high-throughput.

## TL;DR

> **PostgreSQL + FDWs** pour exposer 80 % des engines via la voie PostgREST/RLS existante,
> **query-router avec adapters typés** pour les 20 % restants et tout ce qui sort du SQL,
> **Trino** pour les lectures fédérées analytiques,
> **Outbox + Debezium + Redis Streams** pour la cohérence et le realtime cross-engine,
> **un contrat unique `IDatabaseAdapter`** + **un SDK uniforme** pour que le client ne voie qu'une seule API.

C'est exactement le chemin que prennent Supabase (FDW récents), Hasura (remote sources), et PlanetScale (Vitess + connectors) — vous avez déjà toutes les briques, il reste à formaliser le contrat adapter et à activer les FDWs.