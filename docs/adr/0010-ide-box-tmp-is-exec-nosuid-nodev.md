# 0010. The IDE box's /tmp is mounted exec, keeping nosuid and nodev

- Status: accepted with conditions (X1–X7). Not built yet.
- Date: 2026-10-17
- Deciders: devil, in the addendum "exec on /tmp" to
  `/goinfre/dlesieur/.groot-vault42-recover/devil-verdict-ide-user-shell-2026-10-17.md`. The user
  runs the docker-ide probe (X6) and does the rollout (X7).

## Context

- The box's /tmp is `size=64m,mode=1777` (osionos `scripts/ide-sandbox-spec.mjs:122`). The socket
  proxy pins that exact string (`ide-socket-proxy/create-shape.mjs:133`). Docker prepends
  `noexec,nosuid,nodev` to it, which dylan's live box on docker-ide shows. No README, ADR or verdict
  ever chose noexec.
- Precedent: the runner's `/work` was made exec because compiled languages failed. Its reason is
  that isolation rests on caps, seccomp, the read-only rootfs, a non-root user and the network, not
  on noexec (`docker-compose.yml:202-209`, `IDE-BACKLOG.md:315-318`).
- Measured with the real sandbox image (`osionos-ide-sandbox:home-7df441cd`) in the box shape on local
  rootless docker 28.1.1, throwaway containers, 2026-10-17. With noexec /tmp:
  - `go run` fails with `fork/exec /tmp/go-build…: permission denied`.
  - `ctypes.CDLL("/tmp/x.so")` fails with `failed to map segment from shared object`.
  - The hellish installer dies at `user-install.sh:220`.
  - `sh /tmp/script` still runs.

  With `exec` added, all three work.
- Docker's option merge, measured: the last flag wins.
  - `…,exec` gives `rw,nosuid,nodev`.
  - `…,exec,suid` drops nosuid.
  - `…,exec,dev` drops nodev.
- `/workspace` is already exec (xfs, the live box's `/proc/mounts`). After S2 (ADR 0008) the home is
  a named volume, also exec. Every process in a box is uid 10001, and one box serves one
  (user, workspace) pair. No actor can write /tmp without also being able to write /workspace.
- ADR 0009's `/tmp/.osio/passwd` is read by runc, so the exec flag has no effect on it. `whoami`
  and the symlink were the same under both mounts. The 64m size and its quota (ENOSPC) are unchanged.
- Unknown when this was written: the docker-ide daemon version's merge result (X6 measures it).

## Decision

The box's /tmp is `size=64m,mode=1777,exec`, which mounts as `rw,nosuid,nodev,exec`. The socket
proxy admits only that exact string and refuses any variant that drops nosuid or nodev, or changes
the size. User code may run from /tmp, as it already does from /workspace and the home.

## Alternatives considered

- **Keep noexec and tell users to set `TMPDIR=/workspace/.local/tmp`**: this breaks `go run`, `go test`,
  pip build isolation and installers by default. It protects nothing, because every writer of /tmp
  can already write and run code in /workspace.
- **Set `TMPDIR` in the create Env**: this adds a 9th Env entry to the proxy pin (ADR 0009 P5 counts
  8). Temp files would also land on an unbounded persistent volume that is never cleaned, and every
  tool that hardcodes `/tmp` would still fail.
- **Raise the /tmp size along with exec**: this is a separate decision. tmpfs pages count against the
  1 GiB memory cgroup, and no measurement asks for it yet.

## Consequences

- /tmp becomes a common build target, so its 64 MB size is the next wall. A large `go run` or a heavy
  pip build-isolation tree fails with ENOSPC; the escape hatch is `TMPDIR=/workspace/.local/tmp`
  (README `Caveat:`). A full /tmp also keeps the terminal name `coder` (`osio-login.sh:39-48`). That
  fails safe.
- Running boxes keep noexec until they are stopped (`bridge-ide-sandbox.mjs:114-115`). The rollout
  recreates them, as S2 already requires.
- The proxy and the bridge must ship in one window. A proxy admitting only the new string refuses an
  old bridge's creates.
- The day to reverse this is when something other than the box's own uid-10001 user can write /tmp
  but not /workspace, for example a shared box or an injected helper. noexec would then separate
  two writers, and this ruling no longer holds.
