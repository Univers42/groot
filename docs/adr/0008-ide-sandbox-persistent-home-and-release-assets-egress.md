# 0008. Give each IDE user a persistent home at /home/coder and let the egress reach GitHub release assets

- Status: accepted with conditions. S3 identity is blocked; nothing has been built yet.
- Date: 2026-10-17
- Deciders: devil (ruling of 2026-10-17, conditions E1–E7, H1–H9, U1–U6, L1–L5, R0–R9;
  `/goinfre/dlesieur/.groot-vault42-recover/devil-verdict-ide-user-shell-2026-10-17.md`). The user runs
  the VM root steps and has to live with it.

## Context

- GitHub release downloads end at `release-assets.githubusercontent.com` (2 redirects, measured
  2026-10-17). That host is not in the egress allowlist
  (`infrastructure/docker/osionos/ide-egress-proxy/proxy.mjs:40-45`), and refusals are not logged
  (`:107-111`).
- A box's home is a 64 MB tmpfs, wiped on every box start
  (`apps/osionos/app/scripts/ide-sandbox-spec.mjs:102`). A user install into `~/.local` and any shell
  choice are lost at the next start. `chsh` cannot work: the rootfs is read-only and no-new-privileges
  is set.
- IDE volumes have no size quota (`apps/osionos/app/scripts/ide-docker.mjs:83`). `diskSize` is the
  container rw layer only (`ide-sandbox-spec.mjs:76-79`). No path deletes an IDE volume
  (`ide-socket-proxy/proxy.mjs:43-58`).
- Measured: a volume mounted at a path absent from the image is `0:0 755` and uid 10001 cannot write
  it. At `/home/coder` it is `10001:10001`, with the skel files copied up.
- Measured: `LD_PRELOAD=libnss_wrapper.so` makes every gcc `-fsanitize=address` binary abort ("ASan
  runtime does not come first"), and a user-set ASAN_OPTIONS undoes the `verify_asan_link_order=0`
  workaround.
- Unknown when this was written: whether runc resolves the exec user and HOME after the mounts under
  userns-remap (this decides option (iii) for the identity mechanism).

## Decision

1. The egress allowlist includes `release-assets.githubusercontent.com` (exact or dotted suffix, like
   every entry). Every refusal logs one sanitized `DENY <host>:<port> <reason>` line.
2. Each IDE user has one named volume `osio-ide-home-<sha256(userId)[:32]>` mounted at the constant
   `/home/coder`, shared by that user's workspaces. The socket proxy recomputes the volume name from the
   owner label.
3. A PTY `safe=1` mode starts `bash --noprofile --norc`. It is the way out of a broken persistent rc.
4. The shell choice lives in `~/.config/osio/login-shell`, read and validated at each launch by
   `/usr/local/bin/osio-login`. A user `chsh` shim writes it.
5. The username may ride in the signed IDE token (sanitized, optional, re-validated in the VM). It
   ships only with an identity mechanism that passes the ASan, HOME and read-only-/etc tests.

## Alternatives considered

- **Home at `/home/<username>`**: the volume root is root-owned and unwritable, and the docker-exec
  HOME (from the image passwd) would diverge (measured; `.out-of-scope/ide-home-at-home-username.md`).
- **nss_wrapper with an exported LD_PRELOAD**: breaks ASan for every terminal program (measured;
  `.out-of-scope/ide-identity-via-global-ld-preload.md`).
- **Adding the host through `OSIONOS_IDE_EGRESS_GIT_HOSTS`** (`bootstrap.sh:39`): needs no rebuild,
  but it puts a release CDN in the git-host knob and still restarts the proxy. Acceptable only as a
  stopgap while the host disk cannot build.
- **Home per (user, workspace)**: no cross-workspace persistence, but the shell and `~/.local` would
  have to be reinstalled in every workspace, which is the complaint.

## Consequences

- Home data now persists, unbounded like /workspace and limited by the docker-ide data-root. Before a
  second subject is allowlisted, that bound is re-ruled.
- Code run in one workspace can plant rc files that run in the user's other workspaces (up to 2 boxes
  at once). Written down, and accepted for a single subject.
- Deleting a user's IDE volumes is a manual, user-run VM step until a GDPR path exists (follow-up).
- `verify.sh` EXPECTED grows by the new probes (H8). The green line is restated before the run.
- Reverse: unpin to the previous image ids and `compose down` without `-v`. The home volumes remain and
  must be removed by hand if wanted.
