# 0019. My Tasks reads the tenant-scoped mount list; the bridge's admin routes stay off the tailnet

- Status: accepted with conditions (C1-C10 below, all met)
- Date: 2026-10-18
- Deciders: devil (risk ruling of 2026-10-18: BLOCK on the tailnet plan, PROCEED-WITH-CONDITIONS on this
  one). The user ran every baas step.

## Context

- My Tasks / Databases failed on the public stack: the bridge's `GET /api/databases` called baas
  `GET /admin/v1/databases` with the service key, and WAF rule 10130 refuses `/admin/v1` when the request
  carries `Tailscale-Funnel-Request`. Both test accounts got 403.
- Plan A, as submitted: carry the bridge's `/admin/v1/*` calls over the private tailnet, where 10130 does not
  fire. Rejected. Measured the same day:
  - Past 10130, `/admin/v1` is gated by the service_role key alone. That key also opens `/meta/v1` (SQL),
    key rotation, migrations, function secrets, tenant provisioning and `/realtime/v1/publish`.
  - The bridge's one key is both the PostgREST service_role key and the baas-admin key, so a tailnet route
    cannot be scoped to one endpoint.
  - No container reaches the tailnet: rootlesskit runs with `--disable-host-loopback`. Every way to build the
    transport exposes it to the Funnel-facing containers or the campus LAN.
- The non-admin route already existed: tenant-control `GET /v1/tenants/me/mounts` returns id, tenant,
  engine, name and timestamps, with no DSN, scoped by the key's own tenant ([ADR 0004](0004-serve-the-tenant-mount-list-to-groot-over-funnel.md)).
  baas did not serve it (404): the step ADR 0004 left pending was never deployed.

## Decision

- Plan B. grobase tenant-control was redeployed as a fix-only image: base revision `0ffbe51e` plus the
  cherry-pick `eb0d7cc4`, nothing else. The bridge sets
  `OSIONOS_TENANT_MOUNTS_URL=http://mini-baas-kong:8000/v1/tenants/me/mounts` and reads the list with its
  tenant key. Once set, it never calls `/admin/v1`.
- No tailnet transport: no link route through 127.0.0.1:1055, no rootlesskit change, no tailscale sidecar.
- WAF rule 10130 is unchanged. The admin routes stay refused through the link.
- The out-of-scope record is
  [`bridge-admin-routes-over-the-tailnet`](../../.out-of-scope/bridge-admin-routes-over-the-tailnet.md).

## Conditions (devil) and where they stand

| | Condition | Status |
|---|---|---|
| C1 | No tailnet transport; bridge tests "never calls the registry" and "never falls back" stay green | held |
| C2 | Deploy scoped before running: running image and commit recorded, diff limited to the mount fix | done: `0ffbe51e` + `eb0d7cc4` only |
| C3 | Rollback prepared before replacing anything | done: `:rollback-20261018` is the previous image (rev `0ffbe51e`) |
| C4 | m131, m133, m134 and `go test` green before the image reaches the VM | done: m131, m133 and m134 "ALL GATES GREEN" and `go test` green on the host before the image was shipped |
| C5(a) | Anonymous `GET /v1/tenants/me/mounts` answers 401 | measured over Funnel: 401 |
| C5(b) | With the tenant key: 200, rows of the right tenant, no `connection_string` | measured: 200, 9 rows for tenant `agency`, no `connection_string` field |
| C5(c) | The 9 tenant-key ids equal the ids of the admin `GET /admin/v1/databases` for `agency` | measured (user-run, 127.0.0.1 on the VM, with `X-Baas-Tenant-Id`/`X-Baas-User-Id`): 200, the same 9 ids, all tenant `agency` |
| C6 | 10130 unchanged; admin routes still 403 through the link | held (below) |
| C7 | Re-link and recreate the bridge; the variable is set in `.env.local` and in the running container | set as above |
| C8 | My Tasks answers 200 for the normal and the exempt account; no new 10130 hits | measured (below) |
| C9 | One upstream mounts call per load; no 429 | measured (below) |
| C10 | This ADR and the out-of-scope record | this commit |

## Measured (2026-10-18, deploy at about 21:25 CEST)

- Running image: `ghcr.io/univers42/grobase-tenant-control:mountfix-ca15567e`.
- The baas WAF exclusions file, sha prefix `ef5464c498e738bc`, is the same before and after.
- Through the link, `/admin/v1`, `/meta/v1` and `POST /realtime/v1/publish` still answer 403 (rule 10130).
- My Tasks loads 200 for both test accounts, makes exactly 1 upstream mounts call per load, and the e2e
  window has 0 429s and 0 new 10130 hits.

## Consequences

- baas's docker uses the containerd image store, whose `.Id` is the manifest digest. It differs from the
  host's config digest for the same content. Check the running image on baas by the sha256 of
  `RootFS.Layers`, not by `.Id`.
- A later `compose pull` or build from an image older than the mount fix brings the 404 back with no error.
  The bridge then reports 503 for My Tasks: it has no fallback by design.
- The self-serve bucket (120/min) is shared over Funnel by the bridge and every internet client. A cache, if
  one is ever needed, is a separate change with a `Caveat:` line.
- If the bridge is recreated from an `.env.local` without the variable, it silently reverts to the registry
  path and the 403. Recreate it after every `make link`.
- A `rebuild` of the app without the public overlay would bake `VITE_BAAS_API_KEY` (equal to the tenant key)
  into the bundle again. [ADR 0018](0018-serve-the-groot-frontends-on-the-host-funnel-with-verified-open-signup.md)'s
  secret grep catches it.
- Not verified: the tailnet ACL (who can reach baas:443); whether the baas WAF listeners bind
  loopback only.
- Follow-up F6, not a gate: split the bridge's one key into two Kong consumers (PostgREST service_role and
  baas-admin). That is a grobase change and needs its own ruling.
