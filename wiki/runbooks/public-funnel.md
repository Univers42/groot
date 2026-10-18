# Public mode — the frontends on the internet through Tailscale Funnel

`make public-up` serves the website, the osionos app and the bridge from this host at
`https://osionos.tail10f2ea.ts.net` (`PUBLIC_ORIGIN` in `./.env.public`). The Funnel is the only
way in; nothing is opened until `scripts/public-funnel.sh verify --pre` passes, and
`make public-down` closes it in one command.

## What is exposed, what is not

| Public port | Serves | Loopback target |
|---|---|---|
| 443 | website, `/api/auth` (gateway), `/api/*` (Kong) | `https+insecure://127.0.0.1:4322` |
| 8443 | osionos app | `127.0.0.1:3001` |
| 10000 | osionos bridge | `127.0.0.1:4000` |

Funnel allows only 443, 8443 and 10000. Not exposed: the whiteboard (3007), mail and calendar
(3002/3003/4100/4200), the IDE (8446), the grobase edge (8444) and the gateway's own port (8787).
Consequences for a visitor: no whiteboard tab, no LiveKit calls, no mail/calendar apps, and
`table:` live views fall back to polling because the app is built with no BaaS realtime token.

The bundles are built keyless (`VITE_BAAS_API_KEY`, `VITE_BAAS_KONG_KEY`, `VITE_BAAS_REALTIME_TOKEN`
and the IDE URL are forced empty in `docker-compose.public.yml`) under the `:public` image tags, so
the `:local` images are never overwritten. On the bridge, `OSIONOS_AGENT_CLAUDE`,
`OSIONOS_IDE_ALLOWED_SUBJECTS`, `OSIONOS_RUNNER_URL` and `OSIONOS_SQL_RO` are forced empty, and
nginx answers 404 to `/api/agent/claude/stream` and rate-limits `/api/geocode` to 1 r/s, burst 5
(`infrastructure/tls/public.d/`; measured in a throwaway nginx: stream 404, 14 of 20 rapid
geocode requests 503).

## Order

1. `make public-env`, then edit `./.env.public`: `OSIONOS_ADMIN_EMAILS` (emails, or `none`) and a
   provisional `AUTH_TRUSTED_PROXY_HOPS`. Every key is documented in `.env.public.example`.
2. `make public-up` — rebuilds the five services as public (this recreates the running
   `track-binocle` containers; `PUBLIC_COMPOSE_EXTRA="file.yml"` layers an override such as a
   worktree build context), runs `verify --pre`, opens **443 only**, then verifies again and
   resets the Funnel itself if the second check fails.
3. Measure the real hop count from a request through the Funnel (the gateway logs
   `trusted proxy hops: N` at boot; the client address it derives must be the visitor's, not
   tailscaled's or an nginx's). Correct `AUTH_TRUSTED_PROXY_HOPS`, run `make public-up` again.
4. `make public-up PUBLIC_PORTS=all` opens 8443 and 10000 too; it refuses while
   `AUTH_TRUSTED_PROXY_HOPS` is empty.

`make public-verify` (or `PUBLIC_VERIFY_ARGS="--pre"`, `443`, `all`) prints PASS/FAIL/SKIP per
fact — node name, exposed ports, no secret in either public bundle, bridge and gateway
environment, the two edge probes, `.env.public` ignored and mode 600 — and exits 1 on any FAIL.
A SKIP (for example a secret unset in every env file) is a check that did not run, not a pass.

## Rollback

`make public-down` runs `tailscale funnel reset`: nothing is reachable from the internet. The
containers keep running on localhost, still in public configuration; `make link-frontends-start`
returns them to the local build.

## Limits

- tailscaled here runs `--state=mem:`: a restart drops the node name and the Funnel config. The
  name check then fails and `public-up` has to be run again.
- The bundle check greps for literal secret values; a split or encoded value is missed. The
  geocode check is rate-based and needs a fast host. Both are stated in
  `scripts/lib/public-verify.sh`.
- Behind the Funnel every client reaches nginx from tailscaled's loopback address, so the geocode
  bucket is shared by all visitors.
- grobase itself is reached over the existing link ([grobase-link](grobase-link.md)); this mode
  adds no exposure there.
