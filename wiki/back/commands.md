# Backend — référence exhaustive des commandes

Toutes les commandes utilisées pour **monter**, **vérifier**, **observer**,
**scanner** et **diagnostiquer** le backend `mini-baas-infra`. Chaque entrée
explique *quand* l'utiliser, *ce qu'elle fait*, et *à quoi elle se substitue*.

> Convention : tout passe par Docker. Aucun script ne suppose npm / pg-client /
> redis-cli / vault installés sur le host. Si tu as `docker` + `make` + `bash`,
> tu peux tout lancer.

---

## 0. Lecture rapide

```
┌─────────────────────────────────────────────────────────────────────┐
│  Cycle de vie d'une session "backend"                              │
│                                                                     │
│  1. make baas-up           ←  démarre la stack (compose --wait)    │
│  2. make baas-verify-m1    ←  static gate : structure OK ?         │
│  3. BAAS_VERIFY_LIVE=1                                             │
│     make baas-verify-m1   ←  live gate : la stack répond ?         │
│  4. (boucle dev: edit → m1 → m2 → … → m9)                          │
│  5. make baas-security-scan ←  Semgrep + Trivy + Audit + TruffleHog│
│  6. make baas-zap          ←  DAST baseline contre WAF live        │
│  7. make baas-down         ←  cleanup (volumes -v)                 │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 1. Cycle de vie de la stack

### `make baas-up`

Démarre tout `apps/baas/mini-baas-infra/docker-compose.yml` avec
`docker compose up -d --wait`, en appliquant les profiles `control-plane +
adapter-plane + data-plane + background + storage` par défaut.

Avant de monter les services, il appelle
`bash apps/baas/scripts/generate-localhost-cert.sh` pour générer la
chaîne TLS locale (CA + cert host) sous `apps/baas/certs/`.

```bash
# Démarrage standard (ports par défaut, peut clasher avec un PG local)
make baas-up

# Démarrage "safe" (remappe tout sur ports 1XXXX pour éviter les conflits)
BAAS_VERIFY_SAFE_PORTS=1 make baas-up

# Démarrage sans WAF (plus rapide, utile pour M1-M3)
BAAS_VERIFY_SAFE_PORTS=1 BAAS_VERIFY_NO_WAF=1 make baas-up

# Démarrage avec observability complète (prometheus / grafana / loki / tempo)
BAAS_VERIFY_SAFE_PORTS=1 BAAS_VERIFY_OBSERVABILITY=1 make baas-up

# Démarrage "tout inclus" (analytics + extras + observability)
BAAS_VERIFY_SAFE_PORTS=1 BAAS_VERIFY_FULL=1 make baas-up
```

**Sous le capot** — vérifié avec `make -n baas-up` :
```bash
bash apps/baas/scripts/generate-localhost-cert.sh
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml \
  --profile control-plane --profile adapter-plane --profile data-plane \
  --profile background --profile storage up -d --wait
