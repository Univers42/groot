# A KDS unload journal that skips view-settings-only differences is out of scope

- Decided: 2026-11-17 · by devil (ADR 0055, re-rule on a00b62265)
- Holds while: the pagehide push still sends live views, and the readiness still lets the stored copy push them back.

## The concept

The first-session journal grows past its 1,000,000-character cap because an inline embed writes `loadLimit` 8 into every view. The proposal: when building the journal, ignore databases that differ from their base only in view settings, so the fill no longer counts as an edit.

## Why not

- When a user's real view edit (a sort, a filter, a Limit) is made in the unload window, the pagehide push sends it, the IndexedDB commit is lost (I10: 20/20 on navigation), and the journal does not carry it. The reload then pushes the older stored view back over the server copy. That is the N2 revert the journal exists to close, for views (ADR 0055, Context; `knownDatabasePersistence.ts:97-110`).
- It treats the symptom. The fill keeps reaching the store and the server: every full-page view then shows 8 rows per page (probe L1), and an embed's cap overwrites explicit Limits on other databases (L2). The root fix F1 removes the inflation without exempting anything.
- This would change only if pagehide stopped pushing views the journal does not carry. You would notice in `knownDatabasePersistence.ts` flush: `pushLive` sends a state whose views come from somewhere other than the journal.

## Prior requests

- 2026-11-17 (osionos main session): candidate F2 in the RC9 boundary ruling.

## Reopen when

The pagehide push and the journal carry the same set of views by construction, so excluding a view from one excludes it from the other.
