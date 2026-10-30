# 0022. Terminals stay allowlist-only: the operator first, then at most five named users

- Status: accepted
- Date: 2026-10-19
- Deciders: owner, after two devil rulings (2026-10-18) and a second VM that was built and dropped

## Context

- The public app answers Terminal > New Terminal with "Sandbox disabled" for every account. The bundle
  carries no IDE origin and `public-funnel.sh verify` fails on any IDE token secret (N1/N2).
- The owner asked for every signed-in user to get a space of their own on the baas Debian VM, the way
  42 shares one machine. The devil blocked that for anyone but named users, even with gVisor. The guest
  reports `spec_rstack_overflow` and `tsa` as `Vulnerable ... no microcode`, and that kernel runs prod
  Postgres, the GoTrue secret and the mail sender
  (`.out-of-scope/ide-for-every-verified-user-on-the-prod-kernel.md`).
- The accepted alternative was a second Debian VM `ide`, holding no secrets, for every user. It was built
  on 2026-10-18 (branch `feat/ide-vm`, not merged) and measured:
  - The isolation held. qemu ran with `restrict=on` and the guest had two exits. From the guest,
    `10.0.2.2:1055`, `:4242` and `:6379` were closed and there was no DNS. The `docker-ide` default
    runtime was `runsc`.
  - `verify.sh` under `runsc` gave `RESULT: 45 passed, 11 failed, 1 skipped (expected 57)`.
  - At 2026-10-18 23:47 `/sgoinfre/students/dlesieur` was emptied. Under the running VMs, the ide data
    disk and `baas.qcow2` began answering `Stale file handle`. `/goinfre` had been wiped the same day.
    This seat has no disk that keeps a user's home.
  - The host had about 7 GiB available, enough for three boxes.
- The owner dropped the second VM on 2026-10-19.

## Decision

- `OSIONOS_IDE_ACCESS` stays in {unset, `allowlist`, `off`}. The owner pastes the subject list. It is
  never read from `auth.users` or from logs.
- **Stage 0** is the operator's own subject only. It has no public ingress: the bundle keeps
  `VITE_OSIONOS_IDE_URL` empty and verify keeps N1/N2. Conditions S1–S9 apply.
- **Stage 1** allows at most five named subjects, each a person who accepted the acceptable-use notice.
  It needs R1–R12: gVisor as the default runtime with the plane refusing anything else, budgets, OTP
  step-up before the first box, a third Funnel node serving 443 only, and the residual signed in this file.
- There is no terminal for every user on this seat
  (`.out-of-scope/ide-terminal-for-every-user-on-the-seat.md`).
- Landed for stage 1, each off by default:
  - The socket proxy receives `OSIONOS_IDE_REQUIRE_RUNTIME` from compose. Before this, the K11 check
    existed in code but compose never passed it the variable.
  - `--build-arg STRIP_SETUID=1` removes every setuid and setgid entry (R8).
  - The pids floor is raised to 64 under a pinned runtime.
  - `OSIONOS_IDE_INIT_PIDS` in verify.sh.

## Consequences

- Visitors keep seeing "Sandbox disabled". That is the intended state, not a defect.
- Stage 1 on gVisor inherits the 11 differences measured on the ide VM:
  - **Kernel-view checks need expectations written for gVisor:** the `uid_map` host id, box and slice
    `memory.max`, `unshare -Ur` succeeding, and the `/tmp` mount flags.
  - **`kill 1` stops the box.** It only harms the user who runs it, but the box-B checks fail after it.
  - **The egress name `ide-egress` does not resolve in a `runsc` box**, so the box's `HTTP_PROXY` must
    use the IP. That changes the pinned create shape (`ide-socket-proxy/create-shape.mjs`) and needs the
    devil's ruling first.
- Every step on baas waits until baas has a disk again (the 2026-10-18 23:47 event).
- The residual for stage 1 (K1/K2 unmitigated, slirp reaching host loopback, and the roster being trusted
  people rather than a boundary) is not signed yet. Stage 1 does not open without that signature.

- **Amendment 2026-10-30:** the owner's own machines now get terminals through VS Code's server ([ADR-006](../ide/ADR-006-vscode-backend-osionos-host.md), [0034](0034-the-ide-runs-on-vs-codes-server-behind-a-non-public-node-proxy.md)), owner only. This ADR still governs the hosted sandbox and every non-owner user (C21 BLOCKED).
