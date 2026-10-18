# A shell for every verified user on the prod kernel is out of scope

- Decided: 2026-10-18 · by devil (two rulings, recorded in [ADR 0022](../docs/adr/0022-terminals-the-operator-first-every-verified-user-on-a-second-secret-free-vm.md))
- Holds while: the kernel that would run strangers' code is the baas VM kernel, which also runs prod Postgres,
  GoTrue and the mail sender, and the guest reports SRSO and TSA as `Vulnerable`

## The concept

The request: every account that can sign in on the public deployment (`OSIONOS_IDE_ACCESS=verified`, then the
owner's design of a per-user space on the baas Debian VM, hardened with gVisor, like 42's shared machines)
gets a terminal box on the baas VM.

## Why not

The boundary the plan relies on is not the one that applies.

- In the baas guest, `/sys/devices/system/cpu/vulnerabilities/spec_rstack_overflow` reads `Vulnerable: Safe
  RET, no microcode` and `tsa` reads `Vulnerable: Clear CPU buffers attempted, no microcode`. The host has the
  microcode, but its kernel 5.15.0-191-generic and qemu 6.2.0 cannot pass the CPUID bits to the guest. Both
  belong to 42, so the owner cannot fix it.
- A speculative-execution read needs no syscall and no capability, and ignores uid, namespaces, seccomp and the
  gVisor Sentry (gVisor's threat model excludes it). Containers, per-user uids and gVisor do not touch it.
- That kernel runs `mini-baas-postgres` (about 90 real accounts, already leaked once on 2026-10-17), the GoTrue
  secret that signs every session, and the Titan sender. No working exploit was measured; UNKNOWN = FAIL.
- Separately, `IOWeight` is inert on that VM, so a box competes with prod Postgres for I/O.
- What would have to change: the boxes move to a kernel that holds none of that, or prod leaves this one.
  The accepted route is the secret-free ide VM in the ADR.

## Prior requests

- 2026-10-18: the `verified` plan on baas (blocked in the first ruling).
- 2026-10-18: the owner's same-VM design with gVisor (blocked in the second ruling).

## Reopen when

Both guest `vulnerabilities` files for `spec_rstack_overflow` and `tsa` read `Mitigation: ...`, meaning a host
kernel and qemu that pass the CPUID bits, or prod no longer runs on the kernel that hosts the boxes.
