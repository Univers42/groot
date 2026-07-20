# osionos IDE sandbox plane (P2) — runbook & security acceptance record

The persistent per-`(user, workspace)` IDE workspace: a real shell, a persistent
volume, and network egress for `git`/`pip`/`npm`. Because that inverts every
guarantee of the stateless code runner, it went through the risk gate (`devil`)
and shipped **BLOCK → PROCEED-WITH-CONDITIONS**. This file is the acceptance
record: the architecture, the 16 conditions, how each is verified, and the
operator steps to activate + run the full hostile corpus.

**Ships OFF.** Double-gated on `OSIONOS_IDE_SANDBOX=1` **and** a reachable
`OSIONOS_IDE_DOCKER_HOST`; the `ide` compose profile is never started by
`make all`. With either unset, `POST /api/ide/session` returns 404.

## Architecture (why it's shaped this way)

```
 browser ──auth──▶ bridge (bridge-ide-sandbox.mjs, provisioner)
                      │  server-built docker API calls only
                      ▼  (internal control-net)
              ide-socket-proxy  ── allowlist endpoints + vet create body
                      │  (shared unix socket, NOT a network)
                      ▼
         osionos-ide-dockerd  ── ISOLATED rootless daemon, own data-root
              (its own containers; cannot see mini-baas)
                      │  in-dind networks
        ┌─────────────┴───────────────┐
   sandbox-net (internal)        egress-net
   ┌───────────┐   ┌───────────┐
   │  sandbox  │──▶│ ide-egress│──▶ npm/pypi/github (allowlist + IP revalidation)
   └───────────┘   └───────────┘
   no off-box route          the ONLY path out
```

- **A dedicated rootless daemon** runs the sandboxes on its own data-root, so a
  sandbox/provisioner compromise cannot see the 28 `mini-baas-*` backend
  containers on the host daemon (**condition 1** — the catastrophic-blast-radius
  fix).
- **The socket-proxy** (`ide-socket-proxy/proxy.mjs`) is the only path from the
  provisioner to that daemon. It allowlists endpoints **and vets the create
  body**, rejecting `Privileged`, host `Binds`/bind-Mounts, host
  `NetworkMode`/`PidMode`/…, `CapAdd`, `Devices`, `seccomp=unconfined`
  (**conditions 2, 8**). Container-path ids are pinned to `ide-<32hex>` so an
  exec can never target `mini-baas-postgres` (**condition 9**).
