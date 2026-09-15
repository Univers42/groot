# Module Manifest System

**Design goal**: make modularity safe by separating a non-disableable security kernel from optional feature modules, then generating gateway, Compose and SDK capabilities from manifests.

## Current State

The repo already has many independent services under `apps/baas/mini-baas-infra/src/apps`. Compose and Kong route them statically. That proves modular decomposition, but not product modularity: disabling a service still leaves stale routes unless YAML is edited by hand.

## Kernel Versus Modules

Security primitives are not modules. They are the kernel.

| Kernel, never disable | Optional feature module |
|---|---|
| WAF/Kong gateway | analytics-service |
| auth and signed identity | newsletter-service |
| tenant resolver | ai-service |
| query-router data plane | storage-router, if product tier disables storage |
| adapter-registry | realtime, if tenant does not need it |
| permission PDP/PEP | GDPR tooling UI, not GDPR deletion obligations |
| audit log | log viewer |
| idempotency ledger | dashboards |
| quotas/rate limits | email campaigns |
| outbox/saga kernel | optional producers/connectors |

If a tenant can disable the PDP, audit, idempotency or tenant isolation, the platform is not secure.

## Module Manifest

Each service/module should own a manifest:

```yaml
id: newsletter
kind: feature
service: newsletter-service
owner: platform
defaultEnabled: false
profiles: [background]
routes:
  - name: newsletter-api
    path: /newsletter/v1
    upstream: http://newsletter-service:3090
    auth: optional
    requiredScopes: [newsletter:write]
dependencies:
  services: [email-service]
  stores: [postgres]
config:
  NEWSLETTER_FROM:
    required: true
    secret: false
capabilities:
  newsletter: true
quotas:
  monthlyCampaigns: plan.newsletterCampaigns
```

Kernel manifests use `kind: core` and cannot be disabled.

## Generated Artifacts

From enabled modules, generate:

| Artifact | Purpose |
|---|---|
| `kong.generated.yml` | routes only for enabled modules, no stale 502s |
| `docker-compose.modules.yml` | only needed services and dependencies |
| `.well-known/baas-capabilities` | tenant/project capability discovery |
| SDK capability catalog | typed client surface for enabled modules |
| Prometheus scrape config | scrape only running services |
| policy templates | module-specific ABAC actions/resources |

This turns module activation into a deterministic build step.

## Capability Discovery

Expose:

```http
GET /.well-known/baas-capabilities
```

Response:

```json
{
  "tenant_id": "...",
  "project_id": "...",
  "modules": {
    "query": { "enabled": true },
    "realtime": { "enabled": true, "replay": true },
    "newsletter": { "enabled": false },
    "ai": { "enabled": true, "providers": ["local", "openai-compatible"] }
  },
  "engines": {
    "postgresql": { "transactions": true, "stream": true },
    "mongodb": { "transactions": true, "stream": true }
  },
  "limits": {
    "maxRealtimeConnections": 100,
    "maxPoolSizePerDatabase": 10
  }
}
```

The SDK should read this and expose only enabled module clients at runtime. Type generation can still provide the full package, but runtime should return useful `module_disabled` errors.

## Per-Tenant Enablement

Store enabled modules per tenant/project:

```sql
tenant_modules (
  tenant_id uuid not null,
  project_id uuid not null,
  module_id text not null,
  enabled boolean not null,
  config jsonb not null default '{}',
  enabled_by uuid,
  enabled_at timestamptz,
  primary key (tenant_id, project_id, module_id)
)
```

Runtime services still exist at platform level, but authorization and routing decide whether a tenant can use them.

## Safe Disable Semantics

When a module is disabled:

- Gateway returns `404` or `501 module_disabled`, not upstream `502`.
- SDK capability discovery marks it disabled.
- Existing data is retained or archived according to module policy.
- Background jobs stop for that tenant.
- Quotas drop to zero for that module.
- Audit records the disable event.

## Config Schema

Module config should be typed and validated before deployment:

```yaml
configSchema:
  type: object
  required: [EMAIL_FROM]
  properties:
    EMAIL_FROM:
      type: string
      format: email
    CAMPAIGN_RATE_LIMIT:
      type: integer
      minimum: 1
```

Do not let tenants inject raw environment variables into platform containers. Store tenant module config in the control plane and pass only validated values to jobs.

## Migration Plan

1. Add `modules/` manifest directory under `apps/baas/mini-baas-infra`.
2. Write manifests for all current services.
3. Create a renderer script that outputs Kong and Compose overrides.
4. Add `/.well-known/baas-capabilities` endpoint in a small platform metadata service or query-router.
5. Change SDK boot to fetch capabilities once and cache with ETag.
6. Add verify gate: every Kong route must map to an enabled module or core service.
7. Add tenant module table and admin endpoints.

## Acceptance Criteria

- Disabling `ai-service` removes `/ai/v1` from generated gateway config or returns clean `module_disabled`.
- Security kernel modules cannot be disabled by tenant config.
- SDK capability discovery matches generated gateway routes.
- Prometheus scrape config does not point to disabled services.
- Enabling a module requires one manifest and no hand-editing of three YAML files.
