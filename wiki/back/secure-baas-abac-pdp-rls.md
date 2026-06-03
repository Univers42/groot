# ABAC, PDP And RLS Layering

**Design goal**: make ABAC the non-skippable authorization layer for every engine, while keeping Postgres RLS as defense-in-depth for the control plane and Postgres-native data.

## Current State

ABAC is not just decorative anymore. The query-router calls `decidePermission()` before `adapter.execute()` in [query.service.ts](../../apps/baas/mini-baas-infra/src/apps/query-router/src/query/query.service.ts). The decision endpoint is in [decisions.controller.ts](../../apps/baas/mini-baas-infra/src/apps/permission-engine/src/decisions/decisions.controller.ts), backed by [decisions.service.ts](../../apps/baas/mini-baas-infra/src/apps/permission-engine/src/decisions/decisions.service.ts) and [007_permissions_system.sql](../../apps/baas/mini-baas-infra/scripts/migrations/postgresql/007_permissions_system.sql).

The product gap is performance and expressiveness: every query makes a network call to permission-engine, policy conditions are limited, and policy scope is not yet tenant/project/app aware.

## Target Model

Use a split between PAP, PDP and PEP:

| Component | Meaning | Target owner |
|---|---|---|
| PAP | Policy Administration Point: create/update policies | `permission-engine` |
| PDP | Policy Decision Point: compile and evaluate policies | local library inside query-router and services |
| PEP | Policy Enforcement Point: mandatory gate before action | common middleware/wrapper around adapters/controllers |

`permission-engine` should manage policies and publish compiled policy bundles. Query-router should evaluate locally for hot-path decisions.

## Policy Context

Every decision should receive this context:

```ts
interface PolicyContext {
  tenantId: string;
  projectId: string;
  appId: string;
  userId?: string;
  roleNames: string[];
  scopes: string[];
  resource: {
    engine: string;
    databaseId: string;
    name: string;
    type: 'table' | 'collection' | 'bucket' | 'topic' | 'endpoint';
  };
  action: 'list' | 'get' | 'insert' | 'update' | 'delete' | 'upsert' | 'subscribe' | 'publish';
  attributes: {
    ip?: string;
    userAgent?: string;
    aal?: string;
    time?: string;
    requestId?: string;
  };
}
```

ABAC must authorize realtime topics, schema changes, storage operations and module APIs too, not only query-router data operations.

## Policy Bundle

Compile SQL policy rows into a bundle:

```ts
interface CompiledPolicyBundle {
  tenantId: string;
  projectId: string;
  version: number;
  generatedAt: string;
  policies: CompiledPolicy[];
}

interface CompiledPolicy {
  effect: 'allow' | 'deny';
  priority: number;
  role: string;
  resourceType: string;
  resourceName: string;
  actions: string[];
  condition: PolicyExpression;
  mask?: FieldMask;
}
```

Distribute bundles by Redis pub/sub or a versioned pull endpoint:

```http
GET /permissions/v1/bundles/:tenantId/:projectId?ifVersion=42
```

Query-router caches by `(tenantId, projectId, policyVersion)`.

## Evaluation Rules

1. Deny wins at equal or higher priority.
2. Default deny if no allow matches.
3. Tenant/project mismatch is an immediate deny before role evaluation.
4. Field masks are applied after adapter execution and before response/outbox projection if relevant.
5. Policy bundle fetch failure should fail closed unless a fresh-enough local bundle exists.

## RLS Position

RLS is still valuable, but it is not the universal policy engine:

| Layer | Purpose |
|---|---|
| ABAC PDP | engine-agnostic policy, rich attributes, tenant/app rules |
| Adapter filters | owner/tenant filter injection for engines without RLS |
| Postgres RLS | defense-in-depth for shared/control-plane Postgres tables |
| Database grants | prevent accidental broad access from service roles |

For Postgres, set both:

```sql
SELECT set_config('app.current_tenant_id', $1, true),
       set_config('app.current_user_id', $2, true),
       set_config('request.jwt.claims', $3, true);
```

For MongoDB, MySQL and others, adapters must inject tenant filters or route only to tenant-owned dedicated mounts.

## Performance Target

The hot path should not call permission-engine over HTTP for every row operation.

Target latencies:

| Operation | Target |
|---|---|
| local PDP decision | < 1 ms p50 |
| policy bundle refresh | async, not per request |
| permission-engine admin write | can be slower, audited |

Metrics:

- `baas_pdp_decision_total{allow,deny,tenant,engine}`
- `baas_pdp_decision_duration_seconds`
- `baas_pdp_bundle_version{tenant,project}`
- `baas_pdp_bundle_stale_total`
- `baas_pdp_fail_closed_total`

## Integration Points

Make the PEP unavoidable:

- query-router adapter wrapper
- transaction session `ops` endpoint
- schema-service create/drop
- storage-router presign
- realtime subscribe/publish
- module APIs that mutate tenant state

Avoid putting policy checks inside individual engines. Engines should receive an already-authorized `DataOp` plus mandatory tenant/owner filters.

## Migration Plan

1. Add tenant/project/app columns to policy tables.
2. Create `PolicyBundleService` in permission-engine.
3. Extract PDP evaluator as a shared library in `libs/common` or a new `libs/policy`.
4. Add query-router local PDP cache with fail-closed stale policy rules.
5. Keep remote `/permissions/decide` as compatibility and debugging endpoint.
6. Extend conditions: MFA/AAL, time window, IP/CIDR, app/client, field masks, resource tags.
7. Add ABAC checks to realtime topics and schema-service.

## Acceptance Criteria

- A query-router write is denied locally if the policy bundle says deny, without network hop.
- Killing permission-engine does not allow unauthorized operations.
- Policies can express tenant/project/app/user conditions.
- MongoDB and MySQL operations are protected by the same ABAC rules as Postgres.
- RLS remains enabled for shared control-plane tables and matches ABAC tenant semantics.
