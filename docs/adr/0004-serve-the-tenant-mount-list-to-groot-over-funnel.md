# 0004. Reach baas over Funnel only: list mounts through a read-only self-serve route, publish over the realtime WebSocket

- Status: accepted with conditions (nothing has been built or deployed yet)
- Date: 2026-10-15
- Deciders: devil (risk ruling of 2026-10-15). The user, who triggers the VM deploy and owns the pushes,
  has to live with it.

## Context

- Over Funnel, WAF rule 10130 refuses `/admin/v1`, `/meta/v1` and `/realtime/v1/publish`
  (`apps/grobase/infra/docker/services/waf/conf/exclusions.conf:143-153`). This is correct: Kong sees every
  Funnel request as coming from loopback, so the service_role key alone would otherwise open admin. As a
  result, the bridge's mount list (Kong `/admin/v1/databases`) and its realtime publish both return 403.
- grobase already has a tenant-scoped, read-scope mount list that returns no DSN
  (`src/control-plane/internal/tenants/builder_mounts_list.go:33-47`,
  `adapter_registry_mounts.go:28-35,87-90`). Only BUILDER_ENABLED registers it (`builder.go:88-90`), and
  baas runs with the builder off.
- The builder path builds its self-serve struct without the authenticator (`builder.go:81`;
  `selfserve.go:65-68,82`; `authenticator.go:70`). Since 865dbb8d (2026-06-28), every authenticated builder
  request panics and returns 500.
- `/realtime/v1/ws` is public (`kong.yml:288-293`). A PUBLISH frame is allowed by the JWT's `can_publish`
  plus `namespaces` (`auth_claims.rs:101-118`). A token needs an accepted `iss`
  (`orchestrators/compose/base/data-plane.yml:194-195`).
- On baas, `REALTIME_PROTECTED_NAMESPACES` is empty, measured 2026-10-15.
- The REST publish handler has no auth and no topic scoping (`rest_api.rs:103-111`).
- tenant-control verifies every API key for the data plane and the Nest services (`data-plane.yml:107`,
  `app-services.yml:41`).
- The control-plane Dockerfile defaults to `APP=adapter-registry` (`src/control-plane/Dockerfile:8-9`).
- Unknown when this was written:
  - whether a WebSocket upgrade passes through Funnel;
  - how long Kong keeps the old tenant-control IP after a recreate;
  - the publish queue size the bulk writes need.

## Decision

- **grobase.** tenant-control registers the read-only `GET /v1/tenants/me/mounts` whenever self-serve is on.
  It uses the self-serve authenticator. POST and DELETE on mounts, entitlements and the builder preview stay
  builder-only.
- **osionos bridge.**
  - It lists mounts through that route with its tenant key, opt-in through `OSIONOS_TENANT_MOUNTS_URL`.
  - It publishes over the realtime WebSocket with a short-lived `iss: grobase-realtime`,
    `namespaces: ["*"]` publish-only token minted from JWT_SECRET. This is opt-in through a ws(s)
    `REALTIME_PUBLISH_URL`. baas protects no namespace (`REALTIME_PROTECTED_NAMESPACES` is empty), so
    `"*"` also reaches `collab:` and `xapp:`, exactly like the REST publish route it replaces.
- **groot link.** It writes each variable only when a probe without credentials shows that the target needs
  it.
- **baas.** The patched tenant-control image is built with explicit APP and PORT arguments. The user deploys
  it, behind a backup tag and a compose config-hash check. WAF 10130 is not changed.

## Alternatives considered

- **Relax 10130 for GET /admin/v1/databases.** Rejected. The route trusts the service_role key and
  ip-restriction. Over Funnel, ip-restriction admits the internet (`exclusions.conf:128-141`).
- **Use osionos_workspace_databases.label as the mount name.** Rejected. Labels differ from the registered
  names ("Commerce · Postgres" against pg-commerce). DB1, DB2 and the UI contract key on the registered name.
- **Per-topic, exact-namespace publish tokens.** Rejected as a requirement. Each bridge topic is its own
  namespace (`topic_path.rs:63-65`), so this means one AUTH round per publish, and a failed AUTH closes the
  socket (`handlers.rs:61-65`). The minter already holds JWT_SECRET and SERVICE_ROLE_KEY. See
  `.out-of-scope/bridge-per-topic-realtime-tokens.md`.
- **Plain `docker build ./src/control-plane` on the VM.** Rejected. It builds adapter-registry, which passes
  its own healthcheck while every key verification fails.

## Consequences

- The verdict is PROCEED-WITH-CONDITIONS FO0-FO36, in
  `/goinfre/dlesieur/.groot-vault42-recover/devil-verdict-funnel-only-2026-10-15.md`. Those conditions are the
  acceptance criteria.
- m134's flag-off contract changes: GET /me/mounts now exists with the builder off. The SDK and builder
  comments that say otherwise change in the same commit.
- Until the grobase branch merges and CI republishes `:latest`, baas runs an image built from an unmerged
  branch. A pull of `:latest` silently removes the route, and the bridge reports a 503 naming the missing
  route.
- The tenant-selfserve rate bucket (120/min, `kong.yml:515`) is shared over Funnel by the bridge and every
  internet client.
- Once publishing is restored, chat content reaches whoever holds a namespace-less realtime token. Protected
  namespaces are empty on baas and the fallback is baseline. Closing that is a separate decision:
  `REALTIME_PROTECTED_NAMESPACES` or `SECURITY_MODE=max` on baas.
- Addendum 2026-10-15 ~22:25: the user's explicit "run all of that" moves D and the read-only models
  `--check` to the agent, under E1-E8 in the verdict file. The seeder stays user-run: the user was already
  running it (pid 4181988, pts/4). The agent's deploy starts only after that run reports A1/A2, and only
  with a single operator. The classifier remains the gate.
- Reverse this when the grobase route ships in a published image and the bridge pin carries B. At that point
  the opt-in variables can become defaults.
