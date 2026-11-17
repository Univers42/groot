# Storing the KDS readiness seed base after the adapter projection is out of scope

- Decided: 2026-11-17 · by devil (ADR 0055, re-rule on a00b62265)
- Holds while: the projection depends on which embeds mount (`defaultLoadLimit`, `recordCap`, or none).

## The concept

The first-session journal diffs the live store against the seed base. An inline embed's fill makes all 10 seed databases differ, adding about 447,000 characters. The proposal: store the seed base already passed through `applyAdapterOptions`, so the filled views match it.

## Why not

- No one projection exists. The fill is 8, or a block's `recordCap`, or nothing for a full-page session (`knownDatabaseState.ts:424-442`). A session with no inline embed would then differ from a filled base on all 10 seed databases: the same 447,000 characters, inverted.
- It does not cover the amplification. A hydrated database has no base entry, and the fill still makes it dirty (probe L4: 683,197 characters with one 236,409-character database).
- It breaks RC2(b) and RC2(c): the stored readiness text must equal `serialize(seedSnapshot(), new Set())` exactly.
- It writes a render-time default into the durable copy, which is the bug itself.
- This would change only if the projection stopped depending on the mounting component, for example if the fill were removed and only a fixed, session-independent projection remained.

## Prior requests

- 2026-11-17 (osionos main session): candidate F3 in the RC9 boundary ruling.

## Reopen when

`applyAdapterOptions` gives the same output for every adapter option set a session can mount, so one projected base fits every session.
