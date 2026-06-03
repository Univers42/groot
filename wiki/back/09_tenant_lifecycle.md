# 09 — Tenant Lifecycle

Until migration 032 the BaaS had no central tenant registry — `tenant_id`
was a free-form TEXT scattered across every table. This page covers the
new tenant-control Go service that owns onboarding, API keys, and
verification.

Lives in `apps/baas/mini-baas-infra/go/control-plane/cmd/tenant-control/`
(binary) + `internal/tenants/` (logic). HTTP API on `:3022`.

## Identity model

```
external client ──X-Baas-Api-Key──► query-router (ApiKeyMiddleware)
                                         │
                                         ▼
                                  tenant-control /v1/keys/verify
                                         │
                                         ▼
                                  X-Baas-Tenant-Id header injected
                                         │
                                         ▼
                                  signed envelope to data plane
```

Three auth modes coexist (in priority order):

1. **Signed envelope** (`X-Baas-Tenant-Id` already set by the gateway/Kong).
   ApiKeyMiddleware is a no-op — gateway is trusted to have already
   verified the JWT or service-token.
2. **API key** (`X-Baas-Api-Key: mbk_…`). Middleware calls
   `tenant-control /v1/keys/verify`, materialises tenant headers from
   the response, downstream proceeds as if a signed envelope was present.
3. **Anonymous** (neither). Downstream auth guard rejects with 401.

## Tables (migration 032)

`public.tenants` extends a pre-existing UUID-keyed table:

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | internal PK, referenced by `apps`, `projects` FKs |
| `slug` | TEXT UNIQUE | **what the public API uses as the tenant id** |
| `name` | TEXT | human-readable |
| `status` | TEXT | `active` / `suspended` / `deleted` |
| `plan` | TEXT | `free` / `pro` / `enterprise` |
| `owner_user_id` | TEXT | GoTrue auth.users.id (no FK; auth lives in separate schema) |
| `metadata` | JSONB | tenant-defined |

`public.tenant_api_keys`:

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `tenant_id` | UUID | FK to `tenants.id` |
| `name` | TEXT | unique per tenant (partial: only for non-revoked) |
| `key_prefix` | TEXT | 12 chars, indexed — look up candidates by prefix |
| `key_hash` | TEXT | argon2id, salt-derived-from-prefix |
| `scopes` | TEXT[] | `['read','write']` default |
| `expires_at` | TIMESTAMPTZ | optional |
| `revoked_at` | TIMESTAMPTZ | set by DELETE; partial-unique constraint allows re-creation |

## API surface

All mutation endpoints require `X-Service-Token: $INTERNAL_SERVICE_TOKEN`.

### Tenants

```http
POST   /v1/tenants                     create
GET    /v1/tenants                     list (admin)
GET    /v1/tenants/:slug               fetch (self or admin)
PATCH  /v1/tenants/:slug               update name/plan/status/metadata
DELETE /v1/tenants/:slug               soft-delete (status='deleted')
```

```sh
curl -X POST http://localhost:3022/v1/tenants \
  -H "X-Service-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "id": "t-acme",
    "name": "Acme Corp",
    "plan": "pro",
    "owner_user_id": "u-123"
  }'
```

### Bootstrap (one-call provisioning)

```http
POST /v1/tenants/:slug/bootstrap?name=Acme%20Corp
  { "owner_user_id": "u-123", "default_key_name": "primary" }
```

Returns:

```json
{
  "tenant": { "id": "t-acme", "uuid": "97f1…", "name": "Acme Corp", … },
  "api_key": {
    "id": "ed2d…", "tenant_id": "t-acme", "name": "primary",
    "key_prefix": "i3kufwek2ecd", "scopes": ["read","write","admin"],
    "key": "mbk_i3kufwek2ecd_cifgzpru…"
  },
  "roles": []
}
```

