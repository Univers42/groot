# Tearing the IDE egress rules down when docker-ide stops is out of scope

- Decided: 2026-10-19 · by devil (ruling SEC3, ADR 0024)
- Holds while: boxes can outlive dockerd, which they do (they run under the system containerd, in
  `osionos-ide.slice`, not in `docker-ide.service`'s cgroup)

## The concept

The request, and the original drop-in: run `osionos-ide-egress-nat down` as `ExecStopPost` so that stopping
docker-ide leaves no rules behind.

## Why not

- `ExecStopPost` also runs after a failed start and after dockerd dies abruptly (panic, OOM, SIGKILL after
  `TimeoutStopSec`). On that path the boxes keep running and the firewall disappears under them until the
  next dockerd restores and shuts them down: `RestartSec=3` plus the restore, with `live-restore` off.
- The rules match only 10.202.0.0/16, which nothing else uses, so leaving them loaded costs nothing.
- `down` remains for a manual uninstall.

## Prior requests

- The first `install-egress-nat.sh` (2026-09-16) wired `ExecStopPost=-… down` together with a fail-open
  `ExecStartPost=-… up`.

## Reopen when

Boxes are proven to die with dockerd on every exit path, crash and SIGKILL included.
