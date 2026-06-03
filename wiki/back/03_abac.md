# 03 — Permissions: ABAC and RBAC

The BaaS supports two permission modes, controlled by `PERMISSION_MODE` env
on the permission-engine. ABAC and RBAC are **mutually exclusive** — pick
one per deployment.

## Mode selection

```sh
PERMISSION_MODE=abac   # default; field-level masks, conditions
PERMISSION_MODE=rbac   # binary allow/deny per (role, resource, action)
```

Set it in `.env`; both the TS permission-engine and the Rust router read it.

## ABAC model

Tables (in `scripts/migrations/postgresql/007_permissions_system.sql`):

- `abac_roles` — named bundles (`reader`, `editor`, `tenant_admin`, …)
- `abac_policies` — `(role_id, resource, action, effect, conditions JSONB, field_mask TEXT[])`
- `abac_user_roles` — `(user_id, role_id, tenant_id, project_id, app_id)`

A decision request looks like:

```json
{
  "user_id": "u-123",
  "tenant_id": "t-acme",
  "resource": "orders",
  "action": "read",
  "context": { "project_id": "p-1" }
}
```

The evaluator (SQL function `auth.has_permission` + the Rust mirror in
`crates/data-plane-server/src/abac.rs`) returns:

```json
{
  "allow": true,
  "field_mask": ["id", "total", "created_at"],
  "conditions": { "status": { "$ne": "draft" } }
}
```

`field_mask` is applied by the query-router before serializing the response;
`conditions` are spliced into the engine query as WHERE/filter clauses.

## RBAC model

Same tables, but the evaluator skips field-mask resolution and conditions —
it returns a pure `{ allow: true|false }`. The query-router treats any
allowed read as "all columns visible", giving simpler semantics for projects
that don't need column-level access control.

## Inline policy bundle (Rust local evaluation)

The Rust router can answer `/v1/permissions/decide` without an HTTP roundtrip
when `DATA_PLANE_PERMISSION_BUNDLE` is set to an inline JSON policy bundle:

```json
{
  "version": 1,
  "roles": [...],
  "policies": [...]
}
```

This is useful for edge deployments where the permission-engine isn't
co-located. The bundle format mirrors what `permission-engine/bundles/latest`
serves over HTTP.

## How to add a policy

```sql
INSERT INTO public.abac_roles (id, name, tenant_id)
VALUES ('r-reader', 'reader', 't-acme');

INSERT INTO public.abac_policies (role_id, resource, action, effect, field_mask)
VALUES ('r-reader', 'orders', 'read', 'allow', ARRAY['id','total','created_at']);

INSERT INTO public.abac_user_roles (user_id, role_id, tenant_id)
VALUES ('u-123', 'r-reader', 't-acme');
```

## What's NOT supported (honest list)

- Negative policies (`deny` overriding `allow`) are evaluated but the
  precedence rules are simple "deny wins" — no priority weights.
- ABAC conditions are JSONPath-style; deeply nested `$or` trees work but
  are not optimized.
- Switching modes mid-traffic requires a permission-engine restart.