```

### `make baas-down`

Stoppe la stack **et supprime ses volumes** (`down -v`). Utile pour repartir
d'un état vierge.

```bash
make baas-down
BAAS_VERIFY_SAFE_PORTS=1 make baas-down   # mêmes overrides qu'au up
```

### Tableau des port-mappings host (mode `BAAS_VERIFY_SAFE_PORTS=1`)

| Service | Port host (safe) | Port par défaut | Port interne |
|---|---|---|---|
| PostgreSQL | `15432` | `5432` | `5432` |
| MongoDB | `27018` | `27017` | `27017` |
| Redis | `16379` | `6379` | `6379` |
| Vault | `18200` | `8200` | `8200` |
| Kong (data plane) | `18000` | `8000` | `8000` |
| Kong (admin) | `18001` | `8001` | `8001` |
| WAF HTTP | `18880` | `8880` | `8080` |
| WAF HTTPS | `18443` | `8443` | `8443` |
| MinIO API | `19000` | `9000` | `9000` |
| MinIO console | `19011` | `9011` | `9001` |
| Prometheus | `19090` | `9090` | `9090` |
| Grafana | `13030` | `3030` | `3000` |
| Loki | `13100` | `3100` | `3100` |
| Promtail | `19080` | `9080` | `9080` |
| Tempo | `13200` | `3200` | `3200` |
| OTel collector OTLP/HTTP | `14318` | `4318` | `4318` |
| OTel collector OTLP/gRPC | `14317` | `4317` | `4317` |
| OTel collector health | `13133` | `13133` | `13133` |

Les **services NestJS** (`query-router`, `mongo-api`, …) ne sont **pas**
exposés sur le host — ils sont contactés via Kong (8000/18000) ou directement
sur le réseau docker `mini-baas_mini-baas` quand on `docker compose exec`.

---

## 2. Verify gates (M1 → M9)

Chaque jalon a son script `apps/baas/mini-baas-infra/scripts/verify/mX-*.sh`.
Le make target est un thin wrapper.

### Mode statique (toujours)

Vérifie la **structure** du repo : fichiers présents, signatures de méthodes,
migrations à plat, etc. Pas besoin de stack up.

```bash
make baas-verify-m1   # HEALTHCHECK + IDatabaseAdapter + OpenAPI + audit_log
make baas-verify-m2   # mysql/redis/http engines + Trino + SDK codegen
make baas-verify-m3   # outbox + unified RLS + idempotency + relay
make baas-verify-m4   # prometheus/grafana/loki + correlation-id interceptor
make baas-verify-m5   # WAF + Kong plugins + headers + scanner orchestrator
make baas-verify-m6   # PG FDW universal gateway (mysql/mongo/oracle/clickhouse/redis fdw)
make baas-verify-m7   # adapters étendus
make baas-verify-m8   # saga / debezium / outbox généralisé
make baas-verify-m9   # ABAC centralisé (POST /permissions/decide fail-closed)

# Chaîne complète (M1 → M9, chaque jalon dépend du précédent)
make baas-verify-all
```

### Mode live (`BAAS_VERIFY_LIVE=1`)

Ajoute le flag `--live` au script. Probes runtime :
- `docker compose ps` : aucune unhealthy / starting
- `fetch('/docs-json')` à l'intérieur du container de chaque app NestJS
- `SELECT 1 FROM schema_migrations WHERE version = N` sur Postgres
- `psql` insert/select roundtrip pour M2 (mysql/redis/http engines)
- `XRANGE outbox.order` pour confirmer la projection Redis Streams (M3)
- `mongosh ... countDocuments(...)` pour la projection Mongo (M3)
- `curl /-/ready` sur Prometheus, Grafana, Loki (M4)
- CRS 403 sur SQLi, Kong 429 sur burst, headers HSTS/CSP… (M5)
- POST `/permissions/decide` default-deny (M9)

```bash
# Stack up d'abord
BAAS_VERIFY_SAFE_PORTS=1 make baas-up

# Puis le gate live
BAAS_VERIFY_LIVE=1 BAAS_VERIFY_SAFE_PORTS=1 make baas-verify-m1
BAAS_VERIFY_LIVE=1 BAAS_VERIFY_SAFE_PORTS=1 make baas-verify-all
```

### Exécution directe du script (sans make)

Si tu veux passer des args spécifiques ou voir le script sans la décoration
make, tu peux invoquer le `.sh` direct :

```bash
bash apps/baas/mini-baas-infra/scripts/verify/m1-hardening.sh
bash apps/baas/mini-baas-infra/scripts/verify/m2-federation.sh --live
```

### Override des UUIDs de test (M2/M3 live)

```bash
M2_USER_ID="00000000-0000-4000-8000-000000000002" \
M3_USER_ID="00000000-0000-4000-8000-000000000003" \
BAAS_VERIFY_LIVE=1 BAAS_VERIFY_SAFE_PORTS=1 make baas-verify-m3
```

---

## 3. Suite scanner sécurité

Un orchestrateur Docker-only :
`apps/baas/mini-baas-infra/scripts/security/run-security-scans.sh`.

### Lancement complet

```bash
make baas-security-scan
```

Enchaîne :
1. **Semgrep** — SAST sur tout le repo, configs OWASP Top Ten + TS + Dockerfile + Node + JS
2. **npm / pnpm audit** — SCA sur 7 lockfiles (baas/src, baas/sdk, baas/scripts, opposite-osiris, calendar, mail, osionos/app)
3. **Trivy** — fs scan + image scan (toutes images `mini-baas-*` / `track-binocle-*` / `dlesieur/realtime-*`)
4. **TruffleHog** — secrets sur git history + working tree (`--only-verified`)

Sortie : `apps/baas/mini-baas-infra/artifacts/security/` (semgrep.json,
npm-audit.txt, trivy/*.json, trufflehog.json).

### Sélectif

```bash
# Un seul scanner
make baas-security-scan SECURITY_ONLY=semgrep
make baas-security-scan SECURITY_ONLY=trivy
make baas-security-scan SECURITY_ONLY=trufflehog
make baas-security-scan SECURITY_ONLY=npm-audit

