# M11 — External application integration (tenant onboarding)

**Targets:** dimensions **b** (federation), **d** (unified API), **e** (security).
**Gate:** `make baas-verify-m11` returns `0`.
**Estimated effort:** 2-3 days.
**Risk:** medium — touches authn, tenant isolation, schema discovery.
**Depends on:** M1 (`IDatabaseAdapter`), M2 (engines + adapter-registry), M5 (Vault), M9 (centralized ABAC — recommended).

---

## Use case

Une **application externe** existe déjà, avec son propre back-end et ses
propres bases de données (PostgreSQL + MongoDB). Cette équipe veut :

1. **Garder leur back-end** — ne pas migrer leurs données.
2. **Utiliser le UI Osionos** comme dashboard / Notion-like sur leurs données.
3. **Écrire et lire** depuis Osionos vers leurs bases (CRUD bidirectionnel).
4. **Bénéficier de la sécurité** d'Osionos (ABAC, audit, rate-limit, WAF) sans
   ré-implémenter.

C'est le scénario "Osionos as a BaaS" : leur app devient un **tenant** du
backend Osionos, et leurs DBs deviennent des **resources** enregistrées.

---

## Deux architectures possibles (et pourquoi on en recommande une)

### Option A — Tenant sur le BaaS Osionos partagé (RECOMMANDÉ)

L'application externe est un tenant parmi d'autres sur l'instance Osionos.
Ses DBs sont enregistrées via `adapter-registry` ; le query-router parle
directement à leurs PG/Mongo via les adapters M2 existants.

```
External app's users
        │
        ▼
  Osionos UI (osionos webapp, partagée)
        │
        ▼
  Osionos Kong (WAF + JWT + rate-limit)
        │
        ▼
  Osionos query-router  ──►  adapter-registry  ──►  External app's PG / Mongo
        │                          │
        ▼                          ▼
  Osionos audit_log         Encrypted creds (AES-256-GCM)
  Osionos ABAC decision     in Osionos's tenant_databases
```

**Avantages**
- Zero infra à déployer côté application externe — juste enregistrer leurs
  DBs et c'est fini.
- Sécurité unique (ABAC + audit + WAF) gérée par Osionos.
- L'app externe garde le contrôle de ses DBs ; elle peut révoquer
  l'enregistrement à tout moment.
- Cohérence avec l'archi M1-M9 sans rien réécrire.

**Inconvénients**
- Latence réseau : Osionos → leur PG/Mongo passe par Internet
  (sauf si déploiement co-localisé).
- L'app externe doit accepter qu'Osionos voie ses connection strings
  (chiffrées, mais visibles aux ops Osionos).

### Option B — Mini-BaaS sidecar côté application externe

Un sous-ensemble du BaaS Osionos (Kong + adapter-registry + query-router +
realtime-agnostic) est déployé en sidecar de l'application externe, et
fédère "vers le haut" avec l'Osionos central pour le UI + auth.

```
External app's PG/Mongo  ◄─── Mini-BaaS sidecar ◄─── External app
                                  │
                                  │ (federation HTTP)
                                  ▼
                          Osionos BaaS central
                          (UI, auth, ABAC policies)
```

**Avantages**
- Latence DB minimale (DBs et BaaS sur le même réseau).
- Connection strings ne quittent jamais le réseau de l'app externe.
- L'app externe garde la souveraineté complète.

**Inconvénients**
- Beaucoup plus d'infra à déployer (5-7 containers minimum).
- Le pattern de fédération inter-BaaS n'existe pas encore (chantier de M12+).
- Plus complexe à debugger.

**Verdict** : on livre Option A en M11. Option B reste un papier pour
plus tard si une équipe le demande.

---

## Comment ça marche concrètement — le parcours utilisateur

### Étape 0 — Pré-requis côté application externe

L'app externe doit fournir à un **admin Osionos** :

