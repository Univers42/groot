# storage-router

**Port interne** : `3040` · **Container** : `mini-baas-storage-router` · **Profile** : `storage`

Signeur d'URLs pré-signées pour le stockage objet (MinIO S3-compatible).
Pas de proxy de payload — le client reçoit une URL signée et upload/download
**directement** depuis MinIO (économie de bande passante + chiffrement TLS
end-to-end).

## Ce qu'il fait

- `POST /sign/:bucket/*` : génère une URL signée (PUT/GET) avec TTL
- Vérifie via ABAC que `X-User-Id` a bien `bucket:write` ou `bucket:read`
- Tag chaque URL signée avec `x-amz-meta-owner-id` pour audit ultérieur côté MinIO

## Endpoints

| Méthode | Route | Description |
|---|---|---|
| `GET` | `/health/live` · `/health/ready` | Probes |
| `POST` | `/sign/:bucket/*` | Signe une URL ; body `{ method: 'GET'\|'PUT', ttl_seconds }` |
| `GET` | `/docs` · `/docs-json` | OpenAPI |

## Comment l'invoquer

### Via le SDK

```ts
const { signedUrl, expiresAt } = await client.storage
  .bucket('uploads')
  .signPut('avatars/user-123.png', { ttlSeconds: 600 });
// Le client upload direct vers MinIO :
await fetch(signedUrl, { method: 'PUT', body: file });
```

### Via Kong

```bash
curl -ksS -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  "https://localhost:18443/storage/sign/uploads/avatars/user-123.png" \
  -d '{"method":"PUT","ttl_seconds":600}'
```

### Smoke test dédié

```bash
BASE_URL=http://localhost:18000 bash apps/baas/mini-baas-infra/scripts/phase9-storage-operations-test.sh
```

## Dépendances

- **MinIO** (port interne 9000, console 9001)
- **permission-engine** : ABAC sur `bucket:read` / `bucket:write`
- **Postgres** : audit_log

## Gates qui le couvrent

- **M1** : audit interceptor, OpenAPI, healthcheck
- **M3** : idempotency middleware appliqué (re-sign idempotent par `Idempotency-Key`)
- **M9** : ABAC fail-closed avant signature

## Variables d'env clés

| Variable | Effet |
|---|---|
| `PORT` | 3040 |
| `S3_ENDPOINT` | URL MinIO (interne `http://minio:9000`) |
| `S3_ACCESS_KEY` · `S3_SECRET_KEY` | Credentials MinIO (depuis Vault) |
| `S3_REGION` | Default `us-east-1` |
| `DATABASE_URL` | Pool PG (audit_log) |
| `PERMISSION_ENGINE_URL` | ABAC |
