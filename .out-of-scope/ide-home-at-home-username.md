# An IDE home directory named after the osionos username is out of scope

- Decided: 2026-10-17 · by devil (ruling devil-verdict-ide-user-shell-2026-10-17, S3c)
- Holds while: a named volume mounted at a path the image lacks comes up root-owned in the box

## The concept

When a user opens the IDE terminal, their home is `/home/<their osionos username>` rather than
`/home/coder`, so `~` and `pwd` show their own name.

## Why not

- The fact that decides it: a `local` named volume mounted at a path absent from the image comes up
  `0:0 755`, and uid 10001 gets "Permission denied" on `touch`. Mounted at `/home/coder` (created by
  `useradd` in `infrastructure/docker/osionos/ide-sandbox/Dockerfile:148`), it comes up
  `10001:10001` with the skel files copied up. Measured on the local daemon on 2026-10-17. Under the
  VM's userns-remap the root owner maps to the subuid base, which is still not 10001.
- docker exec takes HOME from the image's /etc/passwd, so git, LSP and fs-agent would keep
  HOME=/home/coder, and the rootfs there is read-only once the tmpfs is gone.
- A per-name path also turns a username change, or a failed lookup that falls back to `coder`, into a
  different mount path and broken absolute paths in `~/.local`.

## Prior requests

- 2026-10-17 (dylan): "each username of the database … is used to create an account of the user
  sandbox".

## Reopen when

The sandbox can create a per-name mountpoint that is owned by 10001 at create time (an image-time
directory or a docker volume option that sets the owner), and every exec spec sets HOME to it, proven
by a probe that writes `~/.cache` from the git, LSP and fs-agent execs.
