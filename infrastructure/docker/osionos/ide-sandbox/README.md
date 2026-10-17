# osionos IDE sandbox plane (P2) — runbook & security acceptance record

A real shell, a persistent volume, and network egress for `git`/`pip`/`npm` per
`(user, workspace)` — every guarantee of the stateless code runner inverted, so it went
through the risk gate (`devil`) and shipped **BLOCK → PROCEED-WITH-CONDITIONS**. This file
is the acceptance record: architecture, the 16 conditions, operator steps.

**Ships OFF.** Double-gated on `OSIONOS_IDE_SANDBOX=1` and a reachable
`OSIONOS_IDE_DOCKER_HOST` (both pinned empty in compose); `make all` never starts the
`ide` profile. Either unset → `POST /api/ide/session` returns 404.

## Architecture (why it's shaped this way)

```
  browser ──auth──▶ bridge (bridge-ide-sandbox.mjs, provisioner)
                       │  server-built docker API calls only
                       ▼  (internal control-net)
               ide-socket-proxy  ── allowlist endpoints + vet create body
                       │  (shared unix socket, NOT a network)
                       ▼
          osionos-ide-dockerd  ── ISOLATED daemon (rootful + userns-remap), own data-root
                       │  in-dind networks
          ┌─────────────┴───────────────┐
     sandbox-net (internal)        egress-net
     ┌───────────┐   ┌───────────┐
     │  sandbox  │──▶│ ide-egress│──▶ npm/pypi/github (allowlist + IP revalidation)
     └───────────┘   └───────────┘
     no off-box route          the ONLY path out
```

- **A dedicated, isolated daemon** (rootful dockerd, `--userns-remap=default` — NOT
  rootless, see below) runs the sandboxes on its own data-root: a sandbox compromise
  cannot see the 28 `mini-baas-*` backend containers (**condition 1**).
- **The socket-proxy** (`ide-socket-proxy/proxy.mjs`) is the only path from the
  provisioner to that daemon: allowlisted endpoints + a create-body filter
  (**conditions 2, 8**), and container-path ids pinned to `ide-<32hex>` so an exec
  can never target `mini-baas-postgres` (**condition 9**).
- **The egress proxy** (`ide-egress-proxy/proxy.mjs`) re-validates the **resolved IP**
  at connect time and dials that literal IP — hostnames resolving to `169.254.169.254`
  or a backend IP are refused (**conditions 3, 5, 6**). The `internal` sandbox net
  makes it the sole route off-box.
- **PAT** is injected per git op via `docker exec -e GIT_PAT` (P6); the credential
  helper emits it **only** when `GIT_PAT` is in the git process env (condition 13).
  Core dumps are disabled (condition 14).

**Invariant — one bridge per sandbox daemon.** Provisioning is single-flight *within* a
process (`ensureSandbox`); two bridges on one `docker-ide` daemon could remove each
other's box.

### Placement — the plane on the VM

The diagram above is the logical path; this one shows where each box runs. The control plane —
`osionos-ide-socket-proxy` + `osionos-ide-server` (compose profile `ide`, project `osionos-ide-plane`)
— runs on the VM's MAIN daemon next to `docker-ide`, so the raw docker-ide API never leaves the VM.
Both containers sit only on internal networks (`osionos-ide-edge-net`, `osionos-ide-control-net`),
publish no host port, and the bridge no longer hosts sandboxes — its IDE gates are pinned empty in
compose; the ide-server runs from the bridge image with a different entrypoint.

```
  browser ──https:8446──▶ local-https-proxy      [client machine]
                 │  $LINK_DIR/ide/ide-server-4100.sock
                 ▼
  grobase-link-ide relay (socat)                 [client machine]
                 │  ssh forward — `make link` (ssh mode)
                 ▼
       osionos-ide-server ──:4100                [VM, MAIN daemon]
                 │  osionos-ide-control-net
                 ▼
  osionos-ide-socket-proxy ──:2375               [VM, MAIN daemon]
                 │  /run/docker-ide.sock
                 ▼
        docker-ide ── ISOLATED daemon            [VM: the sandboxes]
```

