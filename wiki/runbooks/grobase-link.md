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
| `direct` | The target is `http(s)://host[:port]`, or a bare host that answers on `:8000` or `:443` from a container | The relay with one route to Kong: `GROBASE_CA_FILE`'s PEM goes to `LINK_DIR/ca.pem` and to the relay as `cafile=` (empty = the relay image's system store), the URL's name is resolved here (`getent ahostsv4`) and the relay connects to that IPv4 while verifying the certificate against the name. Redis and Mailpit are local stand-ins; realtime publishes reach the edge through the data center's service_role key | `scripts/grobase-link.sh` (`up_direct`), `scripts/lib/grobase-link-target.sh` (`resolve_ipv4`, `kong_addr`, `direct_routes`) |

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

## From another device — every path

The data center is the born2root QEMU VM `b2b` running grobase at `/opt/grobase` on a host whose
LAN address is `192.168.1.132` (wifi/ethernet `enp7s0`, DHCP). The VM runs grobase branch
`feat/b2b-datacenter` (commit `4eb80e0c`), the same commit groot pins at `apps/grobase`.

| Path | URL for the API / CLI (the WAF) | ssh target for `make link` |
|---|---|---|
| same host | `https://127.0.0.1:8443` or `https://localhost:8443` | `ssh://b2b` (alias = `dlesieur@127.0.0.1:4242`) |
| Tailscale (any network) | `https://dlesieur42-1.tail10f2ea.ts.net:8443` or `https://100.94.119.97:8443` | `ssh://dlesieur@100.94.119.97:4242` |
| LAN / wifi without Tailscale | `https://grobase.track-binocle.test:8443` after adding `192.168.1.132 grobase.track-binocle.test` to the device's hosts file | `ssh://dlesieur@192.168.1.132:4242` once `make link-autostart LAN_IF=enp7s0 LAN_SSH=1` put the VM's password ssh on the LAN; otherwise none |

A fresh clone for the data center: clone groot's `main` with `--recursive`. Plain `make all`
fast-forwards every submodule to its tracked branch (`sync-submodules-soft`); grobase and osionos
are pinned at their own `main`, so the commits the link needs (the bridge's realtime key, the WAF
content rule, an XSS fix) survive it. opposite-osiris is pinned ahead of its `main`, and the sync
moves the portal back to it. `make all SKIP_SYNC=1` builds exactly the pins; or skip `make all`
and run `make link` then `make link-frontends-up`.

**Same host** (the machine running the VM): `ssh://b2b` reaches it, and
`https://127.0.0.1:8443` is the WAF for the CLI and curl. Local mode does not apply — grobase runs
inside the VM, not on this host's docker daemon. For `make link` use `ssh://b2b` or the Tailscale
URL below (measured here); a direct URL that resolves to `127.x` points the relay, which runs in a
container, at itself.

**Tailscale, any network**: the WAF answers at `https://100.94.119.97:8443` (or the tailnet name
`https://dlesieur42-1.tail10f2ea.ts.net:8443`), and ssh reaches `ssh://dlesieur@100.94.119.97:4242`
once the device's key is on the VM — once, over Tailscale:
`ssh-copy-id -p 4242 dlesieur@100.94.119.97` (BatchMode never prompts for a password).

```sh
GROBASE_TARGET=https://100.94.119.97:8443
GROBASE_CA_FILE=./grobase-ca.pem
make link
```

**LAN / wifi without Tailscale**: add `192.168.1.132 grobase.track-binocle.test` to the device's
hosts file, then the same two keys with the URL as the name (the certificate does not carry the
LAN IP; it carries `*.track-binocle.test`, so the hosts file is the fix, not `curl -k`):

```sh
GROBASE_TARGET=https://grobase.track-binocle.test:8443
GROBASE_CA_FILE=./grobase-ca.pem
make link
```

