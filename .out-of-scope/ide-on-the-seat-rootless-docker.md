# Running the IDE boxes on the seat's rootless docker is out of scope

- Decided: 2026-10-18 · by devil (first IDE ruling, [ADR 0022](../docs/adr/0022-terminals-the-operator-first-every-verified-user-on-a-second-secret-free-vm.md))
- Holds while: the IDE host's uid owns the prod VM disk or a prod credential, or the host's rootless docker
  lacks the `cpu` and `io` cgroup controllers

## The concept

Run the per-user boxes on the rootless docker of the school seat (c2r19s6), the host that also runs the
frontends, instead of on the baas VM.

## Why not

- The host uid `dlesieur` owns the running prod VM: qemu runs as that uid, and `baas.qcow2` (prod Postgres at
  rest) and `monitor.sock` are dlesieur-owned. An escape from a box lands there.
- That uid also holds the ssh key to b2b, `42admin.env`, the GitHub token and the tailnet node state, and the
  host loopback carries tailscaled's SOCKS5 proxy into the tailnet (`127.0.0.1:1055`).
- The rootless docker delegates only `memory` and `pids`, so `NanoCpus` cannot be enforced: a box's CPU limit
  is not a limit.
- The seat belongs to 42, and the egress leaves from the school's IP.

## Prior requests

- 2026-10-18: raised as a placement option in the first IDE ruling and ruled out there.

## Reopen when

The IDE runs on a host whose uid owns neither the prod VM disk nor any prod credential, with the `cpu` and
`io` cgroup controllers delegated.