# Plusieurs scanners
make baas-security-scan SECURITY_ONLY=semgrep,trivy

# Exclure un scanner
make baas-security-scan SECURITY_SKIP=trufflehog
```

### Seuils

```bash
# npm audit : ne bloque que sur CRITICAL (default: high)
make baas-security-scan SECURITY_FAIL_LEVEL=critical

# Trivy : ne reporte que CRITICAL (default: HIGH,CRITICAL)
make baas-security-scan SECURITY_TRIVY_SEVERITY=CRITICAL

# Trivy : skip images, juste filesystem
SKIP_BUILD=1 make baas-security-scan SECURITY_ONLY=trivy
```

### Exécution directe

```bash
bash apps/baas/mini-baas-infra/scripts/security/run-security-scans.sh --help
bash apps/baas/mini-baas-infra/scripts/security/run-security-scans.sh --only=trivy --skip=trufflehog
```

---

## 4. DAST (OWASP ZAP)

```bash
# Stack up d'abord
BAAS_VERIFY_SAFE_PORTS=1 make baas-up

# Baseline scan (~5-10 min) contre le WAF HTTPS
BAAS_VERIFY_SAFE_PORTS=1 make baas-zap

# Ou cibler une URL custom
WAF_HTTPS_PORT=18443 bash apps/baas/mini-baas-infra/scripts/verify/zap-baseline.sh https://localhost:18443/auth/v1/health
```

Rapports :
- `apps/baas/mini-baas-infra/artifacts/security/zap-baseline.json`
- `apps/baas/mini-baas-infra/artifacts/security/zap-baseline.html`
- `apps/baas/mini-baas-infra/artifacts/security/zap-baseline.md`

Exit code : non-zero si **High** trouvé. Medium = warning non bloquant.

---

## 5. SDK codegen (typed clients)

Construction d'un client TypeScript généré depuis les OpenAPI de chaque
service NestJS (`/docs-json`).

```bash
# Build l'image one-shot puis lance collect + codegen dans Docker
make baas-codegen

# Build l'image seule
make baas-codegen-image

# Manuel : collect d'abord, puis codegen
bash apps/baas/mini-baas-infra/scripts/openapi-collect.sh
cd apps/baas/sdk && npm install && npm run codegen

# Collect ciblé (un seul service)
bash apps/baas/mini-baas-infra/scripts/openapi-collect.sh --apps query-router,mongo-api
```

Output : `apps/baas/mini-baas-infra/openapi/<service>.json` puis
`apps/baas/sdk/dist/` (clients TypeScript).

---

## 6. Healthchecks ad-hoc

### Health Liveness / Readiness — chaque service NestJS

Convention : tout service expose `GET /health/live` et `GET /health/ready`
(implémentés dans `src/health.controller.ts`). Quand la stack est up :

```bash
# Depuis le réseau docker (recommandé — pas besoin de port-mapping)
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T query-router \
  node -e "fetch('http://127.0.0.1:4001/health/live').then(r=>r.text()).then(console.log)"

# Idem via wget (image plus light)
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T outbox-relay \
  wget -qO- http://127.0.0.1:3130/health/live
