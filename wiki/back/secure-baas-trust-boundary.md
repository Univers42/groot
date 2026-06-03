# Trust Boundary And Identity Hardening

**Design goal**: no upstream service should trust caller-provided identity headers unless those headers are cryptographically bound to the gateway or the service has verified the JWT itself.

## Current State

The current identity flow is simple and works for a closed stack:

1. Kong protects most routes with the JWT plugin in [kong.yml](../../apps/baas/mini-baas-infra/docker/services/kong/conf/kong.yml).
2. A global pre-function decodes the JWT payload and injects `X-User-Id`, `X-User-Email`, `X-User-Role`.
3. Nest services read those headers in [auth.guard.ts](../../apps/baas/mini-baas-infra/src/libs/common/src/guards/auth.guard.ts).
4. Internal calls use `X-Service-Token` and `X-Tenant-Id` through [service-token.guard.ts](../../apps/baas/mini-baas-infra/src/libs/common/src/guards/service-token.guard.ts).

The gap is that upstream services trust raw headers. Inside the Docker network, any compromised service or future plugin container could call another service with `X-User-Id: victim` unless the upstream can verify that Kong produced the header.

## Target Invariant

Every request reaching a Nest service must carry one of:

1. A JWT that the service verifies directly.
2. A Kong-signed identity envelope verified by a shared rotating secret.
3. A service-to-service token with audience, tenant scope, expiration, and signature.
4. mTLS identity where the service validates the client certificate SAN.

Raw `X-User-Id` is never authoritative by itself.

## Recommended Default: Signed Identity Envelope

This is the best immediate fit because it preserves the current Kong-centered design and requires the fewest service changes.

Kong injects:

```http
X-Baas-Tenant-Id: <tenant uuid>
X-Baas-User-Id: <user uuid>
X-Baas-Role: authenticated
X-Baas-App-Id: <app/client id>
X-Baas-Issued-At: <unix ms>
X-Baas-Nonce: <random>
X-Baas-Signature: v1=<hmac-sha256 canonical headers>
```

Nest verifies:

1. Required headers exist.
2. Timestamp is within a short skew window, for example 30 seconds.
3. Nonce has not been seen recently for the same signature key.
4. HMAC validates against `INTERNAL_IDENTITY_HMAC_KEYS`, supporting key rotation by `kid`.
5. Tenant/user/app are written to `req.auth`, not scattered through raw headers.

## Canonical Signing String

Use a stable string to avoid signature bypasses:

```text
method=<HTTP method>\n
path=<raw path>\n
tenant=<tenant id>\n
user=<user id>\n
role=<role>\n
app=<app id>\n
iat=<unix ms>\n
nonce=<nonce>\n
body_sha256=<hex body hash>
```

For streaming and WebSocket upgrade routes, omit body hash or use `UNSIGNED-PAYLOAD` and bind the path plus query string.

## Service Guard Shape

Replace header-trusting guards with one common identity guard:

```ts
interface VerifiedRequestIdentity {
  tenantId: string;
  userId: string;
  appId: string;
  role: 'anon' | 'authenticated' | 'service_role';
  scopes: string[];
  authMethod: 'jwt' | 'kong-hmac' | 'service-token' | 'mtls';
}
```

The guard should populate `req.identity`, then deprecate `req.user`. Backwards compatibility can map `CurrentUser()` to `identity.userId` during migration, but new code must consume tenant-aware identity.

## Service-To-Service Tokens

The current `X-Service-Token` is global. Replace it with scoped service tokens:

| Field | Required property |
|---|---|
| `iss` | platform service issuer |
| `sub` | calling service name, for example `query-router` |
| `aud` | target service name, for example `adapter-registry` |
| `tenant_id` | required unless platform-wide maintenance scope |
| `scope` | narrow action, for example `connection:read` |
| `exp` | short TTL, 1-5 minutes |
| `jti` | replay prevention for critical calls |

This token can be a JWT signed by the internal key set, or a compact HMAC token recorded in a service-token table.

## API Keys And Tenant Keys

Public and server keys must be per tenant:

| Key | Intended location | Capabilities |
|---|---|---|
| Tenant anon key | Browser/mobile | tenant-bound, public routes, no bypass |
| Tenant user JWT | Browser/mobile | user-bound, tenant-bound, app-bound |
| Tenant service key | Server only | tenant-bound admin scopes, no cross-tenant access |
| Platform operator key | Platform admin only | break-glass, audited, never in tenant apps |

Never reuse one global `service_role` key for every tenant. A tenant leak must not become a platform leak.

## Network Boundary

Signed headers are still not a substitute for network hygiene:

- Put public services and internal services on separate Compose/Kubernetes networks.
- Only Kong/WAF should be reachable from outside.
- Use network policies in Kubernetes or Compose profiles for local isolation.
- Prefer mTLS for service-to-service traffic once the product leaves local Docker.
- Deny inbound traffic to data stores except from the services that need them.

## Migration Plan

1. Add `VerifiedIdentityGuard` in `libs/common` while keeping `AuthGuard` as a compatibility wrapper.
2. Add Kong HMAC signing pre-function and a static verification secret from Vault.
3. Change `CurrentUser()` or add `CurrentIdentity()` to expose `tenantId`, `userId`, `appId`.
4. Update adapter-registry, query-router, schema-service and permission-engine to require `tenantId` explicitly.
5. Reject raw `X-User-Id` in production mode.
6. Rotate away from global `X-Service-Token` to scoped internal tokens.

## Acceptance Criteria

- A direct request inside the Docker network with forged `X-User-Id` is rejected.
- A request through Kong with a valid JWT and signed identity reaches the service.
- A request with an expired or replayed identity envelope is rejected.
- Every audit log row records `tenant_id`, `user_id`, `app_id`, `auth_method`, and `request_id`.
- Verify script proves that routes without JWT plugin cannot produce trusted identity headers.
