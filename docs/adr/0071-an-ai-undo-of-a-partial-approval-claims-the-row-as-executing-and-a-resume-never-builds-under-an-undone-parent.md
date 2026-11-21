# 0071. An AI undo of a partial approval claims the row as `executing`, and a resume never builds under an undone parent

- Status: accepted. PROCEED-WITH-CONDITIONS Q1–Q12. Options A (new `undoing` status), B (Redis lease),
  C (advisory lock) and D (leave it filed) are BLOCKED.
- Date: 2026-11-21
- Deciders: devil (ruling); osionos-ai builder (lives with it)

## Context

This is Univers42/osionos#333, filed as U6 of ADR 0070. The facts below are from osionos develop 230dde4c5,
service `services/osionos-ai`.

- Undo checks the approval status once and never claims the row (`src/routes/approvals.ts:249`). Resume
  claims `partial → executing` (`src/approvals/repo.ts:143-155`).
- Undo leaves the approval `partial` (`src/builders/undo.ts:127-134`).
- `executePlan` stops a child only when its parent is `pending`, `failed` or `skipped`
  (`src/builders/execute.ts:204-212`). A parent in `undone` falls through to the POST, under the plan's
  fixed parent id (`execute.ts:79-82,107`).
- The bridge's `canNestUnder` does not read `archived_at` (`scripts/bridge-api.mjs:1486-1499`).
- Consequence: an undo followed by a resume creates live pages under archived parents. This needs no race:
  the requests can come one after the other.
- Under a race, a resume can also POST a child after undo's children check (`undo.ts:106`). The child is then
  either live under an archived parent, or archived by the cascade while its item says `done`.
- Undo has no wall budget (`undo.ts:93-125`). Counting the bridge alone, the worst case is 40 items
  (`planSchema.ts:73`) × 8 s (`approvals/bridge.ts:15`) = 320 s. That exceeds the 300 s after which the
  sweeper marks `executing` as `unknown` (`repo.ts:31,311`).
- With DB waits, an undo reaches 1,520 s (`db.ts:39,64`): 5 s for a connection and 5 s on the server, for
  3 statements per item.
- No user page is lost in any interleaving. Resume POSTs only plan ids, and the child check still protects
  user pages.
- The web client does not call `/undo` (0 hits in `src/`).
- Unknown when this was written: none of the interleavings has been executed. They are read from the code
  (Q9 runs them).

## Decision

1. Undo on a `partial` approval claims the row with one conditional UPDATE, `partial → executing` with
   `decided_at = now()`. In a `finally`, it restores `partial` through `recordOutcome`. A loser gets a 409
   and makes no bridge call (Q1, Q3, Q4, Q5).
2. Undo on `executed` stays unclaimed. ADR 0070 governs it (Q2).
3. Undo runs under `buildBudgetMs`, the same as a build pass, and reports the pages it did not reach (Q6).
   Config refuses a budget that could outrun the sweeper (Q7).
4. `executePlan` POSTs a child only under a parent whose status is exactly `done` (Q8).
5. Deterministic tests cover resume-held/undo, undo-held/resume and undo/undo. Revert mutants fail them.
   The service gate and the root bridge suite pass twice (Q9–Q11).

The full conditions are in the verdict at `/mnt/storage/dlesieur/scratch/osionos-333/VERDICT.md`.

## Alternatives considered

- **A. New `undoing` status: BLOCKED.**
  - It leaves the deterministic undo-then-resume case open.
  - It needs a CHECK migration, a new sweeper branch and a retention exception (`repo.ts:311,317`).
  - Clients that do not know the status show "May have been written"
    (`src/features/chat/model/approvalCard.ts:50-61,81`).
  - `executing` already gives the same exclusion.
- **B. Redis lease per approval: BLOCKED.**
  - It leaves the deterministic case open.
  - The TTL was sized as bridge timeout × item cap, and that does not bound an undo (1,520 s with DB waits),
    so the lease expires mid-undo with no fence.
  - It is a second source of truth beside a row that already has a claim.
- **C. Postgres advisory lock: BLOCKED.** It pins a pool connection (1 of 10, `db.ts:56`) across HTTP calls,
  and a session lock survives release to the pool.
- **D. Leave it filed: BLOCKED.** Its premise, that every failure is in the safe direction, is false. Pages
  appear under archived parents.

## Consequences

- During an undo of a partial approval, the card shows "Writing…", and the same call cannot be asked
  again, because the live-call index covers `executing`.
- A crash mid-undo is recovered the way a crash mid-resume is: after 5 min the sweeper sets `unknown`, and
  the approval can no longer be undone or resumed.
- A resume that loses to an undo has spent one daily build unit (C161 spends it before the claim,
  `approvals.ts:157-162`).
- A network loss of 3 × 90 s (`db.ts:46`) can still outrun the sweeper window. This was accepted, and it is
  the same for resume.
- Resume's `recordOutcome` replaces `result` and drops undo's `undone` count. Nothing renders that count.
- Open, unruled:
  - Should undo of a partial approval also cancel its pending items?
  - Should the bridge refuse to nest under an archived parent?
