# 0005. Run the IDE plane on baas, reached over a terminal-only ssh forward

- Status: accepted with conditions (nothing has been built or deployed yet)
- Date: 2026-10-15
- Deciders: devil (risk ruling of 2026-10-15 ~23:45, conditions T0–T35). The user, who runs the sudo
  steps on the VM and merges the PRs, has to live with it.

## Context

- The VM that served the IDE plane on 2026-10-14 (`verify.sh` 41/0/1) was rebuilt as baas. Only the
  encrypted `ide_crypt` volume survived: `docker-ide.service` and `docker-ide.socket` are not-found, no
  `/run/docker-ide.sock`, no IDE images, no `osionos-ide-plane` containers (measured 2026-10-15 23:20).
- groot now reaches baas in direct mode over Funnel (ADR 0004). `up_direct` opens no ssh master, so
  `link_ide_plane` (`scripts/grobase-link.sh:135`, `scripts/lib/grobase-link-ide.sh`) never runs and the
  `grobase-link-ide` relay has nothing to forward.
- The bridge refuses every subject while `OSIONOS_IDE_ALLOWED_SUBJECTS` is empty
  (`ide-sandbox-spec.mjs:23`).
- C21 (2026-10-14): the plane is never exposed publicly; `check-plane.sh` proves no tailscale serve or
  Funnel target reaches it.

## Decision

1. Reinstall the plane on baas with the existing runbook
   (`infrastructure/docker/osionos/ide-sandbox/README.md`): a second rootful dockerd `docker-ide`
   (userns-remap, capped slice), the egress NAT, then `osionos-ide-plane` (socket proxy + ide-server from
   the bridge image). The VM never builds: images are built on the host from a fresh origin/main
   worktree and shipped by digest.
2. The BaaS stays on Funnel. Only the terminal travels over ssh: a new optional key in
   `.env.grobase-link`, `GROBASE_IDE_SSH=<ssh alias>`, makes `make link` in direct mode open one ssh
   master that carries exactly one unix-socket forward to the plane's ide-server (`:4100`). No BaaS name
   is routed over it. Unset, the link behaves byte-identically to today (zero ssh calls).
3. The relay is started only when that forward exists (`ide-linked` in
   `infrastructure/makes/grobase-link.mk`), and a failed ssh open is a note, not a failed `make link`.
4. The allowlist holds one subject: the `sub` of the owner's own osionos session, pasted by the user.
5. `gen-local-env.sh` copies `UNSPLASH_ACCESS_KEY` and `PIXABAY_API` into `.env.local` when they are
   absent there, so a fresh clone keeps media search working. The `--sync` / `--check` exit status stays
   decided by the derived BaaS keys only.
6. The bridge, mount-list and portal fixes reach a fresh clone through PRs into develop that the user
   merges; groot's pins move after that, under a separate ruling.

## Consequences

- One more ssh dependency, for the terminal only. If ssh to the VM is down, everything but the terminal
  keeps working.
- Four steps need the user's tty on the VM (`install-docker-ide.sh`, `install-egress-nat.sh`,
  `verify.sh`) and the user's browser (the allowlisted session). Green `verify.sh` is
  `RESULT: 43 passed, 0 failed, 1 skipped (expected 44)`.
- Memory: the plane must not take more than 1 GiB of the VM's available memory; at most 2 boxes.
- Rollback, written before the install: plane `compose down` (volumes kept), NAT `down`, daemon
  `disable --now`, bridge allowlist emptied.

## Not decided here

- Public or Funnel exposure of the terminal (declined, C21).
- The groot pin bump after the merges.