- `make link` (ssh mode) forwards `$LINK_DIR/ide/ide-server-4100.sock` to the ide-server's edge
  address on the VM; the `grobase-link-ide` socat relay (the link owner's uid, `cap_drop ALL`,
  read-only, edge network only, network alias `osionos-ide-server`, TCP `nodelay`) puts it on the
  local `osionos-ide-edge-net`, where `local-https-proxy` serves it at `https://localhost:8446`.
  `make link-verify` probes `ide-dns`, `ide-healthz`, `ide-isolation`. Measured PTY round trip:
  p50 0.6 ms (41.9 ms before `nodelay`: Nagle + delayed ACK).
- Tokens: the browser gets a ≤ 900 s, one-workspace IDE token from the bridge's
  `POST /api/ide/token` (an app session is required; 401 without it). Bridge and
  ide-server share `OSIONOS_IDE_TOKEN_SECRET` (≥ 32 bytes, never
  `OSIONOS_APP_SESSION_SECRET`); `OSIONOS_IDE_ALLOWED_SUBJECTS` is the user-id
  allowlist, checked on both sides. Measured end to end with a real session: login 200 →
  token 200 → `POST /api/ide/session` 200 → the PTY evaluates `$((6*7))`.
- Exposure: link-only. Public exposure (C21) was declined on 2026-10-14: no caller needs it, and
  a public listener would leave a code-execution service one leaked secret from the internet.
  `check-plane.sh` C21 proves no tailscale serve/funnel target or extra container reaches it.

## The 16 conditions — verification status

| # | Condition | How verified | Status |
|---|---|---|---|
| 1 | Sandboxes not on the mini-baas daemon | isolated `osionos-ide-dockerd` (rootful + userns-remap); `verify.sh` (`docker ps` shows no backend) | built; live probe needs host prep |
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
| 16 | Idle/lifetime reap + CPU budget | `reapExpiredSandboxes`: past 4 h an idle box is stopped, past 12 h any box; `NanoCpus` cap. A stopped box is re-provisioned by the terminal, the session POST, or the LSP/fs-sync sockets — but a box stopped at the 12 h cap comes back only on an explicit action (terminal / session POST), so an open tab cannot keep one alive | `ide-ensure-sandbox.test.mjs` (hard-cap refusal, single-flight, 409 adoption) |

Offline-verified (no live daemon): **2, 4, 5, 6, 8, 9, 10-auth, 11, 13, 14** via
`node --test tests/bridge/ide-sandbox-*.test.mjs` and the proxy `--selfcheck`s; the rest
need the live daemon + `verify.sh`.

## Host prerequisites (why the live corpus isn't auto-run here)

The isolated daemon is a SECOND rootful dockerd (`docker-ide.service`) — chosen over
rootless-dind because this host keeps `apparmor_restrict_unprivileged_userns=1` (a
mitigation we do NOT relax) — with `--userns-remap` (container-root → unprivileged host
uid) + `--iptables=false`. Host-prep:

1. **Separate loopback data-root** (condition 15 — caps host blast at the image size).
   ext4 is enough:
   ```
   sudo fallocate -l 24G /var/lib/docker-ide.img
   sudo mkfs.ext4 -q -O quota -E quotatype=prjquota /var/lib/docker-ide.img
   sudo mkdir -p /var/lib/docker-ide && sudo mount -o loop,prjquota /var/lib/docker-ide.img /var/lib/docker-ide
   echo '/var/lib/docker-ide.img /var/lib/docker-ide ext4 loop,prjquota,nofail 0 0' | sudo tee -a /etc/fstab
   ```
   For a PER-SANDBOX block quota, use `xfs` (`mkfs.xfs -f`, `mount -o loop,pquota`)
   + `OSIONOS_IDE_STORAGE_QUOTA=2G` — overlay2 `StorageOpt.size` needs xfs+pquota.
