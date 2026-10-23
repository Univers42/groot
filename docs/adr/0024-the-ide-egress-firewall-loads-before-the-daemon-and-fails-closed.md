# 0024. The IDE egress firewall loads before the daemon and fails closed

- Status: accepted (code); live install waits for the baas rebuild
- Date: 2026-10-19
- Deciders: owner, after a devil ruling (SEC3, 2026-10-19, Part A: PROCEED-WITH-CONDITIONS; live install on the current VM: BLOCK)

## Context

- `docker-ide` runs `--iptables=false` (`docker-ide.service:55`). The rules from `ide-egress-nat.sh` are the
  only filter on its 10.202.0.0/16 pool, and a box without them can reach the VM's own :8443 and :8880.
- `install-egress-nat.sh` wrote a drop-in with `ExecStartPost=-… up` and `ExecStopPost=-… down`. The dash made
  it fail open on purpose: a failed `up` left the daemon serving, and only a manual `verify.sh` noticed.
- `up` filters in five steps: filter chain (atomic), DOCKER-USER jumps, raw, nat, nft bridge table. A failure
  at the nft step leaves box-to-box L2 open on the shared bridge, with the daemon serving indefinitely.
- `ExecStopPost` ran `down` on every stop. Boxes live in `osionos-ide.slice/docker-<id>.scope` under the
  system containerd, not in `docker-ide.service`'s cgroup (`Delegate=yes`, `KillMode=process`). When dockerd
  dies abruptly they keep running, and `down` removed the firewall under them for the 3 s `RestartSec` plus
  the next dockerd's restore (`live-restore` is off in `docker-ide.daemon.json`).
- `up` needs nothing dockerd creates. It matches addresses, and the bridge by a runtime string
  (`meta ibrname != "osio-ide-sbx"`, `ide-egress-nat.sh:100`), so it may run before the bridge exists
  (`bootstrap.sh:27-29`). It needs `nft`, `iptables-restore` and a default route (`ide-egress-nat.sh:56-57`).
- Measured on systemd 249 (a transient user unit, not baas, which runs a newer systemd):
  - F1. A failed `ExecStartPost` triggers `Restart=on-failure`: 8 restarts in about 27 s, `SubState=auto-restart`,
    start limit (10 s / 5) never reached. `ExecStopPost` ran after every failed start. `RestartSec=3` allows
    at most 4 starts in 10 s, so the loop never ends.
  - F2. With a socket-activated unit the socket stayed `active` with the same inode across 4 restarts and
    accepted a client connect. The socket proxy's bind-mount stays valid.
  - F3. `systemctl show -p ExecStartPost` reports `code=`/`status=` of the last run without root.
  - F4. At 2026-10-19 01:09 both baas disks of qemu pid 153241 answer ESTALE (`baas.qcow2`, and
    `baas-ide.qcow2`, the docker-ide data-root).

## Decision

- The drop-in is exactly:
  ```
  [Service]
  ExecStartPre=/usr/local/sbin/osionos-ide-egress-nat up
  ```
  No dash, no `ExecStartPost`, no `ExecStopPost`. If `up` fails, dockerd never starts.
- `down` is manual, for uninstall only. The rules match only 10.202.0.0/16, which nothing else uses, so
  leaving them loaded while the daemon is stopped costs nothing.
- `install-egress-nat.sh print` shows the drop-in without root.
  `scripts/tests/ide-egress-nat-dropin.bats` asserts on it: one `ExecStartPre` for `up`, zero
  `ExecStartPost`/`ExecStopPost`, zero `=-`. Each of the three regressions was shown red against it.
- The change does not cover rules removed while the daemon runs (`iptables -F`, `nft flush ruleset`, a
  firewall reload). Only `ide-egress-nat.sh check` and `verify.sh` find those.

## Alternatives

- **Keep fail-open.** A failed or partial `up` leaves boxes open with the daemon serving, silently.
- **`ExecStartPost=` with no dash.** Fail closed, but dockerd READY comes before any rule loads, and a failed
  `up` becomes a dockerd start/stop loop forever on the prod VM (F1), restoring the egress proxy and
  deleting `docker-bridges` nft tables each cycle (`install-docker-ide.sh:72-75`).
- **Keep `ExecStopPost down`.** It buys nothing on a clean stop, and on a dockerd crash it removes the firewall
  under live boxes. See `.out-of-scope/ide-egress-rules-torn-down-with-the-daemon.md`.

## Consequences

- A1-A4 (repo): the drop-in, the header and README Activation step 3, the bats test with mutation proofs,
  shellcheck on the changed file. `shfmt` was not run (not installed).
- A5 (operator): nothing write-bearing on the current baas while its disks answer ESTALE: no installer, no
  daemon-reload, no restart, no bootstrap, no `verify.sh`. Read-only:
  `systemctl show docker-ide -p ExecStartPost -p NRestarts` for the 2026-10-17 17:09:41 start. If
  `status` is not 0 the IDE has run unfiltered since then: cut non-operator access with the kill switch,
  or wait for the rebuild.
- A6 (operator, on the rebuilt baas, after install-docker-ide, install-egress-nat, bootstrap):
  - `sudo osionos-ide-egress-nat down; sudo systemctl restart docker-ide` gives `active` and `check` all `ok`.
  - Fail-closed proof: a temporary `zz-failtest.conf` with `ExecStartPre=/bin/false`; the restart exits
    non-zero, `SubState=auto-restart`, `NRestarts` rises, `docker -H unix:///run/docker-ide.sock version`
    fails, `stat -c %i /run/docker-ide.sock` is unchanged. Remove it, daemon-reload, restart: `active`.
  - `verify.sh` green at the pin of the revision run (at fe81aab8: 55 passed, 0 failed, 2 skipped, expected 57).
  - Record `StartLimitIntervalUSec`, `StartLimitBurst`, `RestartUSec` (expect 10 s / 5 / 3 s).
- The permanent failures of `up` (no `nft`, no `iptables-restore`) now mean the IDE stays down until fixed.
  That is the intent. Transient ones (no route at boot, xtables lock contention) heal through the 3 s retry.
- Systemd 249 was measured; baas runs a newer one. A6 re-measures on baas.