- **The egress proxy** (`ide-egress-proxy/proxy.mjs`) is a CONNECT proxy that
  re-validates the **resolved IP** at connect time and dials that literal IP —
  so a hostname (incl. the user's git host) resolving to `169.254.169.254` or a
  backend IP is refused (**conditions 3, 5, 6** — DNS-rebind/SSRF safe). The
  sandbox net is `internal`, so the proxy is the sole route off-box.
- **PAT** is injected per git op via `docker exec -e GIT_PAT` (see P6). The
  system credential helper emits a secret **only** when `GIT_PAT` is in the git
  process env; the long-lived shell never carries it (**condition 13**). Core
  dumps are disabled so a git crash can't drop a PAT-bearing core on `/workspace`
  (**condition 14**).

## The 16 conditions — verification status

| # | Condition | How verified | Status |
|---|---|---|---|
| 1 | Sandboxes not on the mini-baas daemon | isolated rootless `osionos-ide-dockerd`; `verify.sh` (`docker ps` shows no backend) | built; live probe needs host prep |
| 2 | Docker reached only via allowlist socket-proxy | `ide-socket-proxy --selfcheck` | ✅ verified |
| 3 | Sandbox has no direct off-box route | `sandbox-net --internal`; `verify.sh` (`curl 1.1.1.1` fails) | built; live probe |
| 4 | Caps hold under a hostile shell | image probe: `unshare`→EPERM, `CapEff=0`, read-only | ✅ verified |
| 5 | Egress proxy re-validates resolved IP | `ide-egress --selfcheck` (deny tables) + connect-time dial-by-IP | ✅ logic verified |
| 6 | IPv6 metadata/ULA denied | `ide-egress --selfcheck` (`denied6`) | ✅ verified |
| 7 | Egress proxy joins only proxy-net + egress-net | bootstrap wiring | built; live probe |
| 8 | Socket-proxy rejects Privileged/Binds/host-modes | `ide-socket-proxy --selfcheck` (`unsafeCreateBody`) | ✅ verified |
| 9 | Exec pinned by derived name, fixed argv | socket-proxy path regex + `buildShellExecSpec`/`buildGitExecSpec` tests | ✅ verified |
| 10 | Provisioner unreachable from sandbox + auth-first | handler tests (404/401/403); topology (bridge not on sandbox net) | ✅ auth verified; topology built |
| 11 | Names hashed+validated; workspace ownership-checked | `ide-sandbox-spec.test.mjs` | ✅ verified |
| 12 | PAT scoped + short-lived | P6 (git brokering) | deferred to P6 |
| 13 | PAT never on a synced path / shell env | image probes (helper + shell env) | ✅ verified |
| 14 | Core dumps disabled | image probe (`ulimit -c` = 0) + create ulimit | ✅ verified |
| 15 | Block quota, separate fs | separate loopback data-root caps host blast; per-sandbox `StorageOpt.size` is xfs+pquota-only, opt-in via `OSIONOS_IDE_STORAGE_QUOTA` | ✅ host-bounded; per-sandbox = xfs upgrade |
| 16 | Idle/lifetime reap + CPU budget | `reapExpiredSandboxes` (lifetime) + `NanoCpus` cap | built; idle-signal in P3 |

Offline-verified (no live daemon): **2, 4, 5, 6, 8, 9, 10-auth, 11, 13, 14** via
`node --test tests/bridge/ide-sandbox-*.test.mjs`, the two proxy `--selfcheck`s,
and the sandbox-image hardening probes. The rest need the live nested daemon +
`verify.sh`.

## Host prerequisites (why the live corpus isn't auto-run here)

The isolated daemon is a SECOND rootful dockerd (`docker-ide.service`) — chosen
over rootless-dind because this host keeps `apparmor_restrict_unprivileged_userns=1`
(a real mitigation we do NOT relax). It runs `--userns-remap` (container-root →
unprivileged host uid) + `--iptables=false` (never touches the main daemon's
chains). Operator host-prep (sudo):

1. **Separate loopback data-root** (condition 15 — caps host blast at the image
   size regardless of a runaway sandbox). ext4 is enough for this:
   ```
   sudo fallocate -l 24G /var/lib/docker-ide.img
   sudo mkfs.ext4 -q -O quota -E quotatype=prjquota /var/lib/docker-ide.img
   sudo mkdir -p /var/lib/docker-ide
   sudo mount -o loop,prjquota /var/lib/docker-ide.img /var/lib/docker-ide
   echo '/var/lib/docker-ide.img /var/lib/docker-ide ext4 loop,prjquota,nofail 0 0' | sudo tee -a /etc/fstab
   ```
   For a PER-SANDBOX block quota, make the image `xfs` instead (`mkfs.xfs -f`,
   `mount -o loop,pquota`) and set `OSIONOS_IDE_STORAGE_QUOTA=2G` on the bridge —
   overlay2 `StorageOpt.size` works only over xfs+pquota, not ext4-prjquota.
2. **Install + start the daemon:**
   ```
   sudo cp infrastructure/docker/osionos/ide-sandbox/docker-ide.service /etc/systemd/system/
   sudo systemctl daemon-reload && sudo systemctl enable --now docker-ide
   ```
3. **Egress NAT** (scoped to docker-ide's 10.202.0.0/16 pool only):
   ```
   sudo sh infrastructure/docker/osionos/ide-sandbox/ide-egress-nat.sh up
   ```

## Activation

```sh
# 1. Build the three images on the MAIN daemon.
docker build -t osionos-ide-egress:latest        infrastructure/docker/osionos/ide-egress-proxy
docker build -t osionos-ide-socket-proxy:latest  infrastructure/docker/osionos/ide-socket-proxy
docker build -t osionos-ide-sandbox:latest       infrastructure/docker/osionos/ide-sandbox

# 2. After the host-prep above, bring up the filter (talks to /run/docker-ide.sock).
COMPOSE_PROFILES=ide docker compose up -d osionos-ide-socket-proxy

# 3. One-time seed of images + networks + egress proxy into docker-ide (sudo:
#    the socket is root-owned).
sudo sh infrastructure/docker/osionos/ide-sandbox/bootstrap.sh

# 4. Run the FULL 16-condition hostile corpus (must be green before enabling).
sudo sh infrastructure/docker/osionos/ide-sandbox/verify.sh

# 5. Enable on the bridge (double-gate): set on the osionos-bridge service and
#    join it to osionos-ide-control-net.
#      OSIONOS_IDE_SANDBOX=1
#      OSIONOS_IDE_DOCKER_HOST=osionos-ide-socket-proxy:2375
#      OSIONOS_IDE_EGRESS_GIT_HOSTS=github.com   # the user's git host(s)
```

## P3–P7 routes (server halves — built + verified offline)

All reuse the P2 socket-proxy path + `ide-docker` exec engine (proven live via a
throwaway-container `runExec` test), auth-first + double-gated like the
provisioner. Bridge modules, no new deps (WebSocket is hand-rolled: `ide-ws.mjs`,
`--selfcheck`'d):

| Route | Phase | What | Verified |
|---|---|---|---|
| WS `/api/ide/pty` | P3 | interactive shell (`docker exec -it bash`) + out-of-band APC resize | ws codec + exec engine |
| WS `/api/ide/lsp?lang=` | P5 | LSP stdio relay (typescript/pyright) | ws codec + exec engine |
| WS `/api/ide/fsync` | P4 | fs-agent event stream (writeback) | ws codec + exec engine |
| POST `/api/ide/git` | P6 | status/commit/push; subcommand allowlist; **`config` denied** (can't defeat the per-op PAT); PAT request-scoped | argv unit tests |
| POST `/api/ide/search` | P7 | `rg --json`, query after `--` (no flag injection) | parser + argv tests |
| POST `/api/ide/fs` | P4 | editor→container write (base64 argv, path-traversal guarded) | argv test |

Frontend shipped (all behind `osio.ide`, static-verified — typecheck + eslint +
canvas suite green): **terminal** (xterm.js over `/api/ide/pty`, lazy-loaded, PTY
resize propagated), **LSP** (`@codemirror/lsp-client` over `/api/ide/lsp` through
a dependency-free Content-Length codec, + a diagnostics store + Problems panel),
**live sync** (materialize on attach, editor→container mirror, `/api/ide/fsync`
writeback → page CRUD with ignore-set + sha256 echo-suppression), and the
**Source Control panel** (P6) — status/commit/push, graceful "no sandbox" offline.

## Remaining to finish

1. ~~Terminal frontend (P3)~~ — **done**: `IdeTerminal` (xterm.js) over
   `/api/ide/pty`, lazy-loaded, resize propagated via an APC control frame.
2. ~~LSP client (P5)~~ — **done**: `@codemirror/lsp-client` → `/api/ide/lsp`
   through a dependency-free Content-Length codec; diagnostics store + Problems
   panel; `typescript-language-server` + `pyright` in the sandbox image.
3. ~~Live sync loop (P4)~~ — **done**: `useIdeFsSync` streams `/api/ide/fsync`
   → page CRUD; materialize on attach; editor→container mirror; ignore-set +
   sha256 echo-suppression (no `.osio/manifest.json` needed — the page tree is
   the manifest, path↔pageId derived via `pathForPage`).
4. **fly-machines provider (P7):** a drop-in behind `ide-docker`'s interface —
   deferred (YAGNI until a fly deploy is attempted).
5. **Live activation (Part E):** the isolated daemon still needs the host sudo
   prep below; then `verify.sh` 16/16 + the terminal/LSP/sync/git end-to-end run.

## Trade-off notes

- **Rootless dind vs. host DOCKER-USER iptables.** Condition 1 (isolate from the
  backend daemon) drove the rootless-dind choice. Rootless dind can't program
  host `DOCKER-USER` chains, so the sandbox's off-box block is enforced by the
  `internal` sandbox network (no default route) + the connect-time-IP-validating
  egress proxy, not host iptables. The dind daemon itself runs in a rootlesskit
  netns with no backend route, so the "gateway pivot" the deny-rules would block
  leads nowhere useful. This is a deliberate, documented substitution.
