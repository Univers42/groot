# Tenancy And Isolation Model

**Design goal**: separate customer tenancy from end-user identity, then enforce that separation in keys, control-plane rows, data routing, quotas, audit and realtime topics.

## Current State

The backend has a tenant table and API key table in [005_add_tenant_table.sql](../../apps/baas/mini-baas-infra/scripts/migrations/postgresql/005_add_tenant_table.sql). The adapter registry stores `tenant_databases` and has BYO database support in [databases.service.ts](../../apps/baas/mini-baas-infra/src/apps/adapter-registry/src/databases/databases.service.ts).

The product gap is semantic: many flows treat `tenant_id` as the same value as `userId`. That is acceptable for a personal demo, but not for a platform where one customer has many projects, many apps and many end users.

## Identity Taxonomy

Use distinct IDs everywhere:

| Identity | Meaning | Example |
|---|---|---|
| `tenant_id` | paying customer or organization | Acme Corp |
| `project_id` | isolated backend project under a tenant | Acme CRM prod |
| `app_id` | client app or integration | web dashboard, mobile app, worker |
| `user_id` | end-user inside the tenant app | Alice from Acme |
| `service_id` | platform or tenant-side server integration | acme-billing-worker |

Do not overload `user_id` as tenant. `owner_id` can remain a row ownership concept, but it is not tenancy.

## Isolation Tiers

The current `tenants.plan` enum can become a real isolation selector:

| Plan | Application data | Control-plane metadata | Use case |
|---|---|---|---|
| `free` | shared database, tenant-scoped schema or table prefix | shared control-plane with strict `tenant_id` RLS | hobby/dev apps |
| `pro` | dedicated schema per project or dedicated pool | shared control-plane with tenant partitions | production apps needing stronger blast-radius limits |
| `enterprise` | dedicated database or BYO database | dedicated control-plane DB optional | regulated customers |

BYO database should be the flagship isolation story. The platform should never need to co-mingle customer application rows when the customer chooses dedicated/BYO.

## Control-Plane Tables Need Tenant Scope

Every control-plane table must carry `tenant_id` unless it is truly global configuration:

- `tenant_api_keys`
- `tenant_databases`
- `schema_registry`
- `engine_schema_migrations`
- `roles`, `user_roles`, `resource_policies`
- `audit_log`
- `outbox_events`
- `fdw_external_resources`
- session, GDPR, newsletter, storage metadata tables

RLS policies should filter by `tenant_id` and only then by `user_id`/role. Current owner-only policies are useful as defense-in-depth, but tenant isolation must come first.

## Tenant-Aware Request Context

Every request should build this context before application code runs:

```ts
interface PlatformContext {
  tenantId: string;
  projectId: string;
  appId: string;
  userId?: string;
  serviceId?: string;
  role: string;
  scopes: string[];
  plan: 'free' | 'pro' | 'enterprise';
  isolation: 'shared-schema' | 'dedicated-schema' | 'dedicated-db' | 'byo-db';
}
```

This context drives ABAC, data routing, connection pool lookup, quotas, realtime topic prefixes, audit logging and module capability discovery.

## Database Registry Target Shape

`tenant_databases` should become project-scoped and policy-aware:

```sql
tenant_databases (
  id uuid primary key,
  tenant_id uuid not null,
  project_id uuid not null,
  engine text not null,
  name text not null,
  isolation_tier text not null,
  credential_ref text not null,
  capability_overrides jsonb not null default '{}',
  pool_policy jsonb not null default '{}',
  created_by uuid not null,
  created_at timestamptz not null default now(),
  last_healthy_at timestamptz
)
```

`credential_ref` should point to Vault or an envelope-encrypted tenant key record. Avoid returning raw connection strings across services when possible.

## Data Isolation Rules

1. A tenant cannot register or query a database not owned by its `tenant_id` and `project_id`.
2. Shared-schema data tables must include `tenant_id` and ideally `project_id`.
3. Dedicated schemas must be named from stable generated IDs, not tenant-provided names.
4. BYO/dedicated databases should be the default recommendation for production.
5. Query-router must not infer tenant from `userId`; it must receive verified `tenantId`.
6. Realtime topics must start with `tenant/<tenant_id>/project/<project_id>/...` internally.

## Key Model

Tenant keys should be scoped and revocable:

| Key type | Scope | Stored as |
|---|---|---|
| anon/public | tenant + project + app | hash + prefix in `tenant_api_keys` |
| service | tenant + project + scopes | hash + prefix + server-only flag |
| realtime token | tenant + project + topic ACL | short-lived JWT |
| internal service token | service audience + tenant | short-lived signed token |

Never let tenant code use the platform-wide `ADAPTER_REGISTRY_SERVICE_TOKEN`.

## Quotas And Plans

Tenant isolation is incomplete without quotas:

- per-tenant request rate
- per-tenant realtime connections/subscriptions
- per-tenant pool size and idle pool TTL
- per-tenant outbox backlog limit
- per-tenant storage and egress limits
- per-tenant AI/mail/newsletter usage limits

Kong rate limiting should use tenant/API key or consumer, not only IP.

## Migration Plan

1. Add `tenant_id`, `project_id`, `app_id` to verified identity context.
2. Add missing `tenant_id` columns to control-plane tables with backfill from current owner/user assumptions.
3. Split `auth.current_user_id()` and `public.current_tenant_id()` into separate settings.
4. Update `PostgresService.tenantQuery()` to set both `app.current_tenant_id` and `app.current_user_id`.
5. Update adapter-registry `connect` path to require tenant/project, not just user.
6. Add plan-aware quota middleware.
7. Add migration verifier that fails if any control-plane table lacks tenant scope.

## Acceptance Criteria

- Two tenants can have the same `resource_name`, `database name`, and `user email` without data overlap.
- A forged or missing `tenant_id` cannot access another tenant's database metadata.
- All audit and outbox events include tenant/project context.
- Disabling an optional module for one tenant has no effect on another tenant.
- BYO database credentials are accessible only through tenant-scoped, audited flows.