1. Les `connection_string` de ses bases (URI complète) :
   - `postgresql://app_readonly_user:***@external-app.example.com:5432/appdb`
   - `mongodb://app_readonly_user:***@external-app.example.com:27017/appdb`
2. Optionnellement un user PG / Mongo avec des permissions **scope-limitées**
   (par exemple lecture seule sur certaines tables, écriture sur d'autres).
3. Un identifiant d'organisation (qui devient leur `tenant_id` côté Osionos).

> **Best practice** : créer un user dédié `osionos_bridge` côté l'app externe,
> avec uniquement les `GRANT SELECT, INSERT, UPDATE, DELETE` sur les
> schémas/collections qu'on accepte d'exposer. L'app garde le contrôle —
> Osionos ne fait jamais de `DROP TABLE` ou de `GRANT`.

### Étape 1 — Provisioning du tenant côté Osionos (admin one-shot)

L'admin Osionos lance :

```bash
make baas-tenant-onboard \
  TENANT_NAME="external-app" \
  TENANT_OWNER_EMAIL="admin@external-app.example.com" \
  TENANT_PG_URL="postgresql://app_readonly_user:***@external-app.example.com:5432/appdb" \
  TENANT_MONGO_URL="mongodb://app_readonly_user:***@external-app.example.com:27017/appdb"
```

Ce que ça fait derrière :

1. **Crée un tenant** dans `auth.tenants` (nouvelle table M11).
2. **Crée un workspace Osionos** dédié à ce tenant, avec l'email du owner.
3. **Enregistre les 2 DBs** dans `tenant_databases` via `adapter-registry` :
   - chiffrement AES-256-GCM des connection strings (déjà en place M2),
   - tags `engine`, `name`, `tenant_id`.
4. **Introspecte les schémas** via `schema-service` :
   - liste les tables PG (`information_schema.tables`),
   - liste les collections Mongo (`db.listCollections()`),
   - matérialise une ligne `schema_registry` par resource avec ses colonnes
     / champs détectés (les types JSONB stockés inline).
5. **Émet un token de bridge** à l'owner pour qu'il puisse se connecter
   au UI Osionos et voir ses resources.

### Étape 2 — Première connexion utilisateur

Le owner de l'app externe :
1. Suit le lien magic-link envoyé par `email-service`.
2. Atterrit sur `https://osionos.example.com/?bridge_token=...`.
3. La SPA Osionos consomme le token via `/api/auth/bridge/consume` (déjà
   en place côté `auth-gateway.mjs`).
4. Se retrouve avec une session active dans son workspace, qui liste
   automatiquement ses tables PG + collections Mongo comme **resources**
   navigables.

### Étape 3 — Construction du dashboard

Dans le UI Osionos :
1. L'utilisateur crée une page Osionos.
2. Insère un bloc `/database` ou `/dashboard`.
3. Sélectionne une `resource` depuis sa liste (= une table/collection
   externe enregistrée).
4. Configure les colonnes à afficher, les filtres, le tri.
5. Le bloc se rafraîchit en temps réel quand la donnée change côté l'app
   externe (via le realtime-agnostic qui watch les WAL/change streams si
   l'app externe les expose, sinon via polling — choix à la registration).

### Étape 4 — Écriture depuis Osionos

Quand l'utilisateur crée/édite une ligne depuis le UI :
1. Le client Osionos appelle `POST /query/v1/{dbId}/tables/{table}` avec
   `{op: 'insert', data: {...}}`.
2. Kong vérifie le JWT, propage `X-User-Id` / `X-User-Email` /
   `X-User-Role` / `X-Tenant-Id`.
3. **AuditInterceptor** écrit l'événement dans `audit_log` avec request_id.
4. **ABAC** (M9) vérifie que l'utilisateur a la permission `insert` sur
   ce `(tenant_id, resource)` couple. Si non, 403.
5. **query-router** récupère la connection chiffrée depuis
   `adapter-registry`, déchiffre via AES-GCM, dispatche à l'adapter
   `postgresql` ou `mongodb`.
6. L'adapter exécute l'INSERT dans la DB de l'app externe avec
   `owner_id` / `tenant_id` injectés.

---

## Deliverables

### 1. Migration `030_tenants.sql`

Nouvelle table `auth.tenants` + colonne `tenant_id` ajoutée à
`tenant_databases` + `osionos_workspaces` :

```sql
-- File: scripts/migrations/postgresql/030_tenants.sql
BEGIN;

CREATE TABLE IF NOT EXISTS auth.tenants (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name         TEXT UNIQUE NOT NULL,
  owner_email  TEXT NOT NULL,
  status       TEXT NOT NULL DEFAULT 'active'
               CHECK (status IN ('active', 'suspended', 'deleted')),
  metadata     JSONB DEFAULT '{}'::jsonb,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.tenant_databases
  ADD COLUMN IF NOT EXISTS tenant_uuid UUID REFERENCES auth.tenants(id) ON DELETE CASCADE;

ALTER TABLE public.osionos_workspaces
  ADD COLUMN IF NOT EXISTS tenant_uuid UUID REFERENCES auth.tenants(id) ON DELETE SET NULL;

-- RLS : a user only sees their tenant's data
ALTER TABLE auth.tenants ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenants_self_read ON auth.tenants
  FOR SELECT TO authenticated
  USING (
    id IN (
      SELECT tenant_uuid FROM public.osionos_workspace_members wm
      JOIN public.osionos_workspaces w ON w.id = wm.workspace_id
      WHERE wm.user_id::text = auth.uid()
    )
  );

INSERT INTO public.schema_migrations (version, name)
  VALUES (30, '030_tenants') ON CONFLICT (version) DO NOTHING;
COMMIT;
```

### 2. Service `tenant-onboarding` (NestJS)

Nouveau service NestJS sous `src/apps/tenant-onboarding/` qui expose :

```
POST /tenants/onboard
  body: { name, owner_email, databases: [{engine, name, connection_string}] }
  →    creates auth.tenants row,
       calls adapter-registry to register each DB (encrypted),
       calls schema-service to introspect each registered DB,
       creates osionos workspace,
       emits magic-link via email-service,
       returns { tenant_id, workspace_id, bridge_url }
```

Le service utilise les briques existantes (adapter-registry, schema-service,
email-service) — il ne fait que **orchestrer**. Pas de nouvelle logique de
chiffrement / introspection — tout est déjà fait par les services M2.

### 3. Endpoint d'introspection schema

Étendre `schema-service` :

```
GET /schemas/by-tenant/:tenant_id
  →  returns [{resource_id, engine, name, columns, last_introspected_at}]
```

Ce que le UI Osionos consomme pour afficher la liste des resources
disponibles dans le workspace du tenant.

### 4. Champ `tenant_id` dans le JWT

Quand un user se connecte via le bridge-token, le JWT émis par GoTrue
doit contenir le claim `tenant_id` (ajouté en custom claim).

Pour l'instant on triche : on lit `tenant_id` depuis la table
`osionos_workspace_members` à chaque AuthGuard. Plus tard (M11.b) on
l'inscrira dans le JWT pour éviter le round-trip.

### 5. ABAC policies pour les resources tenant

Seed dans la migration : pour chaque tenant, créer automatiquement les
policies :

```sql
-- Members of a workspace can CRUD only their tenant's resources
INSERT INTO public.resource_policies
  (role_id, resource_type, resource_name, actions, conditions, effect, priority)
SELECT r.id, 'tenant_database', '*',
       ARRAY['select','insert','update','delete'],
       jsonb_build_object('tenant_uuid', $TENANT_UUID),
       'allow', 0
FROM public.roles r WHERE r.name = 'user';
```

Le `permission-engine` évalue ces conditions pour chaque requête (M9).

### 6. UI Osionos — "Bridge resources" sidebar section

Le client (osionos webapp) doit :
1. Au mount du workspace, appeler `GET /schemas/by-tenant/:tenant_id`.
2. Afficher les resources sous une nouvelle section "External data"
   dans la sidebar.
3. Quand un user drag-and-drop une resource dans une page, créer un bloc
   `/database` configuré pour cette resource.

### 7. Realtime sur resources externes

Si l'app externe expose son WAL PG ou ses change streams Mongo,
`realtime-agnostic` peut les watcher. Sinon, fallback polling toutes les
N secondes (configurable à la registration via `metadata.realtime.mode`).

### 8. Gate `make baas-verify-m11`

```bash
#!/usr/bin/env bash
# scripts/verify/m11-tenant-integration.sh

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
BAAS_DIR="apps/baas/mini-baas-infra"

step "checking 030_tenants migration"
[[ -f "${BAAS_DIR}/scripts/migrations/postgresql/030_tenants.sql" ]] || fail "030_tenants.sql missing"
grep -q "auth.tenants" "${BAAS_DIR}/scripts/migrations/postgresql/030_tenants.sql" || fail "table not declared"
pass "030_tenants.sql is well-formed"

step "checking tenant-onboarding service"
[[ -d "${BAAS_DIR}/src/apps/tenant-onboarding" ]] || fail "tenant-onboarding service missing"
grep -q "POST.*tenants/onboard" "${BAAS_DIR}/src/apps/tenant-onboarding/src"/**/*.ts 2>/dev/null || fail "/tenants/onboard route not exposed"
pass "tenant-onboarding service exposes /tenants/onboard"

step "checking schema-service /schemas/by-tenant"
grep -rq "by-tenant" "${BAAS_DIR}/src/apps/schema-service/src" || fail "/schemas/by-tenant endpoint missing"
pass "schema-service exposes per-tenant introspection"

if [[ "${1:-}" == "--live" ]]; then
  # Round-trip: onboard a fake tenant, register a sample PG DB, expect a
  # resource list to come back, write one row, read it back.
  …
fi

green "[M11] OK"
```

### 9. Makefile target

```make
baas-verify-m11: baas-verify-m9
## Verify M11 external app integration (tenant onboarding, schema introspection, bridge UI).
	@$(BAAS_PORT_OVERRIDES) bash $(BAAS_VERIFY_DIR)/m11-tenant-integration.sh $(BAAS_VERIFY_FLAGS)

baas-tenant-onboard:
## One-shot onboarding of an external app as an Osionos tenant.
## Required: TENANT_NAME, TENANT_OWNER_EMAIL, TENANT_PG_URL or TENANT_MONGO_URL (at least one).
	@bash apps/baas/mini-baas-infra/scripts/tenant-onboard.sh
```

---

## Security model — récap

| Surface | Mécanisme | Couche |
|---|---|---|
| Authentification de l'app externe | API key (Kong key-auth) OR OAuth2 client-credentials | Kong |
| Authentification des utilisateurs de l'app | GoTrue magic-link + bridge-token | GoTrue + auth-gateway |
| Chiffrement des connection strings | AES-256-GCM, master key dans Vault | adapter-registry |
| Isolation tenant | RLS sur `auth.tenants`, `tenant_databases`, `osionos_workspaces` ; ABAC policy `tenant_uuid = current` | PostgreSQL RLS + permission-engine |
| Autorisation par resource | ABAC policies sur `(role, resource_type, actions, conditions)` | permission-engine (M9) |
| Audit | AuditInterceptor écrit chaque mutation dans `audit_log` avec `tenant_uuid` + `request_id` | libs/common (déjà en place) |
| Rate limit par tenant | Kong rate-limit avec `limit_by: consumer` + un Kong consumer par tenant | Kong |
| Révocation | UPDATE `tenant_databases.status = 'revoked'` → query-router rejette immédiatement | adapter-registry |

---

## What this enables — exemples concrets

### Exemple 1 — App de gestion RH

Une app RH externe expose ses tables `employees`, `contracts`, `leaves` en PG.
Le DRH se connecte à Osionos, voit ses 3 tables comme resources, crée une
page "Dashboard équipe" avec :
- un bloc database `employees` filtré par département,
- un bloc kanban `leaves` regroupé par statut,
- un bloc chart `contracts` en histogramme par mois d'embauche.

Quand quelqu'un édite une ligne dans Osionos, c'est écrit directement
dans la DB de l'app RH. L'app RH continue à fonctionner normalement —
elle voit juste qu'on a ajouté un canal de lecture/écriture.

### Exemple 2 — App e-commerce avec catalogue Mongo

Une plateforme e-commerce stocke ses `products` en Mongo (schéma souple)
et ses `orders` en PG (transactionnel). Le merchandiser se connecte à
Osionos, voit les 2 resources malgré leurs engines différents. Il crée
une vue qui joint visuellement les 2 (Osionos fait l'aggregation côté
client via le SDK, ou demande à Trino de faire un JOIN cross-engine en
read-only).

### Exemple 3 — App SaaS qui veut un dashboard sans coder

Une startup B2B veut donner à ses clients un dashboard custom sur leurs
données. Au lieu de coder un dashboard maison, ils onboardent leur PG
comme tenant Osionos. Chaque client a son workspace, voit ses propres
données, peut construire ses propres dashboards. La startup ne maintient
plus que sa logique métier — Osionos gère la couche présentation +
permissions + audit.

---

## Limites assumées (à acter avant de promettre)

- **Latence réseau** entre Osionos et la DB de l'app externe. Si elles
  sont sur des continents différents, ajouter 100-300 ms par requête.
  Mitigation : déployer une instance Osionos régionale, ou cache
  applicatif côté query-router.
- **Schéma drift** : si l'app externe `ALTER TABLE`, Osionos doit
  ré-introspecter. M11 inclut un job `schema-refresh` qui tourne toutes
  les 6h ; M11.b ajoutera des webhooks DDL pour refresh instantané.
- **Pas de migrations Osionos sur la DB externe**. Osionos ne fait
  jamais de DDL sur les DBs des tenants. Si un user veut une nouvelle
  colonne, c'est à l'app externe de la créer.
- **Pas de cohérence ACID cross-tenant**. Une transaction PostgreSQL
  reste locale à la DB d'un seul tenant. Pour du cross-tenant
  consistency, on parle de saga (M8) — pas couvert par M11.

---

## Done when

- `make baas-verify-m11` exit 0 (static + live).
- Un admin Osionos peut onboarder un tenant avec une seule commande make.
- Le tenant onboardé peut se connecter au UI, voir ses resources, et
  écrire/lire depuis le UI vers ses propres DBs.
- ABAC bloque toute tentative d'un user d'un tenant A d'accéder aux
  resources d'un tenant B (cross-tenant denial).
- Audit log montre chaque mutation avec `tenant_uuid` + `request_id` +
  `actor_id`.
- Documenter le parcours dans [`wiki/back/CHANGELOG.md`](../back/CHANGELOG.md)
  section "M11".

---

## Out of scope (M11.b ou plus tard)

- **Webhook DDL refresh** (M11.b) : aujourd'hui c'est polling 6h, demain
  push instantané.
- **Mini-BaaS sidecar** (M12) : Option B ci-dessus, pour les tenants qui
  veulent garder leur DB on-prem strict.
- **Billing & quotas** : combien de queries un tenant peut faire par mois.
- **Self-service onboarding UI** : aujourd'hui c'est un Make target
  admin ; demain un workflow signup où l'app externe se onboarde elle-même.
- **Fédération inter-Osionos** : 2 instances Osionos qui se branchent
  l'une sur l'autre. Existe en théorie via M7 HttpEngine + adapter
  pointant sur la 2e Osionos, mais pas testé.
