# Beta (osionos develop) on the production bridge: devil verdict, 2026-11-01

**Verdict: PROCEED-WITH-CONDITIONS.** The plan is sound once B1–B12 hold. They are the acceptance
criteria. ADR: [0040](../adr/0040-the-develop-beta-runs-tailnet-only-on-8444-against-the-production-bridge.md).

## The plan's strongest case

The bridge allows exactly one CORS origin (`OSIONOS_ALLOWED_ORIGIN`, `docker-compose.public.yml:90,126`).
Apart from that, `requestOriginConfig` only admits localhost, tauri and `app://osionos`
(osionos `scripts/bridge-api.mjs:2663-2671`). Adding :8444 to the bridge would mean editing and restarting
the production bridge. An edge in front of it leaves production alone. Loopback publishing plus
`serve` with no Funnel keeps the audience to tailnet members.

## What the evidence changes

1. **Cookies give no isolation between :8443 and :8444.** A cookie is scoped to the host, not the port,
   so both origins send and receive the same cookies. That includes `credentials: 'include'` on
   `/api/auth/bridge/consume` (osionos `src/features/auth/model/userStore.helpers.ts:162-166`). Develop
   code can read every non-HttpOnly cookie for that host and overwrite any cookie, `__Host-` ones
   included, because :8444 is https. An XSS bug in develop therefore becomes a production session
   compromise. localStorage (the Bearer JWT, `src/shared/api/*`) is per origin, so users sign in again
   on :8444.
2. **Origin rewriting is a CSRF bypass unless it is conditional.** If the edge rewrites *any* incoming
   Origin to :8443, a web page that a tailnet member opens can call :10001 and the bridge treats the
   call as coming from prod. Browsers allow a page to send requests to tailnet hosts. Only a request
   whose Origin is exactly :8444 may be rewritten.
3. **Develop code writes real data.** A new block, page or database shape from develop is stored in
   production rows, and main's app may then misread them. This is the silent-corruption path, and it
   cannot be undone by rolling back a container.
4. **One wrong port replaces production.** A `tailscale serve --https=8443`, a
   `docker compose -p track-binocle up`, or a `docker image/system prune` would touch prod.
   (See the 2026-10-30 lesson: a compose run under a different file set recreates prod containers.)
5. Auth email links, OAuth and bridge-consume redirects go to `OSIONOS_APP_URL` = :8443
   (`docker-compose.public.yml:89`), so beta users finish those flows on prod. That is functional, not
   a safety problem. Say so in the beta notes.

## Risk

| Axis | Score | Why |
|---|---|---|
| Blast radius | 4 | real users' data and sessions |
| Reversibility | 4 | the containers can be undone; data written by develop cannot |
| Cost on failure | 4 | silent data corruption; session theft through cookies |
| Confidence | 3 | serve config, ACL and the auth gateway's Origin check are unverified |

Worst axis: reversibility of data written by develop.

## Conditions (each one testable)

- **B1 Strict Origin.** On :3010 and :3011, the edge rewrites Origin/Referer only when Origin is exactly
  `https://baas.tail10f2ea.ts.net:8444`. A request with any other non-empty Origin gets 403. Test:
  `curl -H 'Origin: https://evil.example' …:3011/api/health` gives 403, and with the :8444 Origin gives 2xx.
- **B2 Exact ACAO rewrite.** The edge rewrites `Access-Control-Allow-Origin` only from the exact :8443
  value to the exact :8444 value, never to `*` and never by echoing the request. It keeps `Vary: Origin`
  and `proxy_buffering off` for SSE. Test: a curl of the response headers on one JSON route and one
  SSE route.
- **B3 Tailnet only.** Snapshot `tailscale serve status --json` before step 3. After it, the diff adds
  exactly the 8444 and 10001 handlers and changes nothing else (8443, 10000, 443 stay byte-identical).
  `tailscale funnel status` lists neither 8444 nor 10001. Test: from outside the tailnet (Tor),
  `curl https://baas.tail10f2ea.ts.net:8444` fails.
- **B4 Loopback only.** The beta app and the edge publish `127.0.0.1:` ports only. Test:
  `ss -ltnp | grep -E ':(3010|3011)'` shows 127.0.0.1, and the beta app port does too.
- **B5 Separate project.** Beta runs in its own compose project (for example `-p osionos-beta`) with its
  own file, container names prefixed `osionos-beta-`, and `track-binocle` network declared
  `external: true`. The timer script never calls compose with `-p track-binocle`, never runs `down`
  on another project, and never runs `prune` without `--filter label=osionos.beta=1`. Test: grep the
  script; `docker inspect` the prod container IDs and start times before and after a timer run, and
  they are unchanged.
- **B6 Same headers as prod.** The beta app is served with a CSP and security headers no weaker than
  :8443's (they compare equal header by header, with the origin swapped). Its source maps are not
  served if prod's are not.
- **B7 Backup before first exposure.** A restorable dump of the bridge/app databases, dated before the
  first beta request, exists and has been restored once into a scratch DB. Show the command and the
  row counts. This is the only rollback for B-risk 3.
- **B8 Visible beta.** A banner or title marks the beta, saying "develop build, writes real data". Only
  people the owner names are told the URL.
- **B9 Timer safety.** `flock -n`; `devil watch` timeouts on fetch and build; it deploys only after a
  successful build *and* an HTTP 200 health check on the new container. Otherwise the previous beta
  stays up. The deployed sha is in a file and in an image label. Test: break a build on purpose and
  the old container keeps serving.
- **B10 Kill switch, one step, documented.** `tailscale serve --https=8444 off && tailscale serve
  --https=10001 off && docker compose -p osionos-beta down`. Run it once before go-live and confirm
  that :8443 and :10000 still answer.
- **B11 Auth gateway checked.** Before go-live, confirm what :8787 does with Origin. If it is cookie-
  or Origin-gated, B1 applies to `/api/auth` and `/api/newsletter` as well. Proof: a curl showing a
  foreign Origin refused through :3010.
- **B12 Disk and CPU bounded.** Old beta images are removed by label, at most 2 kept. The build runs
  under `nice`/`ionice`, so a build every 5 min cannot starve prod. Show `docker system df` before and
  after a day.

## Caveat

The CSRF and cookie analysis is about browser behaviour. It assumes no tailnet member is hostile. A
hostile member can already reach :10000 directly, and the edge does not change that. The auth
gateway's Origin handling (B11) and the live `serve` config (B3) were not inspected for this ruling.
