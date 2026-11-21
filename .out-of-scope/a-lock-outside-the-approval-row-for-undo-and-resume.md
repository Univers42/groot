# A lock outside the approval row for AI undo and resume is out of scope

- Decided: 2026-11-21 · by devil (ADR 0071)
- Holds while: `ai_approvals.status` has a conditional-UPDATE claim (`claimPartial`) and a sweeper that
  recovers `executing`

## The concept

Serialize undo and resume of one AI build approval with a lock that lives outside the row. Two forms were
proposed: a Redis NX lease `ai:approval:<id>:busy` with a TTL, as in `routes/voice.ts:52`, and a Postgres
advisory lock held across the bridge calls.

## Why not

- The row already carries the claim (`approvals/repo.ts:143-155`), and the sweeper already recovers a stuck
  claim (`repo.ts:311`). A second lock is a second source of truth beside it.
- The worst-case undo is not bounded by any TTL computed from the bridge timeout × the item cap. With DB
  waits it reaches 1,520 s (`db.ts:39,64`, 40 items, 3 statements per item), so a lease expires mid-undo
  with no fence.
- An advisory lock pins one of 10 pool connections (`db.ts:56`) across HTTP calls.
- Neither lock fixes the deterministic failure, which is an undo followed by a resume
  (`execute.ts:204-212`).
- Fact that would change the answer: an operation on one approval that spans more than one service process,
  or more than one row, so that no single conditional UPDATE can express the claim.

## Prior requests

- 2026-11-21 (osionos#333 plan, option B): Redis lease, fail-closed, compare-and-delete release.

## Reopen when

An approval operation needs exclusion across something a single `ai_approvals` row update cannot claim.
For example, a batch undo of several approvals, or work handed to a second process that outlives the
request.