`api_key.key` is the **cleartext key**, returned ONCE. Store it on first
receipt — subsequent reads only expose `key_prefix`.

`roles: []` is intentional today — the permission system uses globally-
unique role names that don't fit per-tenant seeding without an HTTP
roundtrip to permission-engine. Seed roles separately via the existing
permission-engine API for now.

### API keys

```http
POST   /v1/tenants/:slug/keys          issue (returns full key once)
GET    /v1/tenants/:slug/keys          list (redacted — no hashes/keys)
DELETE /v1/tenants/:slug/keys/:keyId   revoke (sets revoked_at)
POST   /v1/keys/verify                 gateway-internal: cleartext -> identity
```

### Verify response

```json
{
  "valid": true,
  "tenant_id": "t-acme",
  "key_id": "ed2d…",
  "scopes": ["read", "write", "admin"]
}
```

Or on failure:

```json
{ "valid": false, "reason": "no_match" }     // wrong key
{ "valid": false, "reason": "expired" }      // past expires_at
{ "valid": false, "reason": "invalid_format" }
```

## API key format

```
mbk_<prefix>_<payload>
    └──┬───┘ └───┬───┘
       │        │
       │        └─ 32 chars base32 (lowercase, no padding)
       │           argon2id-hashed at rest; salt = "mbk-v1-" + prefix
       │
       └─ 12 chars base32, indexed for fast lookup, stored in cleartext
          for searchability. Acts as the salt for the hash so the same
          payload yields different stored hashes per key.
```

Total length: 49 chars (`mbk_` + 12 + `_` + 32). The prefix gives O(1)
candidate lookup; the verify path runs argon2 only on at most one row.

## Query-router integration

`@mini-baas/common` ships `ApiKeyMiddleware`. The query-router registers
it before all routes (in `app.module.ts`). It:

1. Picks up `X-Baas-Api-Key` (or `apikey` for compat).
2. Skips if `X-Baas-Tenant-Id` is already set (signed envelope wins).
3. Calls `TENANT_CONTROL_URL/v1/keys/verify` with the cleartext key +
   `INTERNAL_SERVICE_TOKEN`. Result is cached in-process for 30s.
4. On `valid: true`, sets `X-Baas-Tenant-Id`, `X-Baas-User-Id`
   (`api-key:<key uuid>`), `X-Baas-Scopes`.
5. On `valid: false`, returns 401.

## Config

| Env | Default | Used by |
|---|---|---|
| `TENANT_CONTROL_URL` | `http://tenant-control:3022` | query-router middleware |
| `INTERNAL_SERVICE_TOKEN` | shared with adapter-registry | tenant-control + query-router |
| `API_KEY_VERIFY_TIMEOUT_MS` | `2000` | middleware HTTP timeout |
| `TENANT_CONTROL_PORT` | `3022` | service listen port |

## Signup → first request (GoTrue auto-provision)

The full self-serve onboarding loop is wired as of migration 033:

```
POST /signup (GoTrue)
   │
   │ INSERT auth.users
   ▼
[trigger] auto_provision_tenant
   │
   │ INSERT public.tenants (slug=t-<uuid no dashes>, owner_user_id=<uuid>)
   ▼
GoTrue returns JWT
   │
   │ Bearer <jwt>
   ▼
POST /v1/tenants/me/bootstrap (tenant-control)
   │
   │ JWT.sub → find tenant by owner_user_id → issue first API key
   ▼
{ tenant: {...}, api_key: { key: "mbk_..." } }       ← key returned ONCE
```

### `/v1/tenants/me/bootstrap`

JWT-authenticated. Optional body: `{ "default_key_name": "primary" }`.

```sh
JWT=$(curl -sS -X POST "http://localhost:8000/auth/v1/token?grant_type=password" \
  -H "Content-Type: application/json" \
  -d '{"email":"u@example.com","password":"S3cretP@ss"}' | jq -r .access_token)

curl -sS -X POST http://localhost:3022/v1/tenants/me/bootstrap \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"default_key_name":"primary"}'
```

