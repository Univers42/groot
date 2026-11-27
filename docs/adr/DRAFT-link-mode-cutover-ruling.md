# DRAFT: link mode D reaches the production link by cherry-pick, with the heal timer stopped

- Status: draft, untracked. Ruled by devil 2026-11-24: PROCEED-WITH-CONDITIONS LC-1–LC-16.
- Full ruling: `/mnt/storage/dlesieur/scratch/link-mode/RULING-CUTOVER.md`. Parent: `DRAFT-link-mode-ruling.md`.

## Context

- `grobase-link.service` and `grobase-link-heal.service` (every 2 min) run `make link` and `scripts/grobase-link-heal.sh` from `/home/dlesieur/Documents/groot`, the main checkout (`systemctl --user cat`).
- The deploy tree's `dc.sh:9,18` also runs from there: `cd` into it, then `--env-file ./.env.local`.
- The main checkout is 3 ahead and 122 behind origin/develop 28de93fe, so it cannot fast-forward. It carries 9 dirty gitlinks and a modified `docker-compose.public.yml`.
- `feat/link-mode-d`'s 17 files are byte-identical between main HEAD 44711366 and 28de93fe (`git diff --stat` empty), and disjoint from the user's modified paths.
- In ssh mode, the branch's `publish_env` writes the publish URL and key into `.env.local` (`scripts/lib/grobase-link-target.sh:216`).
- Unknown: whether cherry-pick tolerates the dirty gitlinks. A refusal changes nothing.

## Decision

D reaches the running link by cherry-picking its 6 commits onto the main checkout's develop. This happens only after a fast-forward push to origin develop with green CI, only after osionos promotion 3 is done, only with `grobase-link-heal.timer` stopped, and only under an explicit, named exception from the user to the main-checkout rule. Rollback is `git reset --keep <pre-sha>`, guarded by HEAD == `post-sha`.

## Alternatives considered

- **Pinned side worktree + systemd override: BLOCK.** `.env.local` splits between the relay and dc.sh. The new publish keys never reach the env that recreates read, so the next recreate publishes to the :4000 that D closes.
- **Update the main checkout by 122 commits: BLOCK.** It is not a fast-forward. It changes `docker-compose.yml`, which dc.sh reads, during a live promotion.
- **Wait for the user to update: fallback.** It keeps the unpinned master and the CRS bypass.

## Consequences

- The main checkout carries 6 extra local commits. They are patch-identical to origin develop, so a later rebase drops them.
- The scripts must fix S1–S6 first: the conf snapshot, the partial code rollback, the missing pre-preflight undo, the Redis false ROLLBACK, the unpinned canary ssh, and the heal timer.
- Kill bars run at +10, +30 and +60 min. `make link-autostart` is not re-run while the drop-in is the LM-3 record.
