# Moving the asset library and the message histories to IndexedDB is out of scope

- Decided: 2026-11-17 · by devil ([ADR 0056](../docs/adr/0056-the-localstorage-page-cache-rotates-whole-workspace-keys-under-a-ceiling-and-never-leaves-a-durable-write-less-room-than-today.md))
- Holds while: `osionos:account-asset-library` and the message histories stay under 250,000 characters each on a measured profile

## The concept

These are units L3b and L3c of the localStorage budget plan. Move the base64 asset library
(`osionos:account-asset-library`) and the message histories (`osionos.chat.v1`,
`osionos:agent-conversations`, `osionos:realtime-messages`) out of localStorage, with a migration
under the P1 rules.

## Why not

- Measured on the live Firefox profile (2026-11-17, `ff-ls-breakdown.py`):
  - the asset library is 9,692 characters;
  - `osionos.chat.v1` is 123,773 characters.
- Together that is under 3 % of the 5,242,880-character quota. A migration costs a flag, a dual read
  and a never-delete-on-a-stale-read rule (ADR 0051), and would buy nothing measurable.
- What these stores do need is visibility when a write is refused. That is L2 condition A5 in ADR 0056, not a move.

## Prior requests

- 2026-11-17 (localStorage budget plan, L3b and L3c).

## Reopen when

A measured profile (the L5 self-report) shows either family above 250,000 characters (about 5 % of the
quota). Re-decide then, starting from that number.