Idempotent: subsequent calls return `{ key_reuse: true }` without a new
cleartext key — clients must store the key on first receipt.

### Defensive path

The `BootstrapForUser` Go method does a find-or-create on the tenant
even if the trigger somehow didn't fire (race or migration-not-applied):

1. `SELECT … WHERE owner_user_id = sub`
2. If absent → `INSERT INTO tenants (slug = t-<sub-without-dashes>, …)`
3. Handle the conflict race (another caller raced us) by re-selecting

### Trigger function (migration 033)

`SECURITY DEFINER` so it runs as the migration owner — GoTrue's
connection doesn't need rights on `public.tenants`. Failures are
caught and logged as `WARNING` so signup never breaks because of a
provisioning issue.

```sql
CREATE OR REPLACE FUNCTION public._auto_provision_tenant_from_auth_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
  v_slug TEXT := 't-' || replace(NEW.id::text, '-', '');
  v_name TEXT := COALESCE(NULLIF(NEW.raw_user_meta_data->>'name', ''),
                          NULLIF(NEW.email, ''), v_slug);
BEGIN
  INSERT INTO public.tenants (slug, name, owner_user_id, ...)
  VALUES (v_slug, v_name, NEW.id::text, ...)
  ON CONFLICT (slug) DO NOTHING;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'auto-provision tenant failed for user %: %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$fn$;
```

### JWT verifier config

`tenant-control` reads the shared HS256 secret from `GOTRUE_JWT_SECRET`
(or `JWT_SECRET` as fallback) and optionally pins issuer via
`GOTRUE_JWT_ISSUER`. Algorithm is pinned to HS256 — `alg=none` and
RS256/HS256 confusion attacks are rejected.

If neither secret env is set, `/v1/tenants/me/bootstrap` returns 501.

### Verified end-to-end behaviour

| Test | Result |
|---|---|
| Signup → trigger fires → tenants row exists with `auto_provisioned: true` | ✓ |
| `/me/bootstrap` with valid JWT → 200 + tenant + cleartext key | ✓ |
| Second `/me/bootstrap` → 200 + `key_reuse: true` (no new key) | ✓ |
| Use returned key against query-router → 200 + engines list | ✓ |
| `/me/bootstrap` anonymous → 401 | ✓ |
| `/me/bootstrap` with tampered JWT → 401 invalid signature | ✓ |

## Limitations / TODO

- **GOTRUE_MAILER_AUTOCONFIRM=true required** in environments without
  an SMTP server. Without autoconfirm GoTrue tries to send a confirmation
  email; if `mailpit` (or the configured SMTP host) is unreachable, signup
  rolls back. Production deployments should always wire real SMTP.
- **No role seeding.** `bootstrap.seed_roles` is accepted but ignored
  pending an HTTP integration with permission-engine.
- **No quota enforcement.** Plan field is stored but not consulted by
  rate-limiters or admission control.
- **Key cache TTL** is 30s in-process — multiple replicas don't share a
  cache so key revocation can take up to 30s to propagate per replica.
  Acceptable for the security model; switch to a Redis cache if you
  want sub-second revocation.

## Testing it locally

```sh
TOKEN=$(grep ADAPTER_REGISTRY_SERVICE_TOKEN .env | cut -d= -f2)

# 1. Bootstrap a tenant
curl -X POST "http://localhost:3022/v1/tenants/t-demo/bootstrap?name=Demo" \
  -H "X-Service-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"owner_user_id":"u-demo","default_key_name":"primary"}'
# -> save the .api_key.key field

# 2. Use the key
KEY=mbk_...
docker run --rm --network mini-baas_mini-baas curlimages/curl:latest \
  -H "X-Baas-Api-Key: $KEY" http://query-router:4001/engines
# -> 200 with engines list
```
