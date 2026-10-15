# 0001. Republish groot's prod tree behind a read-only push guard

- Status: accepted (pull check and push guard shipped; the republish waits on
  the operator)
- Date: 2026-10-15
- Deciders: devil (risk rulings of 2026-10-15); the operator who runs the
  republish lives with it

## Context

- The newest univers42/groot/prod tree (key epoch 2, revision 2) is the
  checkout pushed again under `secrets/`. Its SHA256SUMS sits at
  `secrets/secrets/SHA256SUMS` and lists all 13 dumps while the tree holds
  three; `secrets/SHA256SUMS` is absent (`42ctl env files --env prod`).
- `make vault42-pull-everything` stopped with "secrets/SHA256SUMS: absent, the
  required dumps cannot be verified" on a checkout that held every dump.
- `env push` publishes only what is on disk and rebuilds the private manifest
  from disk (42ctl v0.1.16 `src/cmd/scope_tree.rs:150`,
  `src/cmd/scope_private.rs:137`). A dump missing locally drops out of the
  newest tree: that is how 10 prod dumps fell out of reach.
- The scanner reads no `.gitignore`, takes every file under any `secrets/`
  directory and skips symlinks (`src/core/project.rs:266-310`). A pulled copy of
  the checkout parked under `./secrets` is published at `secrets/<path>`.
- `env push` creates `.42ctl/project.json` at the checkout root
  (`src/core/project.rs:44-63`). `root_of` roots a pull at the nearest marker no
  higher than the first ancestor holding a `.git` (`src/core/project.rs:75-84`),
  so a stage inside the checkout is bypassed, and a `.git` plus a marker planted
  above a stage on a world-writable `/goinfre` redirects the pull there.
- `./secrets` holds the oldest of three backup runs: postgres-all.sql.gz is
  3,090,285 B there and 4,089,124 B in epoch 1 revision 10.
- Unknown when this was written: who pushed revision 2-2. It lists as SHARED
  paths the current wrappers mark private, so it did not go through them.

## Decision

- `make vault42-pull-everything` proves the dumps against the SHA256SUMS the
  pull delivered: `secrets/SHA256SUMS`, else the unique shallowest one under
  `secrets/`; two at one depth are refused. Every ENGINE_SEEDS dump in
  `./secrets` must match it and `./secrets/SHA256SUMS`, which the restore
  checks. A dump the tree lacks at `secrets/` whose bytes match is a warning
  naming the republish; absent, unlisted or different fails
  (`scripts/lib/vault42-pull-verify.sh`).
- The pull is staged in a 0700 directory beside the checkout that holds its own
  `.git`, so 42ctl cannot root the pull above it (`make_work`).
- `make vault42-team-push` and `make vault42-push-all` run
  `scripts/vault42-push-guard.sh` first. It is read-only. It refuses a dump that
  is absent, unlisted, different or a symlink, an empty or symlinked
  SHA256SUMS, an entry of `./secrets` that twins a checkout-root entry, and a
  `./.vault42` holding a file, and prints the one command that moves the
  offenders into a fresh 0700 directory beside the checkout.
- A shared `make vault42-push-all` is the team push: `*.bak` and
  `.env.grobase-remote` stay private.
- A human republishes the tree, from a checkout with the mirror moved out, with
  `CTL_USER=0:0 make vault42-team-push` on rootless docker. Agents never push.

## Alternatives considered

- **Republish without a guard**: any teammate holding the mirror re-shifts the
  tree on the next push, because the scanner takes every file under `secrets/`.
- **Refuse to install a shifted tree**: the 23 entries the tree holds at their
  real paths stay unusable until the republish.
- **Republish epoch 1 revision 10 through the `--at` patch**: it publishes a
  SHA256SUMS from an older key epoch as the trust anchor.
- **Refuse a run whose stage has a `.git` above it**: checked once at start, it
  trusts the ancestors for the minutes the run waits at the unlock prompt.

## Consequences

- Verdicts (devil, 2026-10-15): the pull check, the push guard and the
  republish were each PROCEED-WITH-CONDITIONS; landing the code was
  PROCEED-WITH-CONDITIONS once the stage root was pinned.
- The quality condition was amended: `devil quality` exits 1 on main
  (8 gates fail repo-wide), so the gate is diff-scoped. Changed shell files pass
  `shellcheck -x`; added ones pass `shfmt -d -i 2`, modified ones `shfmt -d` in
  their own style; added Markdown passes markdownlint; the branch's failing
  gates are a subset of main's; only the full-suite tests already failing on
  main fail.
- The operator owns the republish. Each of these stops it if unresolved: which
  backup run to publish (the one in `./secrets` is the oldest, or seed from a
  current stack first); every entry of the private listing exists on disk,
  since a private entry missing at push time becomes unreachable; the 42ctl
  image prints 0.1.15 or 0.1.16.
- After the republish: the receipt and the shared listing match the expected
  counts (45 shared, 11 private, from a simulation of the scanner, not a
  measurement), and `make vault42-pull-everything` exits 0 with no shifted-tree
  warning and writes nothing.
- Not covered: `apps/grobase/scripts/vault/ctl-env.sh` run directly,
  `scripts/vault42-ctl.sh env push` and a native `42ctl env push` bypass the
  guard. A dump `./secrets/SHA256SUMS` omits that is not an ENGINE_SEEDS dump
  can still drop out.
- The republish does not repair history: old revisions keep the credentials
  they shared. Only rotating them ends that exposure, a human decision.
- Teammates must update groot and move any `./secrets/{apps,secrets,.env*}`
  mirror aside before their next push; the guard refuses until they do.