Without `LAN_SSH=1` there is no ssh from the LAN path; over it the link is Kong plus the local
Redis and Mailpit stand-ins — the same direct mode `make link-e2e` passed on the Tailscale URL, but a link over the
LAN name itself has not been run (only the CLI has). Any of the three paths can be the
standing choice in `./.env.grobase-link` (git-ignored), or one run with
`make link GROBASE_TARGET=… GROBASE_CA_FILE=…`.

**The CA.** The WAF certificate is signed by the VM's own CA ("Track Binocle Local Development
CA", `/opt/grobase/certs/track-binocle-local-ca.pem` on the VM), a different CA from the one a
local `make certs` mints. Copy it to the device — the certificate is public, its key never leaves
the VM — then verify the copy against the value the data center prints for the same file:

```sh
scp -P 4242 dlesieur@100.94.119.97:/opt/grobase/certs/track-binocle-local-ca.pem ~/grobase-ca.pem
openssl x509 -noout -fingerprint -sha256 -in ~/grobase-ca.pem        # this device
openssl x509 -noout -fingerprint -sha256 -in /opt/grobase/certs/track-binocle-local-ca.pem  # VM
```

`GROBASE_CA_FILE` is the CA PEM, read from the environment then `./.env.grobase-link`; it is
copied to `LINK_DIR/ca.pem` and handed to the relay as `cafile=/link/ca.pem`. Empty means the
relay image's system store, which does not know this CA. Any copy channel works, the fingerprint
check is what makes it safe; never `curl -k` and never `verify=0`. The certificate's SANs are
`localhost`, `host.docker.internal`, `local-https-proxy`, `track-binocle.test`,
`*.track-binocle.test`, `127.0.0.1`, `dlesieur42-1.tail10f2ea.ts.net`, `100.94.119.97` and `::1`
— not the LAN IP, hence the hosts file. The IPv6 SANs come last on purpose: socat 1.8 (the relay
image, `alpine/socat 1.8.0.1`) aborts verification at the first IPv6 SAN when it connects to an
IPv4 literal, and grobase's cert generator orders them that way and re-issues an older cert.

**Secrets.** Direct mode cannot fetch them. The first `make link` over ssh (Tailscale) writes the
data center's `.env` to `./.env.grobase-remote` (mode 600), and later direct-mode links on that
device reuse it. Direct mode takes `REALTIME_PUBLISH_APIKEY` from `./.env.local`'s
`SERVICE_ROLE_KEY` (`publish_env`); with no key there it writes it empty, and the edge refuses
bridge publishes. Never
copy grobase secrets anywhere else, and never push them by hand.

**The grobase CLI** (`github.com/Univers42/grobase-cli`, main `5b5aac7` or later) works against
all four URLs, with the CA file you copied and secrets on stdin. One context can hold every path:
`--url` repeats, the first URL that answers `GET /auth/v1/health` is used (probe timeout
`GROBASE_PROBE_TIMEOUT`, default 2s), so the same context works at home on the LAN and away over
Tailscale:

```sh
grobase context add dc --url https://grobase.track-binocle.test:8443 \
  --url https://dlesieur42-1.tail10f2ea.ts.net:8443 --url https://100.94.119.97:8443 \
  --ca-file ~/grobase-ca.pem --yes
grobase signup --email <email> --password-stdin --anon-key-stdin   # first time; signed in at once (the VM auto-confirms)
grobase login --email <email> --password-stdin                     # later
grobase whoami
grobase doctor
eval "$(grobase context env dc)"                                   # GROBASE_TARGET / GROBASE_CA_FILE for make link
```

The credential store is mode 600; `doctor`'s only WARN is that the CA is not a system root.

