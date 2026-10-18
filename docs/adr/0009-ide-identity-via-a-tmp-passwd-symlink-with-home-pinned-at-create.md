# 0009. Name the IDE user through a /tmp passwd symlink, and pin HOME in the box's create Env

- Status: accepted with conditions (P1–P12). Nothing built yet. This supersedes the S3 identity
  part of 0008.
- Date: 2026-10-17
- Deciders: devil (re-submission ruling "S3b(iii)" in
  `/goinfre/dlesieur/.groot-vault42-recover/devil-verdict-ide-user-shell-2026-10-17.md`). The user
  runs the docker-ide probe (P11) and the browser acceptance (P7).

## Context

- 0008 blocked a global `LD_PRELOAD=libnss_wrapper.so`, because it aborts gcc ASan (measured).
- The box's rootfs is read-only, with no-new-privileges, CapDrop ALL and a numeric User
  (`ide-socket-proxy/create-shape.mjs:87,107-109,159`). Every process in the box runs as uid 10001.
- Measured on rootless docker 28.1.1 / runc 1.2.5 (throwaway image, 2026-10-17):
  - With `/etc/passwd` → `/tmp/.osio/passwd` and the file renamed to `dylan`, `whoami` and `id` print
    dylan.
  - dockerd resolves user names against the image rootfs and never sees the tmpfs, so `-u coder`
    fails closed.
  - runc parses the user-written file as container root on every exec, and only Home is taken from
    it. uid, gid and groups come from the numeric spec: a `root:x:10001:…` entry gives
    `uid=10001(root)` and no access.
  - A FIFO there hangs every exec. A line over 64 KB, `/dev/zero`, or a directory makes every exec
    fail. In both cases only a box stop recovers.
  - A create-Env `HOME=/home/coder` holds HOME against any file contents.
- The bridge's stop route has no UI caller (`apps/osionos/app/scripts/bridge-ide-sandbox.mjs:205-209`).
- Unknown when this was written: the runc and dockerd versions on docker-ide (rootful,
  `--userns-remap=default`). P11 measures them before the host bridge goes live.

## Decision

The image ships `/etc/passwd.base` and links `/etc/passwd` to `/tmp/.osio/passwd`. `/etc/group` is
static. box-init writes the `coder` default at start, and `osio-login` rewrites it with the validated
name from the PTY exec Env before it starts the shell. HOME is pinned once, as the create Env's 8th
entry `HOME=/home/coder`. The socket proxy requires that entry and refuses any other `HOME=` in an
exec Env. A browser action on the existing stop route is the recovery path.

## Alternatives considered

- **nss_wrapper with a global LD_PRELOAD**: breaks gcc ASan (0008, measured).
- **Prompt only (USER/LOGNAME/PS1)**: zero risk, but `whoami` keeps saying coder. It stays the
  fallback if P11 fails.
- **Per-exec `HOME=` on each bridge exec builder**: five or more call sites, each one a chance to
  forget, and the exec Env is free-form in the proxy. One create entry covers PID 1 and every exec,
  and the proxy can enforce it.
- **Identity file on the persistent home volume**: a broken file would survive restarts. runc parses
  it on every exec, so the box would stay bricked for good. A tmpfs resets on restart.

## Consequences

- The box user can make their own box unenterable (FIFO, long line). That is self-only, and a box
  stop cures it. The H4 safe shell no longer guarantees a way in, so P7's restart action is required.
- The design depends on no-new-privileges. Without it, a user-written passwd plus a setuid `su` gives
  root in the box. Any change to the NNP, CapDrop, read-only rootfs or numeric User pins re-opens this
  decision.
- Reverse it by restoring a regular `/etc/passwd` in the image. The create-Env HOME pin can stay.
