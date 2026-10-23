# 0015. Syncro never rewinds a submodule behind its gitlink

- Status: accepted
- Date: 2026-10-18
- Deciders: devil (risk ruling S1-S8)

## Context

- `syncro-submodule` ran `git checkout -B "$branch" "origin/$branch"` on every
  detached submodule (`infrastructure/makes/repo.mk`, before this change). The
  walk is parent first: osionos was fast-forwarded, its nested
  `git submodule update --init --recursive` put `packages/osionos-ui` at its
  gitlink 23016cfa (a commit on osionos-ui `develop` only), then the walk reached
  osionos-ui and reset it to `origin/main` 0cf241b0.
- groot main CI run 39071367620 (`make all`, SKIP_SYNC=0) failed the vite build:
  "Checkbox is not exported by src/shared/ui/index.ts".
- CI clones submodules with `--depth=1` (`.github/workflows/fresh-machine.yml:160`).
  Measured on a depth-1 clone: `merge-base --is-ancestor` is false for a pin at
  main~2, true after `git fetch --unshallow`.
- `repair-detached` merged any detached HEAD into main and pushed main and
  develop, which would publish develop-only pins to main.

## Decision

- A detached submodule is never moved to a branch tip that does not contain its
  gitlink; it stays at the gitlink (`repo.mk:80-99`):
  - shallow: unshallow first; still shallow, leave it;
  - no `origin/$branch`: leave it and carry on with the next submodule;
  - `origin/$branch` does not contain HEAD: leave it.
- The already-on-a-branch path is unchanged.
- The STILL DETACHED warning names the new causes (`repo.mk:110`), still stderr,
  still exit 0.
- `repair-detached` does nothing to a clean detached HEAD that is on an origin
  branch (`repo.mk:267`); `pushes` says so instead of pointing at the repair
  (`repo.mk:305`).

## Consequences

- Tests in `scripts/tests/pinned-submodules.bats`: nested and top-level side-branch
  pins kept, main pin still fast-forwarded, depth-1 unshallowed, missing branch
  skipped, repair-detached moves no ref. Each guard fails its test when removed.
- A pin that is not on its branch is no longer moved by syncro, so `make all`
  builds the gitlink, not the branch tip.
- Known residual, out of scope: `checkout -B` still resets a local branch with
  unpushed commits when the submodule is detached.
