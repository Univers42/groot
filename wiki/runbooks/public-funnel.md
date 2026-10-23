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

The bundles are built keyless (`VITE_BAAS_API_KEY`, `VITE_BAAS_KONG_KEY`, `VITE_BAAS_REALTIME_TOKEN`,
the IDE URL and the mail, calendar and whiteboard URLs are forced empty in `docker-compose.public.yml`) under the `:public` image tags, so
the `:local` images are never overwritten. On the bridge, `OSIONOS_AGENT_CLAUDE`,
`OSIONOS_IDE_ALLOWED_SUBJECTS`, `OSIONOS_RUNNER_URL`, `OSIONOS_SQL_RO`, `OSIONOS_IDE_TOKEN_SECRET` (the IDE mint then answers 404) and
`OSIONOS_IDE_ACCESS` are forced empty, and
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

Surface checks (`scripts/lib/public-verify-surfaces.sh`):

- `bridge-env` also fails when `OSIONOS_IDE_TOKEN_SECRET` is set on the bridge.
- `ide-access` fails when `OSIONOS_IDE_ACCESS` on the bridge, or on `osionos-ide-server` when the
  project runs one, is anything but unset, `allowlist` or `off` (so `verified` and `approved` are
  red). The message names the key and the mode, never a secret. No IDE route ships in public, so
  a mode that admits every verified account is a shell on the shared host.
- `bundle-links` scans the served app image and fails on any `http(s)://localhost:PORT`, listing
  the distinct `localhost:PORT` values. Such a link makes the visitor's browser frame their own
  machine in the Mail, Calendar and Whiteboard tabs. An image that cannot be scanned is a FAIL.
  It misses a URL built at run time or written as `127.0.0.1`.

## Website on Vercel, entry on the data-center node

Running since 2026-10-21: the website is prismatica on Vercel (`PUBLIC_SITE_ORIGIN`) and the
Funnel entry is the born2root data-center VM's node (`PUBLIC_ORIGIN=https://baas.tail10f2ea.ts.net`),
whose 443 already serves grobase's WAF. The containers still run on this host; the VM reaches the
host's loopback at `10.0.2.2` (QEMU user networking). `public-up` opens the Funnel on the local
tailscaled only, so on the VM the mappings are set by hand (`ssh b2b`):

```sh
tailscale funnel --bg --https=8443 https+insecure://10.0.2.2:3001
tailscale funnel --bg --https=8443 --set-path=/api/auth https+insecure://10.0.2.2:8787/api/auth
tailscale funnel --bg --https=8443 --set-path=/api/newsletter https+insecure://10.0.2.2:8787/api/newsletter
tailscale funnel --bg --https=10000 https+insecure://10.0.2.2:4000
```

Vercel rewrites `/api/auth/*` and `/api/newsletter/*` to `:8443`, and `/auth`, `/query` and
`/storage` to the VM's 443 (`apps/opposite-osiris/vercel.json`).

- Close with `tailscale funnel --https=8443 off` and `--https=10000 off` on the VM. Never
  `make public-down` against it: `funnel reset` also closes 443, grobase's entrance.
- `verify --pre` fails `node-name` and `nobridge` (Funnel targets unreadable) because it reads this
  host's tailscaled; check the VM's mappings with `tailscale serve status` there.
- `AUTH_TRUSTED_PROXY_HOPS=2`, measured with a forged `X-Forwarded-For`: tailscaled replaces the
  header with the address it sees, so the forgery is dropped, and every visitor who comes through
  Vercel arrives as a Vercel egress address, one shared rate-limit bucket.

## Mail and Calendar previews (second node)

Static previews of Mail and Calendar, no bridge and no account, served by a second Funnel node
(`osionos-apps`) on its own hostname: Mail on 443, Calendar on 8443
([ADR 0020](../../docs/adr/0020-mail-and-calendar-ship-public-as-static-previews-on-a-second-funnel-node.md)).

1. Mint a Tailscale auth key: single-use, tagged (the tag's ACL needs the `funnel` nodeAttr),
   pre-approved, NOT ephemeral. Then `pbpaste | bash scripts/public-node.sh start` (the key is read
   from stdin only). `bash scripts/public-node.sh status` prints the DNS name and the Funnel ports.
   `public-node.sh stop` resets that node's Funnel before it stops the daemon; the daemon's output is
   dropped unless `PUBLIC_APPS_LOG=1` (then `tailscaled.log` in the node's state dir, which grows).
   `bash scripts/public-node.sh autostart` then hands the node to `osionos-apps-node.service` (a
   systemd user unit; at boot only with linger on), which restarts it after a reboot or a crash with
   its Funnel; `autostart-off` removes the unit. A start that fails keeps the Funnel config, so a
   slow boot never unpublishes the apps; only `stop` closes it. The unit runs the binaries named by
   `TAILSCALED_BIN` / `TAILSCALE_BIN` at the time `autostart` ran (a system install:
   `/usr/sbin/tailscaled`, `/usr/bin/tailscale`).
2. In `.env.public` set `PUBLIC_MAIL_ORIGIN=https://<node dns name>` and
   `PUBLIC_CALENDAR_ORIGIN=https://<node dns name>:8443` (both or neither; the host must not be
   `PUBLIC_ORIGIN`'s).
3. Open the apps node FIRST: `make public-up PUBLIC_PORTS=apps` (rebuilds the images, the osionos
   app with both URLs among them, then runs `bash scripts/public-funnel.sh up apps`: `verify --pre`,
   443 -> 127.0.0.1:3102 and 8443 -> 127.0.0.1:3103 on the apps node, then verifies again).
   `up apps` refuses to run unless both origins are set.
4. Only then `make public-up` (443) or `PUBLIC_PORTS=all`. With the origins set, the post-open
   verify of the main node includes the apps checks, so while the apps node is not serving it FAILs
   and that failure resets BOTH nodes.

`down` resets both nodes. The marketplace rows are changed by a user-run SQL script (dry run unless `-v apply=1`).

## Rollback

`make public-down` runs `tailscale funnel reset` on both nodes and prints which it reset; exit 1 means
one could not be (an apps node with state on disk whose socket is silent): start it or check it with
`status`, nothing is claimed closed until it exits 0. The
containers keep running on localhost, still in public configuration; `make link-frontends-start`
recreates them from the local build (not exercised in this change).

## Limits

- Funnel needs tailscaled to have a state dir, where it keeps the certificate. The born2root seat
  starts it with `--state=mem:` alone; every visitor then gets `SSL_ERROR_INTERNAL_ERROR_ALERT`
  and tailscaled logs `no TailscaleVarRoot`. Restart it with `--state=<dir>/tailscaled.state
  --statedir=<dir>/var` and run `public-up` again; verify's `tls` check fails until then. A
  daemon whose state is in memory also drops the node name and the Funnel config on restart.
- A re-registered node (same name, new node) can be unreachable through some Funnel relays for
  several minutes: each `*.ts.net` relay address answers on its own, and a stale one closes the
  connection right after the ClientHello. `public-down` then `public-up` refreshed one relay of
  three within a minute (2026-10-18).
- The bundle check greps for literal secret values; a split or encoded value is missed. The
  geocode check is rate-based and needs a fast host. Both are stated in
  `scripts/lib/public-verify.sh`.
- Behind the Funnel every client reaches nginx from tailscaled's loopback address, so the geocode
  bucket is shared by all visitors.
- grobase itself is reached over the existing link ([grobase-link](grobase-link.md)); this mode
  adds no exposure there.