```

| Service | Port interne | Endpoint health | Endpoint OpenAPI |
|---|---|---|---|
| `query-router` | 4001 | `/health/live`, `/health/ready` | `/docs`, `/docs-json` |
| `mongo-api` | 3010 | `/health/live`, `/health/ready` | `/docs`, `/docs-json` |
| `adapter-registry` | 3020 | `/health/live`, `/health/ready` | `/docs`, `/docs-json` |
| `email-service` | 3030 | `/health/live`, `/health/ready` | `/docs`, `/docs-json` |
| `storage-router` | 3040 | `/health/live`, `/health/ready` | `/docs`, `/docs-json` |
| `permission-engine` | 3050 | `/health/live`, `/health/ready` | `/docs`, `/docs-json` |
| `schema-service` | 3060 | `/health/live`, `/health/ready` | `/docs`, `/docs-json` |
| `analytics-service` | 3070 | `/health/live`, `/health/ready` | `/docs`, `/docs-json` |
| `gdpr-service` | 3080 | `/health/live`, `/health/ready` | `/docs`, `/docs-json` |
| `newsletter-service` | 3090 | `/health/live`, `/health/ready` | `/docs`, `/docs-json` |
| `ai-service` | 3100 | `/health/live`, `/health/ready` | `/docs`, `/docs-json` |
| `log-service` | 3110 | `/health/live`, `/health/ready` | `/docs`, `/docs-json` |
| `session-service` | 3120 | `/health/live`, `/health/ready` | `/docs`, `/docs-json` |
| `outbox-relay` | 3130 | `/health/live`, `/health/ready` | `/docs`, `/docs-json` |

### Health côté infra

```bash
# Vault — status (sealed / unsealed)
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T vault \
  vault status -address=http://127.0.0.1:8200

# Postgres — psql one-liner
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T postgres \
  psql -U postgres -d postgres -c "SELECT version();"

# MongoDB — ping
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T mongo \
  mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
    --authenticationDatabase admin --quiet --eval 'db.runCommand({ping:1})'

# Redis — PING
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T redis \
  redis-cli PING

# Kong admin API — liste les services
curl -fsS http://127.0.0.1:18001/services | jq '.data[].name'

# WAF — endpoint custom /waf-health (200/204 si OK)
curl -ksS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18880/waf-health

# Prometheus — ready
curl -fsS http://127.0.0.1:19090/-/ready

# Grafana — health JSON
curl -fsS http://127.0.0.1:13030/api/health

# Loki — ready
curl -fsS http://127.0.0.1:13100/ready
```

### Healthcheck end-to-end via le Makefile racine

Le target `make healthcheck` boucle sur tous les endpoints exposés en HTTPS
(via `local-https-proxy`) et vérifie qu'ils répondent :

```bash
make healthcheck
```

Sous le capot :
```bash
bash apps/baas/scripts/generate-localhost-cert.sh
docker compose ps
curl --cacert apps/baas/certs/track-binocle-local-ca.pem ... https://localhost:8000
curl --cacert apps/baas/certs/track-binocle-local-ca.pem ... https://localhost:4000/api/auth/bridge/health
curl --cacert apps/baas/certs/track-binocle-local-ca.pem ... https://localhost:3001
# ... etc pour Mail, Calendar, bridges
```

---

## 7. Probes runtime sur les endpoints métier

### Query router — exécuter une op via l'adapter dispatcher

```bash
# Préalable : stack up + adapter enregistré (récupérer son ID via POST /databases)
DB_ID="<uuid>"
USER_ID="00000000-0000-4000-8000-000000000002"

docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T query-router \
  node --input-type=module -e "
    const headers = {
      'Content-Type': 'application/json',
      'X-User-Id': '$USER_ID',
      'X-User-Role': 'authenticated',
    };
    const r = await fetch('http://127.0.0.1:4001/query/$DB_ID/tables/users', {
      method: 'POST', headers,
      body: JSON.stringify({ op: 'list', limit: 10 })
    });
    console.log(r.status, await r.text());
  "
