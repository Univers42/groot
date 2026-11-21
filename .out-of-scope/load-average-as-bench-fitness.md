# A system-wide load average as a benchmark fitness criterion is out of scope

- Decided: 2026-11-21 · by devil (ruling `/mnt/storage/dlesieur/scratch/me-d/D4-LIFT.md`, ADR 0068)
- Holds while: the markengine A/B runs cpuset-pinned on this shared host (VM, browser, agents as co-tenants)

## The concept

Void a benchmark pair when the host's load average is above a fixed bound (3.0 in D4c), on the theory
that a busy host compresses the measured difference.

## Why not

- It voids on contention-free load: kworker threads in D-state raise the load average without using the
  pinned cores (three D4c runs voided this way, `logs/d4-aa-b6dc3fd-void{1,2,3}.log`).
- It misses the contention that matters: qemu vCPU threads on the pinned cores count once in a host-wide
  number that other cores dominate.
- It counts the benchmark's own runnable threads.
- The per-core gate (foreign time on the pinned cores ≤ 5 %) with an in-run A/A arm measures the
  contention directly; its smoke test fired on a single pinned spinner (D4L5).

## Prior requests

- 2026-11-21 (ADR 0068 D4c): load ≤ 3.0 per pair.

## Reopen when

The benchmark runs on an isolated host, or on CPUs reserved from the scheduler (isolcpus or a cpuset
partition), where the load average is dominated by the benchmark alone.
