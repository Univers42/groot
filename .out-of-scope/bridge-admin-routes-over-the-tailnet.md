# Carrying the bridge's baas admin routes over the tailnet is out of scope

- Decided: 2026-10-18 · by devil (ruling on My Tasks, ADR 0019)
- Holds while: the bridge's one key is both the PostgREST service_role key and the baas-admin key, and the
  bridge is reachable from the internet

## The concept

The request: route the bridge's `/admin/v1/*` calls to baas over the private tailnet instead of Funnel, so
that My Tasks works (bridge `GET /api/databases` calls baas `GET /admin/v1/databases`). WAF rule 10130 keeps
refusing admin routes that arrive through Funnel.

## Why not

- Rule 10130 tests one thing: the `Tailscale-Funnel-Request` header. Past it, `/admin/v1` is gated by the
  service_role key alone, and the same key opens `/meta/v1` (SQL), key rotation, migrations, function
  secrets, tenant provisioning and `/realtime/v1/publish`. It cannot express "only the bridge".
- The bridge's key cannot be scoped down by routing. Giving the bridge a tailnet route gives every
  service-key call it makes admin reach.
- The transport does not exist. No container reaches the tailnet (rootlesskit `--disable-host-loopback`), and
  each way to build one is reachable from the Funnel-facing containers or the campus LAN.
- It is not needed. The tenant-scoped read `GET /v1/tenants/me/mounts` serves the same list with the
  tenant key and no DSN, and baas now runs it ([ADR 0019](../docs/adr/0019-my-tasks-reads-the-tenant-scoped-mount-list-not-the-admin-route.md)).
- A compromised bridge under this plan reaches the control plane of every tenant on prod baas. Today it
  reaches the data plane through the service key, not the control plane.

## Prior requests

- 2026-10-18 (the user, choosing how My Tasks should work on the public stack): plan A, the tailnet route.

## Reopen when

grobase can no longer serve a tenant-scoped mount list, or the bridge gets a credential that opens only
`GET /admin/v1/databases` for its own tenant (a split of the service key). Even then the request must come
with a path-pinned egress proxy in the link that forces the tenant headers and refuses every other admin
path, with the variants (`%2e%2e`, `//`, `%61dmin`) tested.
