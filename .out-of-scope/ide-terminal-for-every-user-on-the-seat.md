# A terminal for every signed-in user, hosted from this seat, is out of scope

- Decided: 2026-10-19 · by the owner ([ADR 0022](../docs/adr/0022-terminals-stay-allowlist-only-the-operator-first.md))
- Holds while: the IDE would run on the school seat c2r19s6 or on a VM whose disks live on its `/goinfre`
  or `/sgoinfre`

## The concept

Every account that can sign in gets its own persistent terminal space. The place tried last was a second
Debian VM, holding no secrets, beside baas on the same seat.

## Why not

- **No durable disk.** At 2026-10-18 23:47 `/sgoinfre/students/dlesieur` was emptied while the VMs ran,
  and their disks began answering `Stale file handle`. `/goinfre` was wiped the same day. A user's home
  on either one can vanish without warning.
- **Capacity.** The host had about 7 GiB available with the VM up, which is three boxes at once.
- **CPU.** Any guest on this host reports SRSO and TSA as `Vulnerable ... no microcode`. 42 owns the
  host kernel and qemu.
- **gVisor parity.** `verify.sh` under `runsc` gave 45 passed, 11 failed and 1 skipped of 57. Egress by
  name does not resolve in a box.

## Prior requests

- 2026-10-18: `verified` mode on baas (blocked by the devil).
- 2026-10-18: the owner's same-VM design with gVisor (blocked by the devil).
- 2026-10-18: a second, secret-free VM on the seat (built, then dropped 2026-10-19).

## Reopen when

The boxes run on a machine the owner controls, with a disk that survives (rented or owned, off the
school seat), and the devil rules on that placement.