```

### Adapter-registry — enregistrer une DB externe

```bash
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T adapter-registry \
  node --input-type=module -e "
    const r = await fetch('http://127.0.0.1:3020/databases', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-User-Id': '$USER_ID',
        'X-User-Role': 'authenticated',
      },
      body: JSON.stringify({
        engine: 'mysql',
        name: 'demo-mysql',
        connection_string: 'mysql://user:pass@mysql:3306/demo',
      })
    });
    console.log(await r.text());
  "
```

### Permission-engine — POST /permissions/decide (M9)

```bash
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T permission-engine \
  node --input-type=module -e "
    const r = await fetch('http://127.0.0.1:3050/permissions/decide', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Service-Token': process.env.ADAPTER_REGISTRY_SERVICE_TOKEN ?? 'dev-service-token',
      },
      body: JSON.stringify({
        user: { id: '$USER_ID' },
        resource_type: 'postgresql',
        resource_name: 'users',
        op: 'select',
        attributes: { request_id: 'manual-probe' },
      })
    });
    console.log(await r.text());
  "
```

### Engines introspection — quelles bases sont supportées ?

```bash
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T query-router \
  node -e "fetch('http://127.0.0.1:4001/engines').then(r=>r.text()).then(console.log)"
# → {"engines":["postgresql","mongodb","mysql","redis","http"]}
```

### Schema-service — lister les schemas

```bash
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T schema-service \
  node -e "fetch('http://127.0.0.1:3060/schemas').then(r=>r.text()).then(console.log)"
```

---

## 8. Phase smoke tests (anciens — couvrent flows end-to-end via Kong)

15 scripts `apps/baas/mini-baas-infra/scripts/phaseN-*.sh` qui font des
roundtrips end-to-end (signup → login → JWT → PostgREST, etc.). Ils
prennent `BASE_URL` (default `http://localhost:8000`, donc Kong) et un
`APIKEY` (default `public-anon-key`).

```bash
# Lance un phase test en local sur Kong
BASE_URL=http://localhost:18000 APIKEY=public-anon-key \
  bash apps/baas/mini-baas-infra/scripts/phase1-smoke-test.sh

# Liste complète des phases
ls apps/baas/mini-baas-infra/scripts/phase*-*.sh
```

| Phase | Couverture |
|---|---|
| `phase1` | Kong routing + Auth (GoTrue) + PostgREST avec/sans JWT |
| `phase2` | Smoke complet (signup, login, refresh, signout) |
| `phase3` | Authenticated DB op (insert + select RLS) |
| `phase4` | User isolation (RLS empêche A de lire les rows de B) |
| `phase5` | DB info endpoint (introspection schemas) |
| `phase6` | HTTP methods (GET/POST/PATCH/DELETE) |
| `phase7` | Error handling (4xx, 5xx, payload trop gros) |
| `phase8` | Token lifecycle (refresh, revoke, expiration) |
| `phase9` | Storage operations (sign URL, upload, download) |
| `phase10` | Mutations + complex queries (joins, filters) |
| `phase11` | Realtime WebSocket (subscribe → INSERT → message reçu) |
| `phase12` | Rate-limiting Kong (429 sur burst) |
| `phase13` | CORS preflight (OPTIONS → Access-Control-Allow-*) |
| `phase14` | Mongo MVP (mongo-api end-to-end) |
| `phase16` | E2E auth flow complet |

---

## 9. Migrations Postgres

Toutes les migrations sont dans `apps/baas/mini-baas-infra/scripts/migrations/postgresql/`.
Elles s'appliquent au démarrage du container `postgres` via le script
`db-bootstrap` (compose service `db-bootstrap`, qui exécute en `exited 0`
après application).

### Voir la liste

```bash
ls apps/baas/mini-baas-infra/scripts/migrations/postgresql/
```

### Vérifier quelles migrations sont appliquées

```bash
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T postgres \
  psql -U postgres -d postgres -c "SELECT version, name FROM public.schema_migrations ORDER BY version"
```

### Migrations clés (référencées par les verify scripts)