**One context for every network, no CA file and no hosts file**: pin the WAF's leaf certificate
instead (`--pin-sha256`, the SHA-256 of the leaf's DER). A pin checks the certificate itself, not
the name in the URL, so the bare LAN IP works where `--ca-file` needs the hosts entry. Check the
value against the data center before trusting it, then list the paths in the order to try them:

```sh
ssh -p 4242 dlesieur@100.94.119.97 openssl x509 -noout -fingerprint -sha256 -in /opt/grobase/certs/localhost.pem
grobase context add b2b --url https://100.94.119.97:8443 --url https://192.168.1.132:8443 \
  --url https://127.0.0.1:8443 --url https://127.0.0.1:18443 \
  --pin-sha256 28e27b66a18a90d701a406fbb479c071a26d08cc2fe250a7bb329d327e780c7a
grobase doctor        # the reachability row names the URL in use: "200 in 3ms via https://…"
```

The four URLs are Tailscale (any network: home wifi, mobile data, another site's network, a
VPN that leaves the tailnet up), the LAN edge (same wifi, no Tailscale), the host itself, and an
ssh tunnel for a network that lets only ssh out:
`ssh -N -L 127.0.0.1:18443:127.0.0.1:8443 -p 4242 dlesieur@100.94.119.97` (the tunnel's far end
is the VM, whose WAF is on its own `127.0.0.1:8443`). A URL that does not answer costs
`GROBASE_PROBE_TIMEOUT` (2 s) before the next one. The pin breaks when the leaf is re-issued
(this one expires 2027-11-12): `doctor` then FAILs the TLS row with both fingerprints; check the
new one the same way, then `grobase context pin b2b`. Use CLI `2ffd17d` or later: before it `doctor` checked TLS on
the first URL even when an alternate was the one answering, so away from the LAN a working
context reported FAIL.

There is no path from the public internet without Tailscale: the WAF listens on the host's
loopback, Tailscale and LAN addresses only. Funnel or a router port-forward would publish it,
which is a decision for the owner, not a link setting.
`grobase api … --input FILE` labels the body `application/json` when it parses (the WAF refuses a
body with no content type). `grobase realtime subscribe pg/<table>/<inserted|updated|deleted>`
prints database changes live; `realtime publish` from a user session is dropped by the gateway
(a GoTrue token carries no `can_publish` claim, which the gateway defaults to false) — publish
needs a minted token.

**The LAN edge** is a host user unit, `grobase-lan-edge.service`, installed from
`infrastructure/systemd/user/grobase-lan-edge.service.in` by `make link-autostart LAN_IF=enp7s0`.
It forwards `<LAN IP>:8443` to the VM's https forward as QEMU actually bound it (`https=` in the
VM's `ports.env`). With `LAN_SSH=1` a second unit, `grobase-lan-ssh.service`, forwards
`<LAN IP>:4242` to the VM's sshd (`ssh=` in `ports.env`), which accepts passwords: anyone on the
LAN can try them (the owner's choice, 2026-10-12; `scripts/grobase-lan-edge.sh`). An install
without `LAN_SSH=1` removes that unit. Rollback: `make link-autostart-off`. It reads the address and the target at start; the heal timer below
restarts it when the LAN URL stops answering TLS, so a DHCP change or a VM restart on another port
heals within two minutes. Without linger it runs only while that user is logged in on the host.

## After a reboot — `make link-autostart`

The link's state lives in `XDG_RUNTIME_DIR`, so a reboot of this host loses it, and a restart of
the data center or a network drop kills the ssh master. `make link-autostart` (once per host)
installs three systemd user units from `infrastructure/systemd/user/`:

| Unit | Does |
|---|---|
| `grobase-link.service` | `make link` at boot, after `b2b-vm-baas.service`, retried every 20 s until the data center answers; the ssh master lives in its cgroup |
| `grobase-link-heal.timer` → `.service` | 3 min after boot, then every 2 min: `make link-status`; on failure restart `grobase-link.service`. With the LAN edge installed, also probe `https://<LAN IP>:8443/auth/v1/health` and restart the edge on no answer (`scripts/grobase-link-heal.sh`) |
| `grobase-lan-edge.service` | only with `LAN_IF=<iface>`: the LAN edge above |

The units start at boot only with linger on (`loginctl enable-linger $USER`; the script warns when
it is off). In local mode the heal does nothing. `make link-autostart-off` removes them and leaves
the link as it is. A unit that differs from the rendered one is backed up as `<unit>.bak-<time>`
before it is replaced.

## Commands

| Command | Does | Source |
|---|---|---|
| `make link [GROBASE_TARGET=…]` | Resolve the target (the command line, else `./.env.grobase-link`, else `auto`), open the path, copy that grobase's secrets into `./.env.local`, start (or, in local mode, remove) the relay, then `link-verify` | `grobase-link.mk:31-42` |
| `make link-verify` | The connectivity test (next section): one request per grobase name from inside every frontend on grobase's network, the browser's path through the TLS edge, then the browser-trust check; exit 1 on any FAIL | `grobase-link.mk:48-50`, `scripts/lib/grobase-link-verify.sh` |
| `make link-status` | Exit 0 when the path is open and Kong answers through it | `grobase-link.mk:44-46`, `grobase-link.sh:173-194` |
| `make link-down` | Stop the relay, cancel the forwards, close the ssh master, forget the state | `grobase-link.mk:52-55` |
| `make link-autostart [LAN_IF=<iface>]` | Install the systemd user units that re-open the link after a reboot, a data center restart or a network drop, and (with `LAN_IF`) the LAN edge; hands the open link over to the unit | `grobase-link.mk` (`link-autostart`), `scripts/grobase-link-autostart.sh` |
| `make link-autostart-off` | Remove those units; the link stays open | `scripts/grobase-link-autostart.sh remove` |
| `make link-models-migrate` | What `make all` does with `models-migrate`, over the link: groot's `models/*.sql` land in the postgres of the linked grobase (local = this daemon; ssh = the target's daemon through docker's ssh transport, `grobase-link.sh docker-host`; direct = refused, no database). Idempotent; ~2 min over ssh. Runs inside `link-frontends-up` | `grobase-link.mk` (`link-models-migrate`), `scripts/apply-models-migrations.sh` |
| `make link-demo-login-ensure` | What `make all` does with `demo-login-ensure`, over the link: the demo account in the linked grobase gets `./.env.local`'s `DEMO_LOGIN_PASSWORD` (`make demo-login` prints it); postgres through `grobase-link.sh docker-host`, Kong (only to create a missing account in LOCAL mode) through the link's loopback port. Idempotent. Runs inside `link-frontends-up` | `grobase-link.mk` (`link-demo-login-ensure`), `scripts/demo-login-ensure.sh` |
| `make link-live-data-ensure` | What `make all` does with `live-data-ensure`, over the link: `scripts/ensure-live-data-access.sh` verifies `./.env.local`'s `OSIONOS_BAAS_API_KEY` with the linked tenant-control (ssh mode: through `tenant-control-3022.sock`), or issues one, and re-stamps the demo rows owned by any other `api-key:` principal onto it — postgres `commerce agency`, mysql `ops`, mongo `activity`, mssql `finance` (`scripts/lib/owner-restamp.sh`). Idempotent; a converged grobase is one line. Runs inside `link-frontends-up` | `grobase-link.mk` (`link-live-data-ensure`) |
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
   instead of pointing at something else. tenant-control 3022 gets one more socket,
   `tenant-control-3022.sock`, in no route: only host scripts use it
   (`make link-live-data-ensure`), no frontend can name it.
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
Not exercised on this host: a working `local` link (grobase would have to run on this daemon).
A working `direct` link is no longer in that case — see the next subsection.

### Every path, 2026-10-11

Measured on the data center host, direct mode to `https://100.94.119.97:8443` with the VM's CA in
`GROBASE_CA_FILE`, against the linked grobase (`feat/b2b-datacenter`, `4eb80e0c`):

| What | Result |
|---|---|
| `make link` | `verify: 9 frontends reach grobase through the direct link to https://100.94.119.97:8443` |
| `make link-e2e` | 11 passed: mail and calendar embeds, whiteboard realtime between two contexts, graph, a second user's graph holding none of the first user's pages, landing sign-in |
| the same run before grobase rule 10110 | 2 passed, 9 failed — every page save 403 from the WAF |

The grobase CLI (`github.com/Univers42/grobase-cli`), with the VM's CA as `--ca-file`, exits 0 on
all four URLs: `context add`, `status`, `login`, `whoami` and `doctor` each of them
(`https://127.0.0.1:8443`, `https://100.94.119.97:8443`,
`https://dlesieur42-1.tail10f2ea.ts.net:8443`, and `https://grobase.track-binocle.test:8443` with
the hosts entry). The credential store is mode 600; `doctor`'s only WARN is that the CA is not a
system root.

2026-10-11, CLI `5b5aac7` from a fresh config in a clean alpine container (`--add-host` standing
in for the device's hosts file and MagicDNS): `signup` over the LAN name, `login` of that account
over the Tailscale name and IP; as the demo account a page created over the LAN, read over the
Tailscale name, edited over localhost, read back over the Tailscale IP; a context whose first URL
is a blackhole address fell through to the LAN URL; a LAN `realtime subscribe
pg/osionos_pages/updated` printed the rename made over the Tailscale IP. Playwright then found
that page in osionos (served here, linked over `ssh://b2b`).

The osionos data mounts, read with the app's key through the WAF and Kong over the Tailscale IP
after the data center was given the DynamoDB pieces (the four `.env` values of
`orchestrators/compose/base/data-plane.yml` and `control-plane.yml`, image
`grobase-data-plane-router:latest-dynamodb`): `/schema` answers 200 on all seven (DynamoDB IoT,
MSSQL finance, SQLite restaurant, MySQL ops, Mongo activity, Postgres commerce and agency), and
paging every row gives DynamoDB 250 / 1200 / 200 and SQLite 1045. Before, DynamoDB answered 400
`Unsupported engine 'dynamodb'` and SQLite 502 `no such table: restaurant`.

In osionos, linked over `ssh://b2b`, the demo account's account-wide data graph
(`/api/graph/data?scope=account`, read in Playwright after a real login) held 367 nodes, all notes:
the bridge's `http://mini-baas-query-router:4001` is not relayed. With `OSIONOS_QUERY_ROUTER_URL`
pointed at Kong's `/query/v1` (`publish_env`, osionos `0cfa815`) it holds 8738, from every engine:
DynamoDB 200 / 400 / 250, MSSQL 400 / 400 / 400 / 20 / 12, SQLite 8 / 8 / 65 / 300 / 400 / 56,
MySQL 400 / 400 / 40 / 400, Mongo 400 / 400 / 400 (the graph takes at most 400 rows per table).
The database list read the adapter-registry the same way, so it failed too; through Kong's
`/admin/v1` with the service key it lists the tenant's 7 databases over the ssh link and over the
Tailscale WAF (anon key 403, no key 401).

Not run: `make link` over the LAN name (only the CLI used it) and from a second device; the ssh
path relays the names with no WAF in the way, at the price of the device's key on the VM.

### After the host reboot, 2026-10-12

The host rebooted. The VM came back with its https forward on `127.0.0.1:8445`, not `8443`:
born2root's port check counted the LAN edge's `192.168.1.132:8443` as a conflict for a
`127.0.0.1` bind, and every LAN client hit a dead port. That check is fixed in born2root
(`utils/host_ports.sh`, `HOST_PORT_BIND`, branch `fix/host-port-bind`) and takes effect at the
VM's next start. Until then the LAN edge follows `ports.env`.

CLI `2ffd17d`, context `b2b` pinned as above, `grobase doctor` from this host:

| Path | `doctor` | Round trip |
|---|---|---|
| Tailscale `https://100.94.119.97:8443` | 8 pass, 1 warn (no credentials stored) | 3 ms |
| LAN edge `https://192.168.1.132:8443` | same | 43 ms |
| localhost `https://127.0.0.1:8445` | same | 2 ms |
| ssh tunnel over Tailscale `https://127.0.0.1:18443` | same | 4 ms |
| first URL a dead port, then an alternate | same, `via` names the alternate | 2 s (the probe timeout) |

Self-heal drill: `make link-down` at 01:11:25. The heal timer found `link-status` failing at
01:13:42 and restarted `grobase-link.service`, whose `make link` ended `verify: 6 frontends reach
grobase through the ssh link to ssh://b2b` at 01:13:52; `link-status` exit 0. DB1
(`tests/e2e/specs/db1-mounted-databases.spec.ts`) passed after the reboot with the 8738-node
graph.

### Afternoon, 2026-10-12: the link as another device runs it

- `make link-e2e` over `ssh://b2b`: 18 passed, 5 failed. The DB2 tests logged the demo user
  in once each and the gateway allows 8 logins a minute per IP (`RATE_LIMITS.login`); the
  helper then tried to register and surfaced the 422 instead of the 429. `tests/e2e/lib/session.ts`
  now logs each user in once per worker and reports a refused login as such: 23 passed.
- Direct link over Tailscale (`GROBASE_TARGET=https://100.94.119.97:8443`, the VM's CA):
  `verify: 9 frontends`; `make link-e2e` 22 passed, AC1 failed — the WAF refused
  `PATCH /rest/v1/osionos_bridge_identities` at score 10 (CRS 930120 read the key
  `json.profile.headline` as the file `.profile`). grobase `3411157f` drops that one rule on
  argument names of `osionos_*` writes (m227 passes in the VM, mutant included); the VM's WAF
  image was rebuilt (rollback tag `grobase-waf:pre-930120`): 23 passed.
- LAN ssh: password-only login (`PubkeyAuthentication=no`) from a bridge-network container,
  whose packets reach `192.168.1.132:4242` through the host's ufw like a LAN device's, through
  `grobase-lan-ssh.service`: `password-login-ok: dlesieur42`. The heal check finds both
  forwards answering.

## What it gets wrong

- **The LAN edge carries at most two ports and needs its host.** `grobase-lan-edge.service`
  forwards `<LAN IP>:8443` to the VM's https forward and, with `LAN_SSH=1`,
  `grobase-lan-ssh.service` forwards `<LAN IP>:4242` to its sshd: no Redis, no Mailpit. It reads its address and target at start, so a DHCP
  change or a VM restart on another port leaves it stale until the heal timer restarts it (up to
  two minutes), and without linger it runs only while that user is logged in on the host.
- **The heal is a two-minute poll on `link-status`.** The frontends can be cut off for up to two
  minutes plus one `make link` (10 s measured) after the data center or the network comes back.
  It sees only what `link-status` sees — the path is open and Kong answers — so a link whose
  relay is up but whose frontends fail for another reason is not re-opened. A link that cannot
  open (the VM still booting: `b2b-vm-baas.service` is done when QEMU starts, not when the guest
  answers) fails the unit, which re-runs `make link` every 20 s, forever, quietly:
  `journalctl --user -u grobase-link.service` is where to look.
- **Container-IP forwards go stale.** A remote service with no published port is forwarded to
  its container IP; recreate that container on the remote and the forward points at nothing
  until the next `make link` (`grobase-link.sh:12-14`).
- **`auto` is first-match, not nearest.** Each candidate costs up to 5 s when down. Set
  `GROBASE_TARGET` when two machines have grobase (`scripts/lib/grobase-link-target.sh:9-11`).
- **`direct` is not all five names, and it does not reach the data center's Redis or Mailpit.**
  Redis and Mailpit are local stand-ins (`grobase-link-redis`, `grobase-link-mailpit`,
  compose profile `link-direct`, no published ports), so sessions and captured mail stay on this
  device and grobase's own are never exposed (`direct_routes`). Realtime does go through the
  edge: `make link` writes `REALTIME_PUBLISH_URL=http://mini-baas-kong:8000/realtime` and
  `REALTIME_PUBLISH_APIKEY` (the data center's service_role key) into `./.env.local`
  (`publish_env`), the key that grobase's edge admits on its own on
  `/realtime/v1/publish`. The URL's host is resolved here and only as IPv4: a name that
  resolves to `127.x` on the device points the relay at itself — on the data center host use
  `ssh://b2b` or the Tailscale URL. It cannot fetch secrets, so a first ssh link must have written
  `./.env.grobase-remote`. And the WAF is still in the way on that path: rule 10110 lifts the
  injection rule families on POST/PATCH/PUT to `/rest/v1/osionos_<table>` only, so an
  attack-shaped value written to any other route, or a read that looks like one, is still
  refused with 403.
- **Behind a link osionos reaches query-router and the adapter-registry through Kong.** No remote
  kind relays either, so `make link` writes `OSIONOS_QUERY_ROUTER_URL=http://mini-baas-kong:8000/query/v1`
  and `OSIONOS_ADAPTER_REGISTRY_URL=http://mini-baas-kong:8000/admin/v1` (blank in local mode,
  which `docker-compose.yml` turns back into the container-DNS defaults). The bridge sends the anon
  key on the first and its service_role key on the second, the only key `/admin/v1` admits. Three
  limits come with it:
  - In direct mode the WAF sits on both routes: an insert whose value holds `console.log(` and
    `' OR 1=1` was refused 403, a plain one passed (2026-10-11, one sample per shape).
  - Direct mode reaches `/admin/v1` only because the data center runs without grobase's prod
    overlay: Kong sees the WAF's address, so its private-ranges `ip-restriction` admits a tailnet
    client (grobase N-23, `wiki/security/remediation-tracker-2025-07-14.md`). With the prod overlay
    (`KONG_TRUSTED_IPS`) a device linked over Tailscale gets 403 there and the database list fails;
    a LAN 192.168.x device keeps working. Opening 100.64.0.0/10 on that allowlist would open the
    service_role admin routes to the whole tailnet — that is grobase's decision, not the link's.
  - Kong limits both routes per client IP (`/admin/v1` 60/min, `/query/v1` 300/min), and every
    bridge behind one relay or one WAF is one client: past the limit the panel shows a 429 error.
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
| After this machine reboots: `track-binocle-grobase-link-1` restarting, the frontends get no answer from grobase | The ssh master and `LINK_DIR` (in `XDG_RUNTIME_DIR`) do not survive a reboot; dockerd re-creates the relay's bind source as root when it restarts the relay, and `make link` replaces that empty directory with this user's (`own_link_dir`) | `make link`; `make link-autostart` once makes it heal on its own |
| `link-status`: `master to … is gone` | The remote rebooted or the network dropped; `ControlPersist` does not reconnect | `make link` again (the heal timer does it within two minutes when `link-autostart` is installed) |
| LAN clients time out on `https://<LAN IP>:8443` while `https://100.94.119.97:8443` answers | The VM's https forward is not on `127.0.0.1:8443` (`https=` in the VM's `ports.env`; it was `8445` after the 2026-10-12 reboot) and the edge forwards to the old port | `systemctl --user restart grobase-lan-edge` (the heal timer does it); born2root `fix/host-port-bind` keeps the forward on 8443 at the next VM start |
| `grobase doctor`: TLS FAIL `pin sha256:… does not match the presented sha256:…` | The WAF's leaf was re-issued | Read the new fingerprint on the data center (`openssl x509 -noout -fingerprint -sha256 -in /opt/grobase/certs/localhost.pem`), compare it with the presented one, then `grobase context pin b2b` |
| Browser: certificate warning on `https://localhost:9443` (or any frontend) while `curl --cacert` is fine | A browser store holds an older CA: `make certs` on a fresh tree mints a new one | `make certs-trust-check` to see the stale or missing stores, `make certs-trust-user`, then relaunch the browser |
| Snap Chromium warns (`ERR_CERT_AUTHORITY_INVALID`) after a snap refresh | Its `HOME` is the revision directory behind `~/snap/chromium/current`; the new revision has no store | `make certs-trust-check` reports it missing; `make certs-trust-user` recreates it; relaunch |
| Every `/query/v1` call answers 502 `An invalid response was received from the upstream server` right after `query-router` was recreated on the data center, while `query-router` answers from Kong's network | Kong keeps the old container's address for the upstream | `docker restart mini-baas-kong` on the data center (measured 2026-10-11: 502 on all seven mounts before, 200 after) |
