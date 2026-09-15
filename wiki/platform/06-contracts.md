# Contracts — how an application is declared

> **Status:** Verified · 2026-09-15
> **Evidence:** `website.json` read directly; contracts are provisioned on every production
> boot by `deploy/fly/boot.sh`; gates `m165` (provisioning) and `m177` (self-serve)
> **Sources:** `infra/config/contracts/website.json` · `deploy/fly/boot.sh` ·
> `apps/grobase/CLAUDE.md` §Going to production

grobase is described by its own documentation as a **generic contract-driven factory, not an
application host**, containing **zero application-specific code**.

This page is where that claim becomes concrete. If one file makes the project click, it is this
one.

---

## An entire application, in one file

```json
{
  "version": 1,
  "tenant": { "id": "website", "plan": "essential", "owner_user_id": "system:website" },
  "mounts": [{
      "name": "website-pg", "engine": "postgresql", "database": "website",
      "isolation": "shared_rls", "read_scoped": true,
      "credentials": { "source": "docker_service", "host": "postgres", "port": 5432 }
  }],
  "roles": [{ "name": "user", "policies": [{
      "resource_type": "*", "resource_name": "*",
      "actions": ["select","insert","update","delete"],
      "effect": "allow", "conditions": { "owner_only": true }
  }]}],
  "api_keys": [{ "name": "website-app", "scopes": ["read","write"] }],
  "schema": { "postgresql": "infra/config/contracts/website.schema.sql" },
  "frontend_config": { "path": "build/website.env", "vars": {
      "PUBLIC_GROBASE_URL": "${KONG_URL}", "PUBLIC_BAAS_KEY": "${ANON_KEY}",
      "PUBLIC_DB_ID": "${MOUNT_ID:website-pg}"
  }}
}
```

A complete application — database, isolation strategy, roles, permissions, keys, frontend
configuration — with no code anywhere. Three things it teaches:

**`"isolation": "shared_rls"`** — the isolation strategy is **a field of the contract**. Not in
code, not in the environment: declared per mount, alongside `"read_scoped": true` which narrows
reads to the owner. This answers a question that stayed open for a long time.
→ [07-isolation](07-isolation.md)

**`"conditions": { "owner_only": true }`** — the permission is a datum, not a conditional
scattered through controllers. This is the genericity principle made visible.

**`${KONG_URL}`, `${MOUNT_ID:website-pg}`** — the provisioner fills in what is only known at
creation time and **emits the frontend's `.env`**. The frontend is never configured by hand.

---

## What the provisioner does

Two files — `infra/config/contracts/<app>.json` and `<app>.schema.sql` — feed one generic
provisioner, which creates an isolated database, seeds it, mints the API keys, and emits the
`PUBLIC_*` configuration the frontend needs.

Those four steps are what a person normally does by hand over half an afternoon, getting the
third one wrong. Here it is a declarative artifact and a process. Gate `m165` proves it.

Live contracts today: **`website.json` and `vault42.json`**. Both are provisioned on every
production boot; the script marks completion so it is not repeated.

---

## The factory running itself

`POST /v1/tenants/me/apps` creates a new app-tenant with its own fresh `CREATE DATABASE` and a
scoped key — gate `m177`, behind `APPS_SELFSERVE_ENABLED`, which is **on in production**.

No operator is needed. Someone asks for an application and gets one, with its own database and
its own credential. That is the difference between an automated procedure and a product.

Its complement is gate `m176`: a foreign key pointing at another application's mount resolves
**zero rows — a 404, never a cross read**. Not "you lack permission" but "it does not exist",
which is the right answer for something outside your universe.

---

## Why this is the strongest demonstration

Thirty seconds, one request, a readable artifact behind it. The best candidate for a custom
module in the evaluation. → [project/02-modules](../project/02-modules.md)

---

See also: [04-control-plane](04-control-plane.md) · [07-isolation](07-isolation.md) ·
[quality/02-key-gates](../quality/02-key-gates.md)
