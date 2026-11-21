# 0070. A concurrent AI undo releases a parent only past children its own approval already undid, never past any child of that approval

- Status: accepted. PROCEED-WITH-CONDITIONS U1–U6. "Exclude the approval's children in any status" is BLOCKED.
- Date: 2026-11-21
- Deciders: devil (ruling); osionos-ai builder (lives with it)

## Context

The osionos-ai service gate failed one run of
"two concurrent undos archive each page exactly once" (C159; expected 3 archived, got 2). The race was
already in the code before osionos `feat/more-free-ai`, which did not touch it.

- The undo claims an item with a conditional UPDATE `done → undone` (`services/osionos-ai/src/builders/items.ts:107-120`).
- In a separate statement it counts the page's live children (`undo.ts:39-47`).
- Undo A claims child C and sends its archive PATCH. Undo B checks parent P before that PATCH lands, still
  counts C as live, and releases P as kept (`KEPT_FOREIGN_CHILDREN`).
- The failure is the safe direction: a page that should be archived stays. A second undo click archives it.

## Decision

1. The children count excludes only children that are items of the same approval with status
   `undone`. It stays one SQL statement: `NOT EXISTS` over `ai_plan_items` (U1).
2. A deterministic test holds child C's PATCH open and runs the second undo meanwhile (U2).
3. A user's page G under a kept child C still keeps parent P (U3).
4. If C's held PATCH fails after P was archived, C's item is recorded `done` with the refusal, and the
   bridge cascade archives C's page (U4).
5. The service gate passes twice in a row (U5).
6. The undo-vs-resume race is filed as Univers42/osionos#333 (U6). The route checks the status once
   (`routes/approvals.ts:249`); `claimPartial` is in `approvals/repo.ts:143-155`. That race predates this change and
   is out of scope.

Built in osionos f4cbbf94a (the filter, U1–U4) and 230dde4c5 (the test split). The service gate passed three runs
in a row, 1532/1532 each (U5).

## Alternatives considered

- **Exclude the approval's children in any status: BLOCKED.** A child stays `done` when it holds a user's
  page (`undo.ts:94`). Excluding it archives the parent, and the bridge cascade then archives the user's
  grandchild. This needs no race; it happens every time.
- **Leave it.** The failure loses nothing, but the gate flakes, and a flaky gate trains people to ignore red.
- **A lock across claim and check.** This adds a transaction to the bridge round-trip for a failure that
  is already safe. The narrower filter removes the race.

## Consequences

- Any later change to undo's child filter keeps the `status = 'undone'` restriction and the grandchild test.
- Every excluded `undone` child has already passed its own children check, so the excluded subtree was
  built by the plan when the check ran.
