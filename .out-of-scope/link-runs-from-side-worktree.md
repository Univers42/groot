# Running the production link from a side worktree is out of scope

- Decided: 2026-11-24 · by devil (link-mode cutover ruling, `scratch/link-mode/RULING-CUTOVER.md` option a)
- Holds while: `make link` writes `$REPO/.env.local` and the deploy tree's `dc.sh` reads the main checkout's `./.env.local` (`dc.sh:9,18`)

## The concept

Point `grobase-link.service` (and the heal unit) at a pinned worktree with a systemd `WorkingDirectory=` override, so new link code runs without touching the main checkout.

## Why not

- The relay's env and the recreate env split into two `.env.local` files. Link keys that `make link` rewrites, such as the ssh-mode publish URL of `grobase-link-target.sh:216`, never reach the env dc.sh recreates from. The next recreate then publishes to a relay port that is closed.
- The heal unit needs a second override, and LM-3's journal check hard-codes the main path.
- The compose `working_dir` label flips between trees, and no bats test covers a link run from a worktree.

## Prior requests

- 2026-11-24 (link-mode D cutover, option a).

## Reopen when

`make link` takes its env-file path from one configured location that dc.sh shares, or dc.sh moves out of the main checkout.
