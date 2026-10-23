# A disk quota on the IDE box's root filesystem is out of scope

- Decided: 2026-10-17 · by devil (devil-verdict-ide-every-user-2026-10-17, B3)
- Holds while: the box is created with `ReadonlyRootfs: true`

## The concept

Turn on `OSIONOS_IDE_STORAGE_QUOTA` (overlay2 `StorageOpt.size`, for example 2 GiB) so that each box's
root filesystem has a disk limit, as part of giving every user a bounded sandbox.

## Why not

- The box's rootfs is read-only. The proxy pins it (`ide-socket-proxy/create-shape.mjs:118`) and the
  bridge sends it (osionos `scripts/ide-sandbox-spec.mjs`, `ReadonlyRootfs: true`). The container's rw
  layer receives no user writes, so a limit on it bounds nothing.
- The writable places are /tmp (a 64 MiB tmpfs counted against the box's memory cgroup) and the
  `/workspace` and `/home/coder` volumes. The disk bound belongs on the volumes (verdict B3.2/B3.3).
- Turning it on only adds a create-time dependency on xfs project quota that a failed probe would
  turn into "every create refused".

## Prior requests

- 2026-10-17 (plan-ide-every-user, B3): "rootfs StorageOpt size 2 GiB on".

## Reopen when

The box rootfs becomes writable, meaning `ReadonlyRootfs` is false in the proxy's pinned shape.