2. **Install + start the daemon** (`install-docker-ide.sh` installs the service, the
   `docker-ide.socket` unit and the slice and proves the result; see "Before step 1"):
   `sudo sh …/ide-sandbox/install-docker-ide.sh`
3. **Egress NAT** (scoped to docker-ide's 10.202.0.0/16 pool only):
   ```
   sudo sh infrastructure/docker/osionos/ide-sandbox/install-egress-nat.sh
   # (a root-owned copy + a drop-in, so the rules survive reboots; a one-off
   #  `sudo sh …/ide-egress-nat.sh up` is lost at the next boot)
   ```

## Rootful, not rootless — what that does and does not protect

`docker-ide.service` runs **rootful** `dockerd` with `--userns-remap=default` (verified
live: `docker -H unix:///run/docker-ide.sock info` reports `name=userns`). Earlier
revisions called it "rootless"; it is not, and the difference is load-bearing:

- **Protected:** root *inside a sandbox* is remapped to an unprivileged host uid
  (data-root `/var/lib/docker-ide/100000.100000`), so a container escape lands as nobody.
- **NOT protected:** the daemon itself is host root — anything that can drive it
  arbitrarily gets host root, which is why the socket is reachable only through
  `osionos-ide-socket-proxy`, whose body filter must stay strict (container, volume AND
  network creates are vetted; the volume/network vetting was added 2026-09-16 after a
  `local` volume with `DriverOpts {o:bind, device:/}` passed through unvetted).
- The socket file is `root:docker 0660`: `docker`-group members can already drive the
  main daemon as root, so this adds no new privilege.

## Activation

### Before step 1 — check the host, and clear a socket that became a directory

Run from the repo root; item A has already broken a host.

**`docker-ide` is socket-activated: systemd owns `/run/docker-ide.sock`, not dockerd.**
`docker-ide.socket` owns the path (mode 0660, group `docker`); `docker-ide.service` runs
`--host=fd://` with `Requires=`/`After=docker-ide.socket`, so the socket's inode survives a
`systemctl restart docker-ide` and the proxy is never recreated (measured: the proxy ping answered
0 s after a restart, and the proxy container was not restarted). `install-docker-ide.sh` performs the
migration — stop the old unit, enable the socket before the service, restart — and adds two checks:
the socket unit active with the file `0660 root:docker`, and the inode unchanged across a restart.
The proxy runs as user `node`; compose `group_add` adds the gid owning the socket (`stat -c %g`, read
on the VM by `deploy-plane.sh`) — without it the proxy answers 502 "daemon unreachable".

**A. `/run/docker-ide.sock` must not exist as a directory.** `docker-compose.yml` (`osionos-ide-socket-proxy`)
bind-mounts the socket into `osionos-ide-socket-proxy`; if it starts before
`docker-ide.service` exists, Docker creates the missing path as an empty root-owned
*directory* and `dockerd` cannot bind there. Symptoms: the proxy answers `502 daemon
unreachable`; the bridge closes every sandbox WebSocket with `4004`; the IDE console
never gets a prompt. Confirm and clear it:

```sh
ls -ld /run/docker-ide.sock        # "d" in the first column = the bug
systemctl is-enabled docker-ide    # "not-found" = the unit was never installed
docker compose --env-file ./.env.local --profile ide rm -sf osionos-ide-socket-proxy
sudo rmdir /run/docker-ide.sock && test ! -e /run/docker-ide.sock
```

The proxy holds the bind-mount, so it goes first and stays down until
`test -S /run/docker-ide.sock` succeeds (step 2). `rmdir` refuses a non-empty directory — the
intended failure: stop and look inside. `ACTIVATE-dlesieur42.sh` performs the same two commands
between the image builds and the data-root. That bind is long syntax with
`create_host_path: false`: a missing socket now fails the container start instead of Docker
creating an empty directory, so this recovery is for hosts that still carry one.

**B. Disk and quota.** Check free space (`df -h /var /`) before creating or growing the
data-root, then confirm the mount carries `prjquota`:

```sh
findmnt /var/lib/docker-ide        # no output (exit 1) = not mounted yet: do host-prep item 1
findmnt -no OPTIONS /var/lib/docker-ide | grep prjquota
```

The sandbox image is about 2.8 GB; `bootstrap.sh` loads it with `docker save | docker
load`, which needs roughly twice that on the data-root, and building needs about 3.5 GB on
`/var` (the refuse-below-3.5 G guard: `ACTIVATE-dlesieur42.sh` `VAR_MIN_KB`).
`STORAGE-dlesieur42.sh` is the owner script for the LV/loopback choice. Without
`prjquota`, stop — `ACTIVATE-dlesieur42.sh` refuses. This is a runbook for the failure; it
does not repair `docker-ide.service` or the mount.

### Steps

```sh
# 1. Build the three images on the MAIN daemon.
docker build -t osionos-ide-egress:latest        infrastructure/docker/osionos/ide-egress-proxy
docker build -t osionos-ide-socket-proxy:latest  infrastructure/docker/osionos/ide-socket-proxy
docker build -t osionos-ide-sandbox:latest       infrastructure/docker/osionos/ide-sandbox

# 2. After the host-prep above AND `test -S /run/docker-ide.sock` succeeds, bring up the
#    filter; starting it earlier recreates the directory.
COMPOSE_PROFILES=ide docker compose up -d osionos-ide-socket-proxy

# 3. One-time seed of images + networks + egress proxy into docker-ide (sudo: the socket is
#    root-owned); afterwards only docker-ide holds the sandbox image (the main daemon's
#    ~2.8 GB copy is removed) — to keep it: `OSIONOS_IDE_KEEP_MAIN_COPY=1`
sudo sh infrastructure/docker/osionos/ide-sandbox/bootstrap.sh

# 4. Run the hostile corpus (must be green before enabling). verify.sh pins EXPECTED=56 and every
#    probe prints exactly one PASS/FAIL/SKIP line. The "Control plane reachability" section adds two
#    probes: a box must not open TCP to osionos-ide-server:4100 nor osionos-ide-socket-proxy:2375, on
#    EVERY address each container has, every target first shown to accept connections from the host;
#    both SKIP where the plane is not deployed. The code-runner probe SKIPs where no runner image is
#    present. The "Persistent home" section adds four probes (home owned by the box uid, mode 700, and writable, box B
#    cannot read box A's home, a file survives box remove and recreate, `touch /etc/x` denied). The
#    "Box identity" section adds three more (`whoami` is coder and HOME is /home/coder right after start,
#    a hostile passwd file changes neither uid nor HOME, a 100 KB passwd line breaks every exec and a
#    box restart cures it). The "Per-user uid" section adds four (another uid cannot list box A's home
#    while its owner can, the two boxes run as different host uids, `volume-nocopy` leaves a fresh volume
#    root alone, the init with its three capabilities gives a 0700 tree another uid left to the new uid).
#    Expected green line once ADR 0011 is deployed: `RESULT: 55 passed, 0 failed, 1 skipped (expected
#    56)`, the skip being the runner probe (not yet run: it needs the VM, A3.8 and A3.9, 2026-10-17). The
#    last measured line on the VM (2026-10-14) was `41 passed, 0 failed, 1 skipped (expected 42)`. The checks do not map 1:1 onto the 16 conditions.
sudo sh infrastructure/docker/osionos/ide-sandbox/verify.sh

# 5. Seed docker-ide, then deploy the plane to the VM (the VM never builds) and prove it read-only:
#      IDE_SHIP_HOST=<ssh alias> sh infrastructure/docker/osionos/ide-sandbox/ship-images.sh
#        # prints the sha256: pins for OSIONOS_IDE_SANDBOX_IMAGE / OSIONOS_IDE_EGRESS_IMAGE
#      IDE_SHIP_HOST=<ssh alias> \
#      OSIONOS_IDE_ENV_FILE=<env file: OSIONOS_IDE_TOKEN_SECRET + the OSIONOS_IDE_SANDBOX_IMAGE pin> \
#      OSIONOS_BRIDGE_IMAGE=<bridge tag> \
#      sh infrastructure/docker/osionos/ide-sandbox/deploy-plane.sh
#      IDE_SHIP_HOST=<ssh alias> OSIONOS_IDE_ENV_FILE=<same env file> \
#      sh infrastructure/docker/osionos/ide-sandbox/check-plane.sh
#    deploy-plane.sh reads the gid owning /run/docker-ide.sock on the VM (refuses root or none) and
#    ships an image only when the VM lacks the same config + layers — the VM's containerd store ids an
#    image by its manifest digest, a classic store by its config digest, so the same image has two ids
#    — then brings the profile up over DOCKER_HOST=ssh://… with --no-build --pull never --wait, each
#    container pinned to the VM's own image ids. check-plane.sh prints one ok|FAIL line per condition
#    — C1 image equality by config + layers, C2 the token secret in no VM home file, C4 the
#    socket-proxy caps non-zero, C6 no mini-baas box dials ide-server:4100 or proxy:2375 while the VM
#    host can, C7 no host-net container + docker group = operator only, C8 both plane subnets private
#    and outside 10.202/16, C10 no host port, C21 no tailscale serve/funnel target and no extra
#    container on the plane networks — measured `RESULT: 8 ok, 0 failed`. The bridge needs no env
#    change (its IDE gates are pinned empty in compose — see Placement).
# 6. On the client machine: `make link` (ssh mode), then `make link-verify` — see Placement.
```

## Persistent home and login shell

A user's dotfiles, `~/.local` installs and shell choice live in one named volume,
`osio-ide-home-<sha256(userId)[0:32]>`, mounted at the constant `/home/coder` in every box of that
user. `/workspace` stays per user and workspace. The username never enters a path or a volume name.
The socket proxy admits exactly two mounts, `[workspace, home]` in that order, and recomputes the home
name from the `osio.ide.owner` label (`create-shape.mjs`, pinned to the bridge by
`scripts/tests/ide-proxy-parity.mjs`). The old 64 MB `/home/coder` tmpfs is gone; `/tmp` stays one.

- **No quota.** The home is unbounded like `/workspace`: it is limited by the docker-ide data-root, not
  by `diskSize` (a local volume honours no size option, and the proxy refuses `DriverOpts`). Before a
  second subject joins `OSIONOS_IDE_ALLOWED_SUBJECTS`, the volume growth bound has to be ruled again.
- **Shared by design (N4).** One home serves all of a user's workspaces and up to two concurrent boxes.
  An rc file written in one box runs in the others.
- **Login shell.** The PTY starts `/usr/local/bin/osio-login`. It reads the first line (at most 4096
  bytes) of `~/.config/osio/login-shell` as a path, never evaluates it, and starts it with `-l` only if
  it is absolute, free of `..` and control characters, a regular executable file, not the launcher
  itself, and either under `$HOME` or listed in `/etc/shells`. Anything else prints one stderr line with
  a fixed reason and starts `/bin/bash -l`. `chsh -s <path>` (a POSIX sh shim at `/usr/local/bin/chsh`;
  the setuid `/usr/bin/chsh` is removed from the image) applies the same checks and writes the file
  atomically; `chsh` alone prints the current shell. It never touches `/etc`. Tests:
  `scripts/tests/ide-login-shell.bats`.
- **Safe terminal.** The IDE's "Safe terminal" button attaches with `safe=1`: `bash --noprofile --norc`,
  a fixed argv that skips the launcher, `~/.bashrc` and `~/.profile`. A saved shell that passes the checks
  but crashes at once, or an rc with `exit 1`, ends every normal terminal; the safe terminal is the way
  back in. `chsh -s /bin/bash` undoes the choice.

### Every user runs as their own uid (ADR 0011)

A box runs as `<uid>:10001`, with `uid` in 20000-59999 and the gid fixed so `/etc/group` stays static.
docker-ide remaps uids by 165536, so two users' processes are different host uids and the kernel keeps
their files apart. The socket proxy owns the owner-to-uid ledger (`/ledger/uid-ledger.jsonl` on the
`osionos-ide-ledger` volume), hands a uid out at `POST /osio/v1/uid`, and refuses a box or init create
whose `User`, `osio.ide.uid` label and owner disagree with it. The uid never rides the token and there is
no database column (verdict A1.4 is moot).

**Invariants.**

- No create admits `User` 10001:10001, a uid outside the range, or a gid other than 10001; no exec body
  may carry a `User` (an exec with none inherits the box's).
- Both box mounts carry `VolumeOptions: {NoCopy: true}`, and the box never creates a volume's root: the
  ownership init (`ideinit-<digest>`, the sandbox image with entrypoint `osio-volume-init`) runs first at
  the real targets `/workspace` and `/home/coder`, with CHOWN, FOWNER and DAC_READ_SEARCH only, no
  network, a read-only root, 16 pids, 128 MiB, and a 120 s bound. A failed init means no box ("home
  repair failed"). `ideinit-*` containers are hidden from the box count and the reaper.
- `osio-volume-init` chowns the contents first and the root last, so a root already at `<uid>:10001 700`
  means a finished run; it never follows a symlink.
- `box-init` and `osio-login` give the coder line of `/etc/passwd.base` the box's own uid at run time;
  the build still asserts that line as `coder:x:10001:10001:` because both match it.

**Caveats.** Losing the ledger volume forgets the bindings and the next create for each owner learns one
by trust on first use, possibly a uid that owns another user's files already on docker-ide. The ledger
guards against a buggy bridge or database, not a compromised ide-server (which can ask for any uid);
the network is the only gate on `POST /osio/v1/uid`. A running box without the uid label (made before
this rollout) is replaced on its next use; the home it shares with another running box of the same owner
changes owner under that box until it is recreated.

**Rollback.** Redeploy the previous images. Files now owned by 20000+ stay that way; the old boxes run as
10001 and cannot read them until `osio-volume-init`-style chown gives them back
(`docker run --rm --user 0:0 --cap-add CHOWN --cap-add DAC_READ_SEARCH --cap-add FOWNER
--entrypoint chown <image> -R -h -P 10001:10001 /h`, the volume mounted at `/h`). Keep the
`osionos-ide-ledger` volume across a rollback and a redeploy.

### Account name and HOME (ADR 0009)

`/etc/passwd` in the image is a symlink to `/tmp/.osio/passwd`; the real file is
`/etc/passwd.base`. `box-init` copies the base to the tmpfs before the Cmd starts, so the account is
`coder`. `osio-login` re-validates `OSIO_USER` (the PTY exec Env entry the bridge sets from the token's
`un` claim) and rewrites the file with only the `coder` line renamed, so `whoami` and the prompt show
the user's osionos username. Names in `/etc/passwd.base` are refused, and so is anything outside
`^[a-z_][a-z0-9_-]{0,31}$`; a refusal keeps `coder`. uid, gid, groups and HOME never come from the
file: runc takes the first three from the numeric `User` and HOME from the create Env, where
`HOME=/home/coder` is the 8th entry. The socket proxy requires that entry and refuses any other
`HOME=` in an exec Env.

**Invariant (P8).** This is safe only while no-new-privileges, `CapDrop: ["ALL"]`, the read-only
rootfs and the numeric `User` pins hold. Without any one of them, a user-written passwd plus a setuid
binary gives root in the box. A change to `create-shape.mjs` on those fields, or a setuid binary added
to the image (the build fails above `SETUID_BASELINE`, 8), re-opens ADR 0009.

**/tmp is exec, nosuid and nodev (ADR 0010).** The create spec's `size=64m,mode=1777,exec` mounts as
`rw,nosuid,nodev`: docker prepends `noexec,nosuid,nodev` and the last flag wins. Under noexec, `go run`,
dlopen of a library in /tmp and installers failed (measured 2026-10-17). The boundary does not rest on
noexec: every process of a user runs as that user's uid (ADR 0011), and anyone who can write /tmp can
already run code from /workspace and the home. The socket proxy admits only this exact string, since `,suid` or `,dev` would drop
nosuid or nodev. Boxes created before the rollout keep noexec until stopped (Restart box).

Caveat: /tmp is still 64 MB, so a build whose temp tree passes that fails with ENOSPC (a large
`go run`, a pip build with heavy build dependencies); use `TMPDIR=/workspace/.local/tmp` for those.
A full /tmp also keeps the terminal name `coder`, because `osio-login` cannot write the account file;
execs keep working.

**Symptom and recovery (P7).** The box user can break their own box: a FIFO, a directory or a line of
more than 64 KB at `/tmp/.osio/passwd` makes every `docker exec` hang or fail, the safe terminal
included (`unable to setup user`, or a terminal that never opens). The workbench's "Restart box" button
calls `DELETE /api/ide/session`, which disposes the sessions and stops the box; the next terminal
recreates it with a fresh `/tmp`. Nothing else in the box is reachable first, so no VM root is needed.

**Acceptance on docker-ide (P11, user-run on the VM, before the host bridge goes live).** Any line that
differs from its comment is a stop: report it and do not run R8.

```sh
D='sudo docker -H unix:///run/docker-ide.sock'; IMG=<sandbox image id pinned by ship-images.sh>
runc --version; $D version --format '{{.Server.Version}}'
$D run -d --name osio-p3-probe --network none --user 20000:10001 -e HOME=/home/coder \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true --pids-limit 512 \
  --tmpfs /tmp:size=64m,mode=1777,exec --tmpfs /home/coder:uid=20000 "$IMG" sleep infinity
$D exec osio-p3-probe sh -c 'grep " /tmp " /proc/mounts'               # rw,nosuid,nodev,... and no noexec (X6)
$D exec osio-p3-probe sh -c 'whoami; echo HOME=$HOME'                 # coder, HOME=/home/coder
$D exec -it -e OSIO_USER=dylan -e TERM=xterm-256color osio-p3-probe /usr/local/bin/osio-login
#   in that shell: whoami; id; echo $HOME; exit                        # dylan, uid=20000(dylan) groups=10001(coder), /home/coder
$D exec osio-p3-probe sh -c 'printf "root:x:20000:0::/root:/bin/sh\n" > /tmp/.osio/passwd'
$D exec osio-p3-probe sh -c 'echo HOME=$HOME; id'                     # HOME=/home/coder, uid=20000(root) groups=10001(coder)
$D exec osio-p3-probe sh -c 'head -c 70000 /dev/zero | tr "\0" a > /tmp/.osio/passwd'
$D exec osio-p3-probe true; echo "exit=$?"                            # exit=126 or 128, "unable to setup user"
$D restart -t 1 osio-p3-probe && $D exec osio-p3-probe whoami          # coder
$D exec osio-p3-probe sh -c 'find / -xdev -perm -4000 2>/dev/null | wc -l; touch /etc/x'  # P1 count; Read-only file system
$D rm -f osio-p3-probe
```

Browser acceptance (P7, user-run): in a terminal, `mkfifo /tmp/x && mv -f /tmp/x /tmp/.osio/passwd`,
open another terminal (it hangs), press "Restart box", open a terminal (it works).

### Recovery when no terminal opens (user-run on the VM)

Moves the rc files aside and clears the saved shell, volume kept. `<h>` is the 32 hex characters of the
home volume (`docker -H unix:///run/docker-ide.sock volume ls | grep osio-ide-home`); stop the user's box
first so no shell holds the files. The home belongs to its owner's uid (mode 700), so the helper runs
as that uid: `<uid>` is the number on the owner's line of the socket proxy's ledger
(`docker exec osionos-ide-socket-proxy cat /ledger/uid-ledger.jsonl`, one `{"owner","uid"}` per line).

```sh
docker -H unix:///run/docker-ide.sock run --rm --user <uid>:10001 -v osio-ide-home-<h>:/h \
  osionos-ide-sandbox:latest sh -c \
  'cd /h && for f in .bashrc .profile .bash_profile .config/osio/login-shell; do [ -e "$f" ] && mv "$f" "$f.aside"; done; ls -A'
```

### Removing a user's data (user-run, GDPR)

Stop and remove the user's `ide-*` containers (without `-v`; the containers carry the
`osio.ide.owner` label), then remove their volumes. Volumes carry only `osio.ide.managed=1`, so they are
found by name: `osio-ide-home-<h>` is `sha256(userId)[0:32]`, and each `osio-ide-vol-<h>` is the digest
`deriveNames` gives for that user and workspace (the `Source` of the container's mounts, visible with
`docker inspect` before the container is removed). The owner's line in the socket proxy's ledger
(`/ledger/uid-ledger.jsonl`) stays: it keeps that uid from ever being reissued to someone else, which
would hand the next user whatever files of the first still sit on docker-ide. Delete the line only after
both volumes are gone, and only if it is the last one (allocation is highest + 1). Nothing automates
this yet; it is a tracked follow-up, not done here.

## P3–P7 routes (server halves — built + verified offline)

All reuse the P2 socket-proxy path + `ide-docker` exec engine (proven live via a
throwaway-container `runExec` test), auth-first + double-gated like the provisioner;
bridge modules, no new deps (hand-rolled WebSocket `ide-ws.mjs`, `--selfcheck`'d).

| Route | Phase | What | Verified |
|---|---|---|---|
| WS `/api/ide/pty` | P3 | interactive shell (`docker exec -it bash`) + out-of-band APC resize | ws codec + exec engine |
| WS `/api/ide/lsp?lang=` | P5 | LSP stdio relay (typescript/pyright) | ws codec + exec engine |
| WS `/api/ide/fsync` | P4 | fs-agent event stream (writeback) | ws codec + exec engine |
| POST `/api/ide/git` | P6 | status/commit/push; subcommand allowlist; **`config` denied** (can't defeat the per-op PAT); PAT request-scoped | argv unit tests |
| POST `/api/ide/search` | P7 | `rg --json`, query after `--` (no flag injection) | parser + argv tests |
| POST `/api/ide/fs` | P4 | editor→container write (base64 argv, path-traversal guarded) | argv test |

Frontend shipped (always on since the P3 cut-over removed `osio.ide`; static-verified —
typecheck + eslint + canvas green): **terminal** (xterm.js over `/api/ide/pty`,
lazy-loaded, resize propagated), **LSP** (dependency-free JSON-RPC client `lspProtocol.ts`
over `/api/ide/lsp`; Monaco providers + diagnostics store + Problems panel), **live sync**
(materialize on attach, editor→container mirror, `/api/ide/fsync` writeback → page CRUD
with ignore-set + sha256 echo-suppression), and the **Source Control panel** (P6;
status/commit/push, graceful "no sandbox" offline).

## Remaining to finish

1–3. ~~Terminal (P3)~~, ~~LSP client (P5)~~, ~~live sync loop (P4)~~ — **done** (routes table).
4. **fly-machines provider (P7):** a drop-in behind `ide-docker`'s interface —
   deferred (YAGNI until a fly deploy is attempted).
5. ~~Live activation (Part E)~~ — **done on the VM (2026-10-14)**: `verify.sh` 41 passed, 0 failed,
   1 skipped (the runner probe); real-session PTY green. Another host needs the host prep first.

## Trade-off notes

- **SUPERSEDED (2026-09-16):** the paragraph below is the original rootless-dind design;
  the deployed daemon is the rootful, userns-remapped `docker-ide.service`.
- **Rootless dind vs. host DOCKER-USER iptables.** Condition 1 drove the rootless-dind
  choice; rootless dind can't program host `DOCKER-USER` chains, so the off-box block rests
  on the `internal` sandbox network (no default route) + the connect-time-IP-validating
  egress proxy, not host iptables. The dind daemon sits in a rootlesskit netns with no
  backend route, so the "gateway pivot" the deny-rules would block leads nowhere useful —
  a deliberate, documented substitution.
