# Feature flags

> **Status:** Verified · 2026-09-15
> **Evidence:** the master/sub pattern and the "off is the proven state" warning are stated in
> the backend document; the production set read from `deploy/fly/boot.sh`
> **Sources:** `apps/grobase/CLAUDE.md` §Cloud, enterprise & parity features are flag-gated OFF ·
> `deploy/fly/boot.sh`

Cloud, enterprise and parity features are **off by default**, each with its own flag, migration
and gate — that is how one codebase produces the open-source core, the managed cloud and the
enterprise edition. Four things about it will otherwise cost you a day.

---

## 1 · Off is structural, not a runtime check

In Go the routes of a gated feature are **not mounted at all** unless the flag is set — ~38 sites:

```go
if envBool("ORG_MODEL_ENABLED") {
    // the route is registered here — otherwise it DOES NOT EXIST
}
```

**Consequence:** an unexpected **404 is usually a flag, not a bug.**

---

## 2 · Half a flag is a silent no-op

Several features need **both halves, one per plane**. Each plane reads its own variable.

| Feature | Control plane (Go) | Data plane (Rust) |
|---|---|---|
| Metering | `METERING_ENABLED` | `DATA_PLANE_METERING` |
| Quota enforcement | `QUOTA_ENFORCEMENT` | `DATA_PLANE_QUOTA_ENFORCEMENT` |
| Per-tenant observability | `TENANT_OBS_ENABLED` | `DATA_PLANE_TENANT_OBS` |

Raise one and you get a **silent no-op** — the backend document's own words. No error, nothing
happens. The most expensive trap in the repository, and the project's own "silence is not
success" rule in environment-variable form.

---

## 3 · Flags carry migrations, and some have roots

A flag raised without its SQL migration leaves the feature broken. And there are chains: the
whole organisation block — teams, groups, environments, invites — depends on
**`RBAC_HIERARCHY_ENABLED` and `ORG_MODEL_ENABLED`**. Raising a leaf without the roots does
nothing.

---

## 4 · Off is the proven state

The document asks that these not be raised in shared or parity runs without a gate backing them:
**the tested configuration is the default one.** Raise eight flags the night before a
demonstration and you will demonstrate a configuration nobody has ever run. Raise them early,
run their gates, save a known-good `.env`, leave it alone.

---

## What is on in production

Read from `deploy/fly/boot.sh`, not assumed:

```
ORG_MODEL_ENABLED  RBAC_HIERARCHY_ENABLED  ENVIRONMENTS_ENABLED  GROUPS_ENABLED
INVITES_ENABLED    USER_PUBKEYS_ENABLED    TENANT_SELFSERVE_ENABLED
APPS_SELFSERVE_ENABLED  APP_CHANNELS_ENABLED  EMAIL_OTP_ENABLED
VAULT42_SCOPE_KEYS_ENABLED  BUILDER_ENABLED  DYNAMODB_ENGINE_ENABLED
REALTIME_PROTECTED_NAMESPACES=collab:,xapp:
```

Still off: `SSO_ENABLED`, `SCIM_ENABLED`, `PASSKEYS_ENABLED`, `HARD_ERASE_ENABLED`,
`TENANT_EXPORT_ENABLED`, `TENANT_AUDIT_ENABLED`, `TENANT_BACKUP_ENABLED`, metering, quota
enforcement, `PERMISSION_CONDITIONS_ENABLED`, `API_KEY_ABAC_ENABLED`, `CMEK_ENABLED`,
`TENANT_HEADER_IDENTITY_HMAC`.

That split matters: features already on need **only a screen**; the rest need flag, migration,
gate *and* screen. → [project/02-modules](../project/02-modules.md)

`make cloud-up` raises the cloud set via `infra/config/cloud/flags.env.cloud` — read that file
before using it.

---

## One that is not a feature flag

`RUST_DATA_PLANE_FORWARD` / `DATA_PLANE_ROUTER_PRODUCT_MODE` govern the TypeScript→Rust cutover:
per request, not per deployment. → [platform/02-planes](../platform/02-planes.md)

**Open question:** production sets `RUST_DATA_PLANE_FORWARD_ENGINES` with ten engines but the
master switch is not visible in `.env.local`. If unset anywhere, the allow-list does nothing —
the master/sub no-op, in production.
Check: `grep -rn "RUST_DATA_PLANE_FORWARD=" scripts/env/ .env*`

---

See also: [01-bring-up](01-bring-up.md) · [platform/04-control-plane](../platform/04-control-plane.md)
