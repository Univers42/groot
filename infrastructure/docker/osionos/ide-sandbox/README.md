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
| 15 | Inode + block quota, separate fs | `StorageOpt.size`; inode cap needs pquota data-root | built; needs pquota host fs |
| 16 | Idle/lifetime reap + CPU budget | `reapExpiredSandboxes` (lifetime) + `NanoCpus` cap | built; idle-signal in P3 |

Offline-verified (no live daemon): **2, 4, 5, 6, 8, 9, 10-auth, 11, 13, 14** via
`node --test tests/bridge/ide-sandbox-*.test.mjs`, the two proxy `--selfcheck`s,
and the sandbox-image hardening probes. The rest need the live nested daemon +
`verify.sh`.

## Host prerequisites (why the live corpus isn't auto-run here)

Rootless dind needs host support this machine lacks out of the box — a probe
showed `rootlesskit: fork/exec … operation not permitted` (the host's
`apparmor_restrict_unprivileged_userns` blocking rootlesskit) and unloadable
`ip_tables` modules. An operator must, on the deployment host:

1. Allow the dind container's userns: an apparmor profile for it, **or**
   `sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` (host policy call).
2. `modprobe ip_tables ip6_tables nf_tables` (or bake into the host).
3. cgroup v2 delegation for the dind user + `/etc/subuid`,`/etc/subgid` entries.
4. Put the dind **data-root on a pquota-capable fs** (xfs prjquota / ext4) for
   the inode+block quota (condition 15), on a filesystem **separate** from the
   host daemon's `/var/lib/docker`.

These are host-policy changes (sudo, invasive) deliberately left to the operator,
not performed by the build.

## Activation

```sh
# 1. Build the three images on the host daemon.
docker build -t osionos-ide-egress:latest        infrastructure/docker/osionos/ide-egress-proxy
docker build -t osionos-ide-socket-proxy:latest  infrastructure/docker/osionos/ide-socket-proxy
docker build -t osionos-ide-sandbox:latest       infrastructure/docker/osionos/ide-sandbox

# 2. Bring up the isolated daemon + filter (after the host prereqs above).
COMPOSE_PROFILES=ide docker compose up -d osionos-ide-dockerd osionos-ide-socket-proxy

# 3. One-time seed of images + networks + in-dind egress proxy.
sh infrastructure/docker/osionos/ide-sandbox/bootstrap.sh

# 4. Run the FULL 16-condition hostile corpus (must be green before enabling).
sh infrastructure/docker/osionos/ide-sandbox/verify.sh

# 5. Enable on the bridge (double-gate): set on the osionos-bridge service and
#    join it to osionos-ide-control-net.
#      OSIONOS_IDE_SANDBOX=1
#      OSIONOS_IDE_DOCKER_HOST=osionos-ide-socket-proxy:2375
#      OSIONOS_IDE_EGRESS_GIT_HOSTS=github.com   # the user's git host(s)
```

## Trade-off notes

- **Rootless dind vs. host DOCKER-USER iptables.** Condition 1 (isolate from the
  backend daemon) drove the rootless-dind choice. Rootless dind can't program
  host `DOCKER-USER` chains, so the sandbox's off-box block is enforced by the
  `internal` sandbox network (no default route) + the connect-time-IP-validating
  egress proxy, not host iptables. The dind daemon itself runs in a rootlesskit
  netns with no backend route, so the "gateway pivot" the deny-rules would block
  leads nowhere useful. This is a deliberate, documented substitution.
