# grobase link — reach grobase wherever it runs

The root frontends (`track-binocle` compose project) find grobase by container name on the
`mini-baas_mini-baas` network: `mini-baas-kong`, `mini-baas-redis`, `mailpit`,
`mini-baas-realtime`. The link keeps those names valid when grobase is not on this Docker
daemon — on the born2root VM, a LAN box, a VPS, a cloud host — without sudo, without editing
the frontends and without a hardcoded address. One target, resolved at `make link` time.

## Modes

| Mode | Picked when | What is opened | Source |
|---|---|---|---|
| `local` | `mini-baas-kong` runs on this daemon | Nothing. Docker DNS already resolves the names; a running relay is removed | `scripts/grobase-link.sh:155-169` (`cmd_up`), `infrastructure/makes/grobase-link.mk:30-32` |
| `ssh` | The target is `ssh://…`, an ssh alias, `user@host`, or a bare host whose `docker ps` over ssh shows `mini-baas-kong` | One ssh ControlMaster; one unix-socket forward per grobase port into `LINK_DIR`; the `grobase-link` relay container that serves the names | `scripts/grobase-link.sh:97-140`, `docker-compose.grobase-link.yml` |
| `direct` | The target is `http(s)://host[:port]`, or a bare host that answers on `:8000` or `:443` from a container | The relay with a single route to Kong (TLS when https, verified against the system CA bundle) | `scripts/grobase-link.sh:142-153` (`up_direct`) |

`GROBASE_TARGET=auto` (the default) takes `local` when this daemon has grobase, else probes every
`Host` of `~/.ssh/config` (no wildcards) and every born2root VM whose `ports.env` records an
`ssh=` forward, in that order, and takes the first one that has it
(`scripts/lib/grobase-link-target.sh:40-78`, `ssh_candidates` + `resolve_auto`). A bare host name
is tried as ssh, then `http://host:8000`, then `https://host` (`resolve_host`, `:79-89`).

## Configuration — which kind of connection this machine uses

The scheme of `GROBASE_TARGET` is the kind: `local`, `ssh://…`, `http(s)://…`, or `auto` /
a bare host to let the script find out. It is read in this order, first hit wins
(`scripts/grobase-link.sh:20-31`, `setting`; `infrastructure/makes/grobase-link.mk:6-15`):

1. The environment, which is also where `make link GROBASE_TARGET=…` puts it — one run.
2. `./.env.grobase-link` at the repo root — this machine's standing choice. Git-ignored
   (`.gitignore:5`); `.env.grobase-link.example` documents every key; `KEY=value`, no quotes.
3. The default: `auto`.

`bash scripts/grobase-link.sh conf [KEY]` prints what the next `make link` will use, and the
Makefile reads `GROBASE_LINK_HOST_PORT` from it rather than parsing the file a second time. The
same three steps apply to `GROBASE_LINK_HOST_PORT` and `GROBASE_REMOTE_DIR`; `GROBASE_LINK_DIR`,
`GROBASE_LINK_CONF` (another settings file, used by the tests) and `B2B_DIR` are environment only.

The direction does not matter: whichever machine runs the frontends runs `make link` pointing at
the machine that runs grobase. Exposing the frontends themselves to other machines is a separate
knob, `TRACK_BINOCLE_BIND_ADDR` (`infrastructure/makes/grobase.mk:127`,
`infrastructure/scripts/detect-bind-addr.sh`).

## Commands