| Version | Fichier | Apporte |
|---|---|---|
| 007 | `007_permissions_system.sql` | Rôles / policies ABAC, table `user_roles`, `roles`, `resource_policies` |
| 013 | `013_audit_log.sql` | Table `audit_log` avec `request_id`, `actor`, `payload` |
| 014 | `014_add_http_engine.sql` | CHECK constraint accepte `'http'` comme engine |
| 015 | `015_outbox_events.sql` | Table `outbox_events` (state machine pending/published/failed/dead) |
| 016 | `016_unify_rls.sql` | `auth.current_user_id()` lit `request.jwt.claims` partout |
| 020 | `020_fdw_servers.sql` | Bootstrap helpers FDW (`ensure_fdw_extension`, `register_fdw_foreign_table`) |
| 030 | `030_tenants.sql` *(M11)* | Multi-tenant onboarding, table `tenants`, `tenant_databases` |

---

## 10. Vault — secrets (commandes locales et Fly.io)

### Local (docker-compose vault)

```bash
# Démarre Vault local (profile 'secrets')
make vault-up

# Status
make vault-status

# Seed (charge .env initial dans Vault local)
make vault-seed

# Rotation des AppRole secret_ids
make vault-rotate-approles

# Verify (lit chaque path et vérifie qu'il répond)
make vault-verify-approles

# Récupère un secret précis (admin/reader/writer)
make vault-get-secrets VAULT_SECRET_PATH=secret/data/track-binocle/env/baas

# Logout local
make vault-logout
```

### Fly.io (Vault distant `track-binocle-vault`)

```bash
# Status distant
make vault-status VAULT_ADDR=https://track-binocle-vault.fly.dev

# Récupère un reader token (24h TTL) sur Fly
make vault-fly-invite-token VAULT_TEAM_ROLE=reader

# Récupère un writer token (8h TTL)
make vault-fly-invite-token VAULT_TEAM_ROLE=writer

# Login en tant qu'admin via OIDC GitHub (à utiliser depuis CI)
make vault-login-jwt

# Fetch shared (.vault/track-binocle-*.env est mis à jour)
make vault-fetch-shared
```

### Bootstrap d'un nouveau dev

```bash
# 1. Récupère un reader token depuis le Vault Fly (avec son GitHub login)
make vault-fly-invite-token VAULT_TEAM_ROLE=reader

# 2. Login dans Vault local avec ce token
make login-user

# 3. Fetch tous les secrets nécessaires (.env, KONG_PUBLIC_API_KEY, etc.)
make vault-fetch-shared
```

---

## 11. Certificats locaux (TLS)

```bash
# Génère la chaîne CA + cert host pour *.localhost
bash apps/baas/scripts/generate-localhost-cert.sh
# Ou idempotent via make :
make certs

# Trust la CA dans le keystore système (sudo)
make certs-trust-system

# Trust la CA dans le keystore browser (Firefox NSSDB)
make certs-trust-browser-host

# Diagnostic chaîne TLS (chain validation, dates, SAN)
make certs-doctor
```

Output : `apps/baas/certs/`
- `track-binocle-local-ca.pem` — la CA self-signed (à truster)
- `track-binocle-local.crt` / `.key` — cert + clé pour `*.localhost`

`CURL_HEALTH` (défini dans `common.mk`) utilise cette CA pour tous les
healthchecks HTTPS :

```bash
curl --cacert apps/baas/certs/track-binocle-local-ca.pem -fsS https://localhost:8000
```

---

## 12. SQL admin (Postgres)

```bash
# Shell psql interactif
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec postgres \
  psql -U postgres -d postgres

# One-shot SQL
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T postgres \
  psql -U postgres -d postgres -c "SELECT count(*) FROM public.users"

# Appliquer une migration manuellement
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T postgres \
  psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -f - < apps/baas/mini-baas-infra/scripts/migrations/postgresql/013_audit_log.sql

# Lister les RLS policies actives
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T postgres \
  psql -U postgres -d postgres -c \
  "SELECT schemaname, tablename, policyname FROM pg_policies ORDER BY schemaname, tablename"

# Voir le contenu de la file outbox
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T postgres \
  psql -U postgres -d postgres -c \
  "SELECT id, aggregate, event_type, status, created_at FROM public.outbox_events ORDER BY id DESC LIMIT 20"

# Voir les rows audit
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T postgres \
  psql -U postgres -d postgres -c \
  "SELECT request_id, actor, action, target, status_code FROM public.audit_log ORDER BY created_at DESC LIMIT 20"
```

