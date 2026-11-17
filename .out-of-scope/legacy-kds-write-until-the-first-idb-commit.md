# Keeping the legacy synchronous KDS write until the first IndexedDB commit is out of scope

- Decided: 2026-11-17 · by devil (R8 verdict, option E; [ADR 0052](../docs/adr/0052-the-kds-indexeddb-move-still-loses-or-risks-the-edits-named-here-and-is-not-loss-free.md) R8)
- Holds while: the unload journal (ADR 0055) is the only synchronous writer for the unload window, and the KDS can reach 4.5 M characters (J-C5 measured 4,554,902 for one account).

## The concept

On a store with no IndexedDB copy, keep writing the whole KDS to localStorage synchronously on each flush, as before P1, until the first IndexedDB commit resolves.

## Why not

- It recreates the unflagged legacy pair on every new browser, which is the N1/B3 class ADR 0054 closed.
- Each flush would `setItem` up to 4.5 M characters. On a full origin the write is refused, so the edit is lost anyway, and on a fitting one it costs the full serialization per flush.
- It adds a second synchronous writer for the window the journal already carries.

## Prior requests

- 2026-11-17 (osionos develop red, R8 fix options): proposed, rejected.

## Reopen when

The journal is removed, or a measurement shows a first-session loss that neither the journal nor A2 covers and that a bounded legacy write would.
