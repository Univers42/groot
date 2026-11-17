# A shorter KDS commit debounce (eager commit) as part of the unload journal is out of scope

- Decided: 2026-11-17 · by devil ([ADR 0055](../docs/adr/0055-the-kds-unload-journal-is-per-tab-keyed-by-every-base-it-may-land-on-and-never-regresses-an-acked-record.md))
- Holds while: the unload journal (J-C1 to J-C5) carries the unload window, and no benchmark shows that a 300 ms commit cadence costs under 3% of input latency on the 4.6 M-character state.

## The concept

Design J3 proposed shortening the KDS debounce to about 300 ms, with no idle wait before the commit, so that a commit usually starts long before the page unloads. The journal would then only cover what is left.

## Why not

- Once the journal holds every pending and resolved base (ADR 0055 J-C1), correctness no longer depends on when the last commit started. J3 buys no safety.
- It moves serialization (8–10 ms) and a commit (p50 9–17 ms) on the 4.6 M state into the typing pauses. The idle wait in `knownDatabaseFlushSchedule.ts:16-17` exists to prevent exactly that. No benchmark backs the change.
- More commits mean `pending > 0` more often, so `commitRecord` refuses more often (`knownDatabaseDurableCopy.ts:206`). The record then lags its state more often, which is T4's class.
- It widens T2's window: an edit lands while a commit is in flight.

## Prior requests

- 2026-11-17 (osionos main session, journal design J3): proposed, rejected.

## Reopen when

A benchmark against a baseline shows the 300 ms cadence costs under 3% of input latency on the 4.6 M state, and a measured loss remains that the journal does not cover.