---

## 13. MongoDB admin

```bash
# Shell mongosh interactif
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec mongo \
  mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
  --authenticationDatabase admin

# Compte les docs d'une collection
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T mongo \
  mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
  --authenticationDatabase admin --quiet --eval \
  "db.getSiblingDB('mini_baas').orders_view.countDocuments({})"

# Voir le replica set status (Mongo est en RS, requis par Debezium)
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T mongo \
  mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
  --authenticationDatabase admin --quiet --eval "rs.status().ok"
```

---

## 14. Redis admin

```bash
# Shell redis-cli
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec redis redis-cli

# Voir la file Redis Streams "outbox.order" (publiée par outbox-relay)
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T redis \
  redis-cli XRANGE outbox.order - + COUNT 10

# Voir tous les streams
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T redis \
  redis-cli KEYS 'outbox.*'

# Voir le cache d'idempotency (IdempotencyMiddleware)
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T redis \
  redis-cli KEYS 'idempotency:*'

# Flush (DANGER en non-dev)
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T redis \
  redis-cli FLUSHDB
```

---

## 15. Trino (analytics federated SQL)

```bash
# Lister les catalogs branchés
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T trino \
  trino --execute "SHOW CATALOGS"

# Query inter-engine : count Postgres × count Iceberg
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T trino \
  trino --execute \
  "SELECT (SELECT count(*) FROM postgresql.public.users) AS pg_users,
          (SELECT count(*) FROM iceberg.default.events) AS iceberg_events"

# Créer une table Iceberg + insert + select (utilisé par m2-federation.sh --live)
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T trino trino --execute \
  "CREATE SCHEMA IF NOT EXISTS iceberg.default;
   CREATE TABLE iceberg.default.demo (id int, v varchar);
   INSERT INTO iceberg.default.demo VALUES (1, 'hello');
   SELECT * FROM iceberg.default.demo;"
```

---

## 16. Inspection des logs

```bash
# Logs d'un service précis (live tail)
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml logs -f query-router

# Logs des 5 derniers événements d'un service
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml logs --tail=5 outbox-relay

# Logs filtrés sur un correlation-id (M4 — CorrelationIdInterceptor propage X-Request-ID)
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml logs --since 10m | \
  grep "req-abc-123"

# Logs ingérés dans Loki (si observability profile up)
curl -fsS "http://127.0.0.1:13100/loki/api/v1/query?query=%7Bjob%3D%22varlogs%22%7D"
```

---

## 17. Release et publication

```bash
# Build, tag, push toutes les images BaaS (DockerHub + GHCR)
make version VERSION=v1.2.3

# Build seul (tag locales)
make baas-build VERSION=v1.2.3

# Push seul (vers DockerHub + GHCR)
make baas-push VERSION=v1.2.3

# Pin la version dans le wrapper Dockerfile
make baas-update VERSION=v1.2.3

# Smoke test post-release (frontend appelle le BaaS publié)
make baas-smoke

# Build l'image SMTP-enabled (séparée)
make baas-release-smtp BAAS_SMTP_VERSION=smtp-v1
```

---

## 18. Stack frontale complète (root compose)

Le `Makefile` racine pilote l'ensemble (frontend + backend + auth-gateway + bridges) :

```bash
# Bootstrap complet (certs, build, prefetch, up, db-password sync, wait)
make up

# Backend infra only (pas de hot-reload frontend)
make up-infra

# Healthcheck end-to-end (frontend + bridges + BaaS + Mail + Calendar)
make healthcheck

# Cleanup Docker (images + builders + volumes)
make docker-clean
make docker-clean-volumes  # supprime aussi les volumes
make docker-rm-all         # nuke complet (compose down + rm -v)
```

---

## 19. Dépannage rapide

### Conflit de port

```bash
# Symptôme : "Bind for 127.0.0.1:5432 failed: port is already allocated"
# Fix : passer en mode safe ports
make baas-down
BAAS_VERIFY_SAFE_PORTS=1 make baas-up
```

