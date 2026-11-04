# 0040. The develop beta runs tailnet-only on :8444 against the production bridge

- Status: accepted with conditions (devil: PROCEED-WITH-CONDITIONS, 2026-11-01). B1–B12 are open
- Date: 2026-11-01
- Deciders: owner (chose a beta app on the prod bridge over a beta bridge on prod data), devil (ruling)

## Context

- The bridge allows one fixed CORS origin, :8443 (`docker-compose.public.yml:90,126`; osionos `scripts/bridge-api.mjs:205,2657`). Besides it, it admits only localhost, tauri and `app://osionos` (`bridge-api.mjs:2663-2671`).
- Cookies are scoped to the host, not the port, so :8443 and :8444 share every cookie. The app sends cookies on `/api/auth/bridge/consume` (osionos `src/features/auth/model/userStore.helpers.ts:162-166`). Bearer JWTs stay in per-origin storage.
- The service worker rules out a path-based beta on :8443.

## Decision

The beta app (osionos develop) and an edge nginx publish to host loopback only. `tailscale serve` exposes them on :8444 and :10001 with no Funnel. The edge rewrites Origin to :8443, and the response ACAO from :8443 to :8444, only for the exact :8444 Origin. Beta is a separate compose project, and a systemd timer rebuilds it on each new develop sha.

## Alternatives considered

- Add :8444 to the bridge's admitted origins: needs a production bridge change and restart, which the owner declined.
- A beta bridge on a copy of prod data: isolates writes but forks the data, which the owner declined.
- `/beta` on :8443: shares the service worker scope and the origin, so it is ruled out.

## Consequences

- Develop code runs with prod cookies and writes prod data. A develop XSS bug can take over a prod session, and a format change can corrupt rows. Rolling back the container does not undo the data.
- Conditions B1–B12 in `docs/ops/beta-develop-verdict-2026-11-01.md` are the acceptance criteria. The most important are B1 (strict Origin), B3 (serve diff, no Funnel), B5 (separate compose project, no unscoped prune) and B7 (tested backup before first exposure).
- Rollback is B10. Revisit this decision if beta opens beyond the tailnet, or if develop starts a schema or storage-format migration.
