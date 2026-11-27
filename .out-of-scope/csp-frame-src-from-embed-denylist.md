# Building frame-src from the embed denylist is out of scope

- Decided: 2026-11-23 · by devil (osionos #342 ruling, `scratch/csp342/RULING.md` §8, E13)
- Holds while: `FIRST_PARTY_ENV_KEYS` lists what an embed block must not frame

## The concept

Reuse `FIRST_PARTY_ENV_KEYS` (`embedUrlGuard.ts:82-86,99-104`) as the list of origins the generated `frame-src` allows, so the two cannot drift.

## Why not

- The table is a denylist: origins a user-authored embed must never frame (the API, the BaaS, its console, the bridge). An allow list built from it would permit exactly the frames the guard exists to refuse.
- While `frame-src` holds `https:`, the mistake is invisible, which is how it would ship.

## Prior requests

- 2026-11-23 (design §4, #342).

## Reopen when

Never as stated. If frame-src is ever narrowed below `https:`, its allow list gets its own table, with a test that it shares no entry with the denylist.
