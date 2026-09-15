# The control plane

> **Status:** Partial · 2026-09-15
> **Evidence:** package grouping and binaries from the backend document; production flag set
> read from `deploy/fly/boot.sh`; gates `m165`, `m176`, `m177` cover provisioning
> **To check:** how long `verify_cache` lives — the window in which a revoked key still works
> **Sources:** `apps/grobase/CLAUDE.md` §Three-language plane, §flag-gating · `deploy/fly/boot.sh`

If the data plane executes, the control plane **decides and manufactures**. It also exists
differently: not one process serving requests, but six processes with separate jobs.

| Binary | Job |
|---|---|
| `tenant-control` | Tenant lifecycle |
| `adapter-registry` | Mounts and their credentials |
| `orchestrator` | Coordinates provisioning |
| `function-scheduler` | Scheduled jobs |
| `webhook-dispatcher` | Outbound events |
| `scale-seed` | Seeds the scale experiments |

None sits in the path of a query: the control plane works **before and around**, not during.
The one exception is the seam — resolving an API key to an identity.

---

## Decide above, apply below

The most useful pattern in the system, because it repeats three times.

Expensive decisions are made in the control plane and travel to the data plane as **snapshots
that can be consulted for free**:

- **Identity** — resolved via `/v1/keys/verify`, then held in a `verify_cache`.
- **Permissions** — the data plane carries its own ABAC evaluator in Rust, mirroring the SQL
  `has_permission(...)`, so it decides locally instead of round-tripping.
- **Quotas** — three "honor sets" (`quota_over`, `spend_over`, `suspended`) with refreshers.
  The commercial machinery lives above (metering, spend caps, abuse guard, entitlements,
  Stripe); only a cached verdict reaches below. That is where `402` comes from.

This is what makes separating decision from execution affordable.

**The cost:** a snapshot is stale by definition. Requests pass between a decision and the
refresh. Tolerable for quotas, delicate for permissions — hence the open TTL question.

---

## Forty-four packages are a business model

Read the grouping, not the count: core, cross-cutting infrastructure, **cloud**, functions,
auth, cross-app messaging, **enterprise**, parity.

The enterprise group alone is seventeen packages — `orgs teams groups environments sso scim
passkeys invites pubkeys audit compliance cmek trust ipguard erase export telemetryexport`.
Nearly 40% of the control plane. That is not architecture; it is the entry price to a market.

All of it is **flag-gated off by default**, each flag with its own gate and its own SQL
migration. That is how one codebase produces the open-source core (AGPL-3.0), the managed cloud
and the enterprise edition. The cost is a large configuration matrix, and the permanent burden
that the default path is not the path paying customers use.

Flags are structural: in Go the routes are **not mounted** unless the flag is set, in ~38
places. A surprising 404 is usually a flag, not a bug.
→ [operations/02-flags](../operations/02-flags.md)

---

## What is actually on in production

Read from `deploy/fly/boot.sh`, not assumed:

```
ORG_MODEL_ENABLED  RBAC_HIERARCHY_ENABLED  ENVIRONMENTS_ENABLED  GROUPS_ENABLED
INVITES_ENABLED    USER_PUBKEYS_ENABLED    TENANT_SELFSERVE_ENABLED
APPS_SELFSERVE_ENABLED  APP_CHANNELS_ENABLED  EMAIL_OTP_ENABLED
VAULT42_SCOPE_KEYS_ENABLED  BUILDER_ENABLED  DYNAMODB_ENGINE_ENABLED
```

Still off: SSO, SCIM, passkeys, hard erase, tenant export, audit, backup, metering, quota
enforcement, permission conditions, CMEK. → [project/02-modules](../project/02-modules.md)

---

## Provisioning, and the factory running itself

A new application is declared, not programmed — see [06-contracts](06-contracts.md), gate `m165`.

Gate `m177` goes one step further: `POST /v1/tenants/me/apps` creates a new app-tenant with its
own fresh `CREATE DATABASE` and a scoped key, behind `APPS_SELFSERVE_ENABLED` (on in
production). The factory does not need an operator. Gate `m176` proves that isolation holds:
a foreign key pointing at another app's mount resolves zero rows — a 404, never a cross read.

---

See also: [06-contracts](06-contracts.md) · [02-planes](02-planes.md) ·
[operations/02-flags](../operations/02-flags.md)