| Command | Does | Source |
|---|---|---|
| `make link [GROBASE_TARGET=…]` | Resolve the target (the command line, else `./.env.grobase-link`, else `auto`), open the path, copy that grobase's secrets into `./.env.local`, start (or, in local mode, remove) the relay, then `link-verify` | `grobase-link.mk:31-42` |
| `make link-verify` | The connectivity test (next section): one request per grobase name from inside every frontend on grobase's network, the browser's path through the TLS edge, then the browser-trust check; exit 1 on any FAIL | `grobase-link.mk:48-50`, `scripts/lib/grobase-link-verify.sh` |
| `make link-status` | Exit 0 when the path is open and Kong answers through it | `grobase-link.mk:44-46`, `grobase-link.sh:173-194` |
| `make link-down` | Stop the relay, cancel the forwards, close the ssh master, forget the state | `grobase-link.mk:52-55` |
| `make link-models-migrate` | What `make all` does with `models-migrate`, over the link: groot's `models/*.sql` land in the postgres of the linked grobase (local = this daemon; ssh = the target's daemon through docker's ssh transport, `grobase-link.sh docker-host`; direct = refused, no database). Idempotent; ~2 min over ssh. Runs inside `link-frontends-up` | `grobase-link.mk` (`link-models-migrate`), `scripts/apply-models-migrations.sh` |
| `make link-frontends-up` | `make link`, then `frontends-up` with the relay overlay, the vhost on `LINK_VHOST_HTTPS_PORT`, then `certs-trust-user` (the CA into this user's browser stores, no sudo), then `link-verify` from inside every frontend | `grobase-link.mk:57-64` |
| `make link-healthcheck` | `link-verify`, then the stack healthcheck with the backend probed through the host loopback copy of Kong | `grobase-link.mk:66-73` |
| `make link-e2e [E2E_SPECS=specs/<file>]` | `link-healthcheck`, then the Playwright smoke (`tests/e2e/run.sh`, pinned container, `--network host`) against the frontends served here through the linked grobase; the stack must already be up | `grobase-link.mk` (`link-e2e`), `tests/e2e/run.sh` |
| `bash scripts/grobase-link.sh conf [KEY]` | The effective settings, one or all as `KEY=value`; exit 1 on an unknown key | `grobase-link.sh:222-230` |
| `bash scripts/grobase-link.sh --help` | The verbs (`up down status env verify mode conf`), the settings, the exit codes (0 ok, 1 failure or misuse) | `grobase-link.sh:232-252` |

| Setting | Default | Meaning |
|---|---|---|
| `GROBASE_TARGET` | `auto` | `local` · `ssh://[user@]host[:port]` · `<alias \| user@host \| host>` · `http(s)://host[:port]` |
| `GROBASE_LINK_HOST_PORT` | `28000` | Kong copy on `127.0.0.1` for host tools and `link-healthcheck`; `0` disables |
| `GROBASE_REMOTE_DIR` | `/opt/grobase` | Where the remote grobase's `.env` is (ssh mode, `env` verb) |
| `GROBASE_LINK_DIR` (env only) | `$XDG_RUNTIME_DIR/track-binocle-link` | Sockets, routes and state; `0700`; bind-mounted into the relay as `/link` |
| `GROBASE_LINK_CONF` (env only) | `./.env.grobase-link` | The settings file |
| `LINK_VHOST_HTTPS_PORT` (make only) | `9443` under rootless Docker, else `443` | Rootless cannot bind below `ip_unprivileged_port_start` (`grobase-link.mk:16-18`) |

## The connectivity test — `make link-verify`

Every `make link`, `link-frontends-up` and `link-healthcheck` ends (or, for the healthcheck,
starts) with it, whatever the kind of connection, so a link that opened but does not carry
traffic is reported before anything is started against it. `scripts/lib/grobase-link-verify.sh`:

1. **What to reach**: the `SERVICES` table of `grobase-link.sh` (`relay port`, `service`,
   `container port`, `name the frontends use`, `probe kind`) filtered by `LINK_DIR/routes` —
   all five names in local mode, the relayed ones in ssh mode, Kong alone in direct mode.
2. **From where**: every container on `mini-baas_mini-baas` that is neither `mini-baas-*` nor
   the relay (`link_consumers`): the frontends, as `docker network inspect` lists them.
3. **How**: one `alpine/socat` probe container per frontend, in parallel, started with
   `--network container:<frontend>` so it uses that frontend's DNS and network namespace and
   sends one request per name: `GET / HTTP/1.0` (`HTTP/*` expected; Kong's own `/` 404 counts),
   `PING` to Redis (`+PONG`, or `-NOAUTH`), nothing to smtp (the `220` banner). The sender keeps
   its side open 1 s: an immediate half-close makes realtime drop the request unanswered.
4. **The browser's path**: `https://127.0.0.1:<published 8444>/auth/v1/health` on this host —
   nginx (`local-https-proxy`) to `mini-baas-kong` by name; Kong's 401 without an apikey is a pass.
   Skipped with a note while the edge is not running; the local CA is used when present.
5. **The browser's trust**: `scripts/certs-trust-user.sh --check` over every browser NSS store of
   this user (`LOCAL_CA_CERT` is `apps/grobase/certs/track-binocle-local-ca.pem`). A stale or
   missing store is a FAIL; before `make certs` there is no CA, and it is a note. This is what
   `curl --cacert` in step 4 cannot show: curl passes while Firefox and Chrome warn. It does not
   relaunch a browser, and a running one keeps its old view until relaunched.

Output is the matrix, one line per frontend and name, `ok` or `FAIL` with the first line of the
answer; exit 1 on any FAIL, exit 0 with a note when no frontend runs yet. Its pure parts (the
specs per mode, the consumer filter, the verdicts, the exit codes) are
`scripts/tests/grobase-link-verify.bats`, 5 tests, run as the other suite below.

## ssh mode, step by step

1. **Master.** `ssh -o ControlMaster=yes -o ControlPersist=yes -o ClearAllForwardings=yes -N -f <target>`
   (`open_master`, `grobase-link.sh:97-103`). One authenticated connection; every later
   operation is `ssh -F /dev/null -S <ctl> -O forward|cancel|check|exit`, so no re-auth and
   none of the user's config forwards replay.
2. **Where each service listens on the remote.** `docker inspect` of every `mini-baas-*`
   container over the master gives, per tcp port, the published host port (rewritten to
   `127.0.0.1`) or, when nothing is published, the container IP on its first network
   (`remote_endpoints`, `:57-68`).
3. **One unix socket per port.** For each row of `SERVICES` (`:38-42`: kong 8000, redis 6379,
   mailpit 8025 and 1025, realtime 4000) a `-L $LINK_DIR/<svc>-<port>.sock:<ip:port>` forward
   (`up_ssh`, `:119-140`). A missing service is reported and its name refuses connections
   instead of pointing at something else.
4. **The relay.** `alpine/socat:1.8.0.1` reads `/link/routes` (`<port> <socat address>`) and
   runs `socat TCP-LISTEN:<port>,fork,reuseaddr <address>` per line; it carries the aliases
   `mini-baas-kong mini-baas-redis mini-baas-mailpit mailpit mini-baas-realtime` on
   `mini-baas_mini-baas` (`docker-compose.grobase-link.yml:13-45`). Its healthcheck is a real
   `GET /` to Kong through the relay (`:34`).
5. **Secrets.** `env` copies the remote `$GROBASE_REMOTE_DIR/.env` to `./.env.grobase-remote`
   (`umask 077`, refuses a file without `JWT_SECRET`) and runs `scripts/gen-local-env.sh` on it,
   `--sync` when `./.env.local` exists (`cmd_env`, `:195-218`). Values never reach a terminal.

Why unix sockets and not `-L 127.0.0.1:port`: rootless Docker here runs with
`--disable-host-loopback`, so a container cannot reach the host's `127.0.0.1`; a socket in a
bind-mounted directory it can. Why not an ssh port forward inside the relay container: the
relay would then hold the user's key. Why the relay instead of `extra_hosts`: the frontends
resolve names on the Docker network, and a Docker alias is the only thing that answers there
without touching the frontends' compose files.

## Guards

| Guard | Why | Source |
|---|---|---|
| `make backend-up` refuses while the relay runs | Two containers must not answer to `mini-baas-kong`; `make link-down` first | `infrastructure/makes/grobase.mk:63-66` |
| `certs-trust-user`, not the system store, in `link-frontends-up` | The system store needs sudo; the browser stores do not. The old `TRACK_BINOCLE_CERT_TRUST=skip` there was dead and is dropped | `infrastructure/makes/grobase-link.mk`, `scripts/certs-trust-user.sh` |
| `MINI_BAAS_WAF_TLS_GID=none` in the link targets | The grobase WAF (gid 101) is the only reader that needs the TLS key group-readable, and it runs where grobase runs. On NFS without sudo the grant cannot be done, and `chgrp` to the user's primary group would hand the key to the whole promo | `apps/grobase/scripts/certs/generate-localhost-cert.sh:30-39`, `grobase-link.mk:15-18` |

## Verified — 2026-10-08, host rootless Docker 28.1.1, target `b2b` (born2root VM over ssh)

Probes run from a container on the frontends' network, the way the frontends connect:
`docker run --rm --network mini-baas_mini-baas curlimages/curl:8.12.1 -sS -m 10 -H "apikey: $SB_KONG_KEY" <url>`.

| Through the relay | Result |
|---|---|
| `http://mini-baas-kong:8000/auth/v1/health` with apikey | `HTTP 200` `{"version":"v2.188.1","name":"GoTrue",…}` in 0.005 s |
| same, no apikey | `HTTP 401` `{"message":"No API key found in request"}` |
| `http://mini-baas-kong:8000/rest/v1/` with apikey | `HTTP 200`, PostgREST swagger (`"version":"12.2.3"`) |
| `http://mini-baas-kong:8000/` | `HTTP 404` `{"message":"no Route matched with those values"}` — Kong's own answer, the relay healthcheck relies on it |
| `http://mailpit:8025/api/v1/info` | `HTTP 200` `{"Version":"v1.31.4",…}` |
| `mailpit:1025` (socat, read 120 bytes) | `220 … Mailpit ESMTP Service ready` |
| `mini-baas-redis:6379` `PING` | `+PONG` |
| `http://mini-baas-realtime:4000/v1/health` | `HTTP 200` `{"status":"ok",…}`; `/health` is `404` — the server's routes are `/v1/*` (`apps/grobase/infra/docker/services/realtime/realtime-agnostic/crates/realtime-server/src/server.rs:242-245`) |
| host `http://127.0.0.1:28000/auth/v1/health` with apikey | `HTTP 200` |

`bash scripts/grobase-link.sh status` → `ssh: master to b2b up; Kong through …/kong-8000.sock answers HTTP 404`, exit 0.
Parsers, settings precedence and exit codes: `scripts/tests/grobase-link.bats`, 11 tests,
`scripts/tests/grobase-link-verify.bats`, 5 tests, and the `get_env` reader in
`scripts/tests/envfile.bats`; run with
`docker run --rm -v "$PWD:/code" -w /code bats/bats:1.11.1 scripts/tests/grobase-link.bats scripts/tests/grobase-link-verify.bats scripts/tests/envfile.bats`.

### Browser trust, 2026-10-08

`make certs-trust-check` before the fix, `make certs-trust-user`, and the check after (the 17:06
CA regeneration left 7 stores stale and 1 missing; snap Chromium's revision 3551 had no store):

```text
$ make certs-trust-check
FAIL chrome   /home/dlesieur/.pki/nssdb  stale
FAIL chrome   /home/dlesieur/snap/chromium/current/.pki/nssdb  stale
FAIL firefox  /home/dlesieur/snap/firefox/common/.mozilla/firefox/pqdn9c63.default-release-1  stale
FAIL firefox  /home/dlesieur/.var/app/org.mozilla.firefox/config/mozilla/firefox/2vgnvz7b.default  missing
[certs] 8 browser store(s) do not hold the current CA; run: make certs-trust-user, then relaunch the browser
make: *** [infrastructure/makes/certs.mk:72: certs-trust-check] Error 1

$ make certs-trust-user
[certs] chrome /home/dlesieur/.pki/nssdb: CA imported (was stale)
[certs] firefox /home/dlesieur/snap/firefox/common/.mozilla/firefox/pqdn9c63.default-release-1: CA imported (was stale)
[certs] firefox /home/dlesieur/.var/app/org.mozilla.firefox/config/mozilla/firefox/2vgnvz7b.default: CA imported (was missing)
[certs] a browser is running: it trusts the new CA only after a relaunch (quit Firefox / Chrome and reopen; vendor/born2root/setup/host/restart_browsers.sh does it with session restore)

$ make certs-trust-check
ok   chrome   /home/dlesieur/.pki/nssdb  current
ok   chrome   /home/dlesieur/snap/chromium/current/.pki/nssdb  current
ok   firefox  /home/dlesieur/snap/firefox/common/.mozilla/firefox/pqdn9c63.default-release-1  current
[certs] every browser store holds the current CA (EC:EE:6E:11:28:10:6F:BC:99:F1:EA:60:3C:B7:E9:7A:0F:99:CC:32:E8:7C:95:B7:8F:CE:96:12:20:F6:F1:FC)
```

Tail of `make link-verify` (23:36, 8.9 s):

```text
  track-binocle-osionos-bridge-1         ok   mini-baas-realtime:4000  HTTP/1.0 200 OK
  ok   edge  https://127.0.0.1:8444/auth/v1/health  Kong HTTP 401
[certs] every browser store holds the current CA (EC:EE:6E:11:...:F1:FC)
  ok   chrome   /home/dlesieur/.pki/nssdb  current
  ok   firefox  /home/dlesieur/snap/firefox/common/.mozilla/firefox/pqdn9c63.default-release-1  current
[grobase-link] verify: 4 frontends reach grobase through the ssh link to ssh://b2b
```

Headless, fresh profiles holding only the imported store, no `--ignore-certificate-errors`: Google
Chrome 149 (deb, `~/.pki/nssdb`) rendered `https://localhost:4322/` (title "Prismatica — Everything.
One Space.") and `https://localhost:3001/` (osionos gate) with no certificate error; snap Firefox
(profile `pqdn9c63.default-release-1`) rendered both; snap Chromium 154 failed with
`ERR_CERT_AUTHORITY_INVALID` until the store was recreated under the new revision, then rendered
`4322`. `docker ps`: 12 track-binocle containers, all `(healthy)` (`livekit` and `drawnosaurus-*`
gained healthchecks in `docker-compose.yml`).

### Every kind through `make link`, 2026-10-08 23:0x (each run ends with `link-verify`)

| `GROBASE_TARGET` | Resolved as | Result |
|---|---|---|
| `ssh://b2b` (from `./.env.grobase-link`) | ssh, alias | exit 0 in 24 s; `verify: 4 frontends reach grobase through the ssh link to ssh://b2b` |
| `auto` | `probing b2b` → ssh `b2b` | exit 0 in 24 s; same matrix |
| `b2b` | bare alias → ssh | exit 0 in 25 s; same matrix |
| `ssh://dlesieur@127.0.0.1:4242` | ssh, user@ip:port | exit 0 in 23 s; `closing the master to b2b`, new master, same matrix. Needed a current `known_hosts` entry first: the VM's host key had changed since `[127.0.0.1]:4242` was recorded (`ssh-keygen -R '[127.0.0.1]:4242'`, then one `ssh -o StrictHostKeyChecking=accept-new`); the alias block disables that check, the bare form does not |
| `local` | guard | exit 1 in 1 s: `no mini-baas-kong on this daemon`; the ssh link stayed up (`link-status` exit 0) |
| `https://dlesieur42.tail10f2ea.ts.net` | direct | exit 1 in 4 s: `does not answer from a container of this daemon` — campus DNS returns NXDOMAIN for `*.ts.net` and this host is not on the tailnet; the ssh link stayed up (`up_direct` checks before it closes anything) |
| `make link-healthcheck` after the restore | | exit 0 in 10 s: the matrix, then the stack healthcheck (`auth-gateway-https-200`, bridge `{"ok":true}`, website, osionos, drawnosaurus) |

The matrix each time: `track-binocle-auth-gateway-1`, `-local-https-proxy-1`, `-opposite-osiris-web-1`,
`-osionos-bridge-1` × `mini-baas-kong:8000` (`HTTP/1.1 404`), `mini-baas-redis:6379` (`+PONG`),
`mini-baas-mailpit:8025` (`HTTP/1.0 200`), `mailpit:1025` (`220 … Mailpit ESMTP Service ready`),
`mini-baas-realtime:4000` (`HTTP/1.0 200`), then `edge https://127.0.0.1:8444/auth/v1/health Kong HTTP 401`.
Those four are the containers on `mini-baas_mini-baas`; `osionos-app`, `livekit` and `drawnosaurus-*`
are not on it (the browser reaches Kong through the vhost), so they are not probed.
Not exercised on this host: a working `direct` link (no Kong URL is reachable from a rootless
container here: `*.ts.net` does not resolve, QEMU hostfwds bind `127.0.0.1`, and Tailscale Funnel
would publish grobase) and a working `local` link (grobase would have to run on this daemon).

## What it gets wrong

- **Container-IP forwards go stale.** A remote service with no published port is forwarded to
  its container IP; recreate that container on the remote and the forward points at nothing
  until the next `make link` (`grobase-link.sh:12-14`).
- **`auto` is first-match, not nearest.** Each candidate costs up to 5 s when down. Set
  `GROBASE_TARGET` when two machines have grobase (`scripts/lib/grobase-link-target.sh:9-11`).
- **`direct` is Kong only.** Redis, Mailpit and realtime are not published behind a Kong URL:
  auth-gateway keeps sessions in memory, no mail is captured, bridge publishes are dropped
  (`up_direct`, `:151-152`). It cannot fetch secrets either; put that grobase's `.env` at
  `./.env.grobase-remote` before `make link`.
- **Do not probe Kong with `socat` on stdin.** Kong/nginx aborts a proxied request when the
  client half-closes after sending, so `printf … | socat - TCP:mini-baas-kong:8000` prints 0
  bytes for every upstream route while `curl` gets 200. Kong's own `/` 404 is unaffected,
  which is why the relay healthcheck and `link-verify` use it.
- **`link-verify` sends its own requests, not the frontend's.** It proves that the names
  resolve and the services answer from inside each frontend's network namespace; a frontend
  configured with another host name or port passes here and fails for real (`make
  link-healthcheck` and `make e2e` cover the frontends' own calls). A frontend that is not
  running is not probed: the test runs again at the end of `link-frontends-up`.
- **The 5 s probe budgets are for an idle host.** Under heavy load (browsers starting, containers
  being recreated) 3 of 5 names timed out from every frontend on 2026-10-08 at 23:30 and were
  green 2 minutes later. Re-run a FAIL under load before believing it.
- **The trust check is a file check, not a browser check.** It compares each NSS store with the CA
  file; it does not know whether a running browser has been relaunched since.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `no grobase found here, on an ssh alias or a born2root VM` | Nothing in `~/.ssh/config` or `disk_images/.vm_path.*` reaches a daemon running `mini-baas-kong` | `make link GROBASE_TARGET=ssh://user@host[:port]` (or the URL) |
| `ssh cannot open a master to …` | No key in `ssh-agent`, or a password prompt (`BatchMode=yes`) | `ssh <target>` once by hand; add the key to the agent |
| `frontends-up` fails to bind `127.0.0.1:4322`, `3001`, `4000`, `8787`, `3002`, `4100`, `3003`, `4200` | A QEMU `hostfwd` of a born2root VM holds the port. The `baas` profile (`vendor/born2root/profiles/server.toml`, `[network] forwards`) stopped forwarding those, `8000`, `8001` and `8025` on 2026-10-08: the link needs only the ssh forward, and a hostfwd never reaches a guest-loopback service anyway | `cat <vm dir>/ports.env` shows what the running VM forwards; edit the profile's `forwards` and `make qemu_restart B2B_CONFIG=profiles/server.toml`. Kong's host copy stays on `28000` so a grobase on this daemon can keep `8000` |
| `make certs`: `not readable by the WAF gid 101 (tried chgrp, setfacl, docker)` | NFS refuses `setfacl` and `chgrp` to a group the user is not in; rootless Docker maps gid 101 to the user's subgid range | `MINI_BAAS_WAF_TLS_GID=none make certs` — the link targets already set it |
| `[backend] the grobase-link relay is running` | By design | `make link-down`, then `make backend-up` |
| `drawnosaurus-wasm`: `cannot setuid to unmapped uid <uid> in user namespace` | A rootless daemon has no mapping for the host uid that `--user` asked for; the flag only exists to keep `engine/pkg` user-owned on a rootful daemon, where container root would write it as root | Fixed 2026-10-08: `DRAWNOSAURUS_RUN_USER` (`infrastructure/makes/drawnosaurus.mk`) drops `--user` when `docker info` reports `rootless`. Container root already is the invoking user there |
| `make link GROBASE_TARGET=local`: `no mini-baas-kong on this daemon` | The monolithic kind is taken as given but still checked: without grobase here the frontends would start against a name that resolves to nothing | `make backend-up` first, or set the target to the machine that runs grobase |
| `link-status`: `master to … is gone` | The remote rebooted or the network dropped; `ControlPersist` does not reconnect | `make link` again |
| Browser: certificate warning on `https://localhost:9443` (or any frontend) while `curl --cacert` is fine | A browser store holds an older CA: `make certs` on a fresh tree mints a new one | `make certs-trust-check` to see the stale or missing stores, `make certs-trust-user`, then relaunch the browser |
| Snap Chromium warns (`ERR_CERT_AUTHORITY_INVALID`) after a snap refresh | Its `HOME` is the revision directory behind `~/snap/chromium/current`; the new revision has no store | `make certs-trust-check` reports it missing; `make certs-trust-user` recreates it; relaunch |
