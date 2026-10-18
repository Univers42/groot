# 0020. Mail and Calendar ship public as static previews on a second Funnel node

- Status: accepted (Phase A only; the run steps below are the operator's)
- Date: 2026-10-18
- Deciders: devil (conditions MC1-MC14)

## Context

- The osionos app has Mail and Calendar tabs. Locally each frames an app on localhost and talks to a
  bridge that holds one Gmail or Google Calendar account in one file, with no authenticated route.
  On the public Funnel those tabs would frame the visitor's own localhost, and the bridges would be a
  stranger's route to one account and to the BaaS service role.
- A Tailscale node has one 443 and one 8443, and the main node already uses 443, 8443 and 10000.
  The Mail and Calendar origins therefore need their own node and hostname.
- Phase B (real accounts) is blocked, see `.out-of-scope/public-mail-calendar-provider-bridges.md`.

## Decision

- Mail and Calendar are built with `--target prod` (a static nginx image of `dist/`) and served as
  previews. No bridge container runs and no Vite dev server exists on the public path.
- `docker-compose.public.yml` adds `mail-web` and `calendar-web` (images
  `track-binocle/osionos-mail-web:public` and `...osionos-calendar-web:public`). They have no
  `env_file`, no volumes, `read_only: true` with tmpfs for the nginx cache, `/run` and `/tmp`,
  `mem_limit: 64m`, and sit only on the `apps-static-net` network, which is `internal: true`.
- `infrastructure/tls/public.d/apps.conf.template` adds one TLS vhost on `127.0.0.1:3102` (Mail) and
  `127.0.0.1:3103` (Calendar). It returns 444 unless the `Host` is exactly the configured origin, sets
  the CSP, nosniff, no-referrer and HSTS on every response (`always`), hides ACAO and X-Frame-Options,
  and answers dotfile paths with 404. `nginx.conf` and the existing vhosts are untouched.
- A second userspace tailscaled (`scripts/public-node.sh`, node `osionos-apps`) keeps its state on disk
  under `${XDG_STATE_HOME:-~/.local/state}/tailscale-osionos-apps/` (mode 700), has no SOCKS or HTTP
  proxy listener, and reads its auth key from stdin only. `scripts/public-funnel.sh up apps` runs, on that
  node's socket, `tailscale funnel --bg --https=443 https+insecure://127.0.0.1:3102` and
  `--https=8443 https+insecure://127.0.0.1:3103`, after `verify --pre`. `down` resets both nodes.
- The main `FUNNEL_MAP` stays `443:4322 8443:3001 10000:4000`.
- The osionos app is built with `VITE_MAIL_APP_URL` and `VITE_CALENDAR_APP_URL` set from
  `PUBLIC_MAIL_ORIGIN` and `PUBLIC_CALENDAR_ORIGIN` (empty when unset, which hides the tabs).
- `verify` gains `exposure2`, `nobridge`, `nodev`, `apphdrs`, `bundle2`, `appurls` and `appenv`
  (`scripts/lib/public-verify-apps.sh`).
- The marketplace rows are changed by a SQL script the user runs (one transaction, ROLLBACK unless
  `-v apply=1`). It is kept outside the tree and was never run against a database.

## Conditions (devil)

| | Condition | Proven by |
|---|---|---|
| MC1 | no bridge container; no Funnel target on 4100 or 4200 | `nobridge` |
| MC2 | dev-server paths and token files answer 404 | `nodev` |
| MC4 | CSP (`frame-ancestors` only the main origin on 8443), nosniff, no-referrer, HSTS, no CORS | `apphdrs` |
| MC5 | no client secret, JWT, `service_role`, `localhost:` or env-file secret in either image | `bundle2` |
| MC8 | the osionos bundle holds both origins and no localhost link | `appurls` |
| MC9 | marketplace launchUrls point at the new origins; Desktop hidden | the SQL script (user-run, not in the tree) |
| MC10 | locked static containers | the compose overlay; `appenv` for the environment |
| MC11 | second node durable, no `mem:`, `down` resets both | `public-node.bats`, `exposure2` |
| MC13 | no `SMTP_`, `GOOGLE_`, `VAULT_`, `KONG_`, `SERVICE_ROLE_KEY`, `JWT_SECRET` in the containers | `appenv` |

## Consequences

- Mail and Calendar are previews: no account is connected and nothing is stored server-side.
- With either origin set, `up 443` and `up all` fail their post-open verify (and reset) until the apps node
  serves, because `exposure2` and `appenv` then need it.
- Mail's CSP carries `style-src 'unsafe-inline'`; Calendar's does not (measured with Playwright against
  the built bundles). Mail was exercised only lightly (two clicks), so a style it applies later may be
  blocked; the CSP is a header, so the fix is one line in the vhost.
- Not verified: that the second node gets the `funnel` capability (needs the tagged key's ACL, only
  visible once tailscaled runs); the `funnel status --json` shape on that node (assumed equal to the main
  node's); that the osionos UI hides an app with `published=false` or an empty launchUrl; the prod
  marketplace rows; the `osionos.draw` row, which still holds a localhost:3001 launchUrl.
- The `healthcheck`, `cap_drop` and similar hardening on the static containers were not tested.

## Operator steps (none can run from an agent shell)

- Mint a single-use, tagged, pre-approved, non-ephemeral key; `scripts/public-node.sh start`.
- Set `PUBLIC_MAIL_ORIGIN` and `PUBLIC_CALENDAR_ORIGIN` in `.env.public`; rebuild the three images.
- `scripts/public-funnel.sh up apps`, then the main node's `up`.
- Run the marketplace SQL script as a dry run, read it, then apply.
