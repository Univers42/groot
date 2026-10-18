# 0011. Each IDE user runs as their own uid, bound at the socket proxy; public `verified` access waits

- Status: accepted with conditions (A1–A3, B1–B4, C, D in the verdict). `verified` in public is
  blocked (B1.L1–L7). Phase A built on `feat/ide-per-user-uid` (A1–A3 minus the user-run A3.8 and
  A3.9); nothing deployed.
- Date: 2026-10-17
- Deciders: devil, `/goinfre/dlesieur/.groot-vault42-recover/devil-verdict-ide-every-user-2026-10-17.md`.
  The user runs the docker-ide probes (A3.8, B3.2, D1–D4), the load test (B2.2) and the rollout, and
  decides the sign-up posture (go-public G3).

## Context

- Every box runs as `10001:10001` (`ide-socket-proxy/create-shape.mjs:96,171`,
  `osionos scripts/ide-sandbox-spec.mjs:93`). Under userns-remap (`dockremap:165536:65536`, b2b
  `/etc/subuid`) that is host uid 175537 for every user.
- b2b `kernel.yama.ptrace_scope` = 0, and `/var/lib/docker-ide` is `drwx--x--- root` (read-only ssh,
  2026-10-17). An escape that keeps the mapped uid can ptrace other boxes and walk
  `/proc/<pid>/root` into them. An escape to root is not affected by uids.
- The local volume copy-up resets an empty volume's root to the image directory's owner
  (`10001:10001 755`) on mount. That happens on a fresh volume after an init chown at another path,
  and on a home the user emptied. Measured on local rootless docker 28.1.1 with
  `osionos-ide-sandbox:home-7df441cd` (verdict F1, F3, G2). `volume-nocopy` prevents it (G1).
- `chown -R` as container root with CHOWN+FOWNER stops at 0700 directories (rc=1). With
  DAC_READ_SEARCH it completes (E3, E3b). Symlinks are not followed (E3c).
- An exec with no User inherits the create User. An explicit exec User overrides it (E4).
- `insert … on conflict do nothing` burns one sequence value per conflict. Behind a restored
  sequence, it silently returns no row on a uid collision (E7, Postgres 16).
- The local volume driver supports `size` through xfs project quota (moby
  `daemon/volume/local/local_unix.go:23-27,65-71,181-183`). docker-ide's root is xfs prjquota (b2b
  `/proc/mounts`).
- Unknown when this was written: `size` on docker-ide 29.9.1, the init chown under userns-remap,
  runsc under userns-remap, inode bounds under project quota, and hypervisor IO sharing between sda
  (ide_crypt) and sdb (prod).

## Decision

- A box runs as `<uid>:10001`, with the uid in 20000..59999.
- The socket proxy holds a persistent owner↔uid ledger and refuses any create that disagrees with
  it. It also recomputes the workspace digest from the owner and workspace labels.
- The proxy allocates the uid (option b of A1.3): `POST /osio/v1/uid` returns the owner's bound uid or
  the next one above every bound uid. There is no database table, no migration and no uid in the
  token, so verdict A1.4 (the DB-side sequence work) is moot.
- Execs carry no User. Both box mounts are NoCopy.
- Volume ownership is set by `ideinit-<digest>`, the only create shape with capabilities: CHOWN,
  DAC_READ_SEARCH and FOWNER; no network; read-only; the sandbox image at the real targets; a fixed
  entrypoint; no exec route. It runs before every box create and does nothing when the roots already
  match.
- Volume size comes from the local driver's `size` option, pinned to exact strings, if docker-ide
  honours it.
- Access stays `allowlist` by default. An operator-`approved` mode may follow. `verified` in public
  waits for the sign-up posture, the gVisor measurement, disk accounting and a plane-side gate.

## Alternatives considered

- **The DB sequence as the sole uid authority** (the plan): restores, a second backend through
  `make link`, and swallowed conflicts all break the binding silently (E7). The files on docker-ide
  would carry the old binding, and nothing on the VM would notice.
- **A uid hashed from the userId**: 40 000 slots collide by the birthday bound (about 2 % at 43
  users, about 67 % at 300), and a collision is exactly the shared-uid state A removes.
- **An init container from a minimal image at `/v`** (the plan): undone by copy-up on the box's first
  mount (F1, F3).
- **CHOWN+FOWNER only** (the plan): cannot migrate or repair a volume with 0700 directories (E3).
- **A per-user gid**: needs a user-writable /etc/group, which runc reads (ADR 0009 forbids it), and
  adds nothing behind 0700 roots.
- **A root-owned VM quota helper** (the plan's fallback): a new privileged component, when the
  platform's volume `size` may already do the job. It comes back only if B3.2 fails.
- **The rootfs StorageOpt quota**: a no-op on a read-only rootfs (`create-shape.mjs:118`).
- **An 8 GiB slice**: MemAvailable 6.83 GB with the slice at 1.34 GB gives about −0.42 GB at a full
  8 GiB, against the plan's own 1.5 GiB floor.

## Consequences

- The proxy gains state (the ledger volume `osionos-ide-ledger`, jsonl, rename + fsync writes). Losing
  it re-learns bindings by trust on first use. The file carries a `Caveat:`. Allocation is highest + 1,
  so a hand-deleted line frees its uid only when it was the top one.
- `POST /osio/v1/uid` is gated by the control network alone: any caller there can bind an owner.
- The init is a no-op when the roots already match, so it can change ownership under a still-running
  box of the same owner in another workspace (B2.4 is not enforced).
- A running box without the `osio.ide.uid` label is replaced on its next use.
- A rollback to a 10001 image cannot read volumes already chowned to a per-user uid without a user-run
  `chown -R` on docker-ide.
- GDPR removal of a user is user-run: the volumes plus the ledger line. Automating it is a
  precondition of `verified` (B1.L3).
- The uid check defends against a buggy bridge or DB, not a compromised ide-server, which already
  chooses the owner label. An asymmetric IDE token is the follow-up that closes that (B1.L5).
- An idle-based stop (20 min) shortens how long background processes survive a closed terminal.
