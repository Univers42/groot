# adapter-registry

**Port interne** : `3020` · **Container** : `mini-baas-adapter-registry` · **Profile** : `adapter-plane`

Catalogue **tenant-scoped** des bases de données enregistrées. Quand un user
veut connecter sa propre PostgreSQL / MongoDB / MySQL / Redis / HTTP API, il
appelle cette API. Le service chiffre la `connection_string` en **AES-256-GCM**
(`authTagLength: 16`) avant de la stocker.

## Ce qu'il fait

- `POST /databases` : enregistre un moteur (engine + connection_string)
- `GET /databases` : liste les DBs du user courant
- `GET /databases/:id/connect` : retourne la `connection_string` **déchiffrée** (réservé aux services internes via `X-Service-Token`)
- `DELETE /databases/:id` : retire la DB du catalogue
- Pour M6+ : enregistre les **FDW aliases** (`register_fdw_foreign_table` côté PG)

## Endpoints

| Méthode | Route | Description |
|---|---|---|
| `GET` | `/health/live` · `/health/ready` | Probes liveness/readiness |
| `POST` | `/databases` | Enregistre une DB ; body `{ engine, name, connection_string, register_via_fdw? }` |
| `GET` | `/databases` | Liste les DBs accessibles à `X-User-Id` |
| `GET` | `/databases/:id` | Metadata d'une DB (sans connection_string) |
| `GET` | `/databases/:id/connect` | Retourne la connection_string déchiffrée — **réservé internal** |
| `DELETE` | `/databases/:id` | Supprime la DB du catalogue |
| `GET` | `/docs` · `/docs-json` | OpenAPI Swagger |

## Sécurité

- **AES-256-GCM** pour chiffrer `connection_string` (clé dérivée via scrypt à partir de `ADAPTER_REGISTRY_KEY` de Vault)
- **Tag d'authentification** explicitement 16 bytes (`authTagLength: 16`) — fix Semgrep
- La connection_string n'est **jamais** retournée par `GET /databases` ou `GET /databases/:id` — seulement par `/connect`, qui exige `X-Service-Token`
- Le `X-User-Id` est extrait de la JWT par Kong et propagé en header — chaque row est `owner_id = X-User-Id`, isolation enforced via PG RLS

## Comment l'invoquer

### Via le SDK

```ts
const db = await client.adapters.register({
  engine: 'mysql',
  name: 'production-mysql',
  connection_string: 'mysql://user:pass@host:3306/db'
});
console.log(db.id); // → uuid, à passer à query-router
```

### Via Kong (curl)

```bash
curl -ksS -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  "https://localhost:18443/databases" \
  -d '{"engine":"mysql","name":"demo","connection_string":"mysql://user:pass@mysql:3306/demo"}'
```

### Via `docker compose exec` (debug)

```bash
docker compose -f apps/baas/mini-baas-infra/docker-compose.yml exec -T adapter-registry \
  node --input-type=module -e "
    const r = await fetch('http://127.0.0.1:3020/databases', {
      method: 'POST',
      headers: { 'Content-Type':'application/json', 'X-User-Id':'$USER_ID', 'X-User-Role':'authenticated' },
      body: JSON.stringify({ engine:'redis', name:'demo-redis', connection_string:'redis://redis:6379' })
    });
    console.log(await r.text());
  "
```

## Dépendances

- **Postgres** : table `public.databases` (uuid, owner_id, engine, name, connection_string_encrypted)
- **Vault** : `ADAPTER_REGISTRY_KEY` (clé AES-256)
- **permission-engine** : décisions ABAC sur `engine:*` (M9)
- (M6+) **PostgreSQL FDW extensions** : `register_via_fdw=true` provisionne un FOREIGN TABLE

## Gates qui le couvrent

- **M1** : table `databases`, encrypt/decrypt symétrique
- **M2** : engines `'mysql'`, `'redis'`, `'http'` acceptés par CHECK constraint (migration 014)
- **M6** : `register_via_fdw` + `registerFdwAlias()` (créer un FOREIGN TABLE côté PG)
- **M11** : `tenant_id` filtré + ABAC policy par tenant

## Variables d'env clés

| Variable | Effet |
|---|---|
| `PORT` | Port d'écoute (default 3020) |
| `DATABASE_URL` | Pool PG |
| `ADAPTER_REGISTRY_KEY` | Clé AES-256 (chargée depuis Vault au boot) |
| `PERMISSION_ENGINE_URL` | URL du permission-engine pour ABAC |
| `ADAPTER_REGISTRY_SERVICE_TOKEN` | Token sortant (utilisé par query-router pour `/connect`) |