### Un service est unhealthy

```bash
# Voir le status global
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml ps

# Voir les logs d'un unhealthy précis
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml logs <service>

# Restart un service unhealthy seul (sans toucher au reste)
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml restart <service>
```

### WAF ne démarre pas

```bash
# 99 % du temps : configs WAF empty (incident d'IDE crash)
git status apps/baas/mini-baas-infra/docker/services/waf/
git restore apps/baas/mini-baas-infra/docker/services/waf/

# Skip WAF si urgence (M1-M3 n'en ont pas besoin)
BAAS_VERIFY_NO_WAF=1 make baas-up
```

### Trivy met 10 minutes au 1er run

C'est normal : Trivy télécharge sa DB de vulnérabilités (~1 GB). Les
runs suivants utilisent le cache `apps/baas/mini-baas-infra/artifacts/security/trivy/cache/`.

### Verify M4 fail sur PrometheusModule

C'est une **dette connue** (M4.b). Le module Prometheus est référencé mais
pas `register()` dans les `app.module.ts` → `/metrics` n'est pas exposé.
Le gate M4 le marque en soft-warn, pas en fail.

### Idempotency-Key replay ne fonctionne pas

```bash
# Vérifier que Redis est up et que le middleware est wiré
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T redis redis-cli PING
grep -l "IdempotencyMiddleware" apps/baas/mini-baas-infra/src/apps/*/src/app.module.ts
```

---

## 20. Diff "static" vs "live"

| Aspect | Static gate | Live gate |
|---|---|---|
| Durée | < 5 sec | 30-120 sec / jalon |
| Pré-requis | rien | `make baas-up` |
| Couvre | structure repo (fichiers, signatures, migrations) | runtime (HTTP, DB, Redis) |
| Fail-fast | oui (`set -euo pipefail`) | oui |
| Idempotent | oui | oui |
| CI-friendly | oui (pas de Docker) | oui (Docker dans la CI) |

Règle d'or : **static avant chaque commit**, **live avant chaque PR**.

---

## 21. Quoi lancer dans quel ordre — workflow complet

```bash
# 0. Setup une fois
make certs
make vault-fetch-shared    # si on doit lire le Vault Fly

# 1. Cycle dev : edit → static gate
make baas-verify-all

# 2. Avant PR : live gates + scanner suite
BAAS_VERIFY_SAFE_PORTS=1 make baas-up
BAAS_VERIFY_LIVE=1 BAAS_VERIFY_SAFE_PORTS=1 make baas-verify-all
make baas-security-scan
BAAS_VERIFY_SAFE_PORTS=1 make baas-zap
make baas-down

# 3. Avant release : tag + push + smoke
make version VERSION=v1.2.3
```

---

## 22. CI ↔ local

Tout ce qui tourne en local tourne aussi en CI (mêmes scripts) :

| Workflow | Lance |
|---|---|
| `.github/workflows/colleague-docker-pipeline.yml` | `make up` puis `make healthcheck` |
| `.github/workflows/mini-baas-security.yml` | 7 jobs : Semgrep, npm/pnpm audit (matrix), Snyk, Trivy fs+image, TruffleHog, ZAP, security-gate |
| `.github/workflows/supply-chain.yml` | `pnpm install --frozen-lockfile --ignore-scripts` sur tous les workspaces |

Le gate `security-gate` du workflow `mini-baas-security.yml` agrège tous les
autres → un job rouge bloque le merge.

---

## 23. Liens utiles

- [README index](./README.md) — entrée dans la doc backend
- [milestones.md](./milestones.md) — état M1 → M9
- [security.md](./security.md) — stack sécurité détaillée
- [verify-and-test.md](./verify-and-test.md) — hiérarchie des tests
- [CHANGELOG.md](./CHANGELOG.md) — chronologie de tous les changements
- [agnostic-vs-incumbents.md](./agnostic-vs-incumbents.md) — comparatif Supabase / Firebase / etc.
- [services/](../../apps/baas/mini-baas-infra/src/apps/) — README détaillé par service
