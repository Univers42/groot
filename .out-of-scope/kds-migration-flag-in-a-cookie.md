# Storing the KDS migration flag in a cookie is out of scope

- Decided: 2026-11-17 · by devil ([ADR 0054](../docs/adr/0054-the-kds-indexeddb-writer-reaches-develop-only-after-its-coverage-fixes-and-is-not-promoted-live-before-pagehide-survival-is-measured.md), C7 re-rule)
- Holds while: a page cannot make a cookie write durable before a later localStorage write on the same origin

## The concept

The proposal was "F-cookie", to meet ADR 0054 C7 without measuring every browser profile.
- When the `osionos.kds.idb` flag does not fit in a full localStorage, write the cookie `osionos_kds_idb_<port>=1` (400 days, `Secure`, `SameSite=Strict`).
- Read it back, then remove the legacy KDS keys.
- An origin counts as migrated when either the flag or the cookie is present, so that a later load without IndexedDB is read-only.

## Why not

- **The two stores reach the disk on different timers.** In the devil probe, a Chromium 147 profile was killed 12 s after the retirement.
  In 3 of 3 runs the localStorage removal had persisted and the cookie had not (`scratch/devil-c7/out-crash.txt`).
  That leaves no marker and no legacy text, which is the state `.out-of-scope/legacy-kds-removal-before-the-migration-flag.md` rejects because it loses an unpushed migrated edit.
- **It cannot run in dev or be tested in WebKit.** A `Secure` cookie is not stored on a non-loopback http origin, and WebKit 26.4 does not store it even on 127.0.0.1 (`out-scope.txt`).
- **Cookies ignore the port** (`out-scope.txt`), so the name has to carry the port.
- **Blocking cookies in the browser also blocks localStorage and IndexedDB** in Firefox and in Chromium (`out-blocked.txt`). The case it was meant to cover barely exists.
- **The need is already met inside localStorage.** Overwriting the legacy state key with a 20-character tombstone is a shrinking write, which a full origin accepts on Chromium 147, Firefox 148 and WebKit 26.4 (`out-s1.txt`).
  It is one write in one store, so no ordering across stores is involved.
- What would have to change: either some browser that loads osionos refuses a shrinking localStorage write, which the tombstone's own test C7-short-state shape would show as a kept legacy pair; or a durability barrier across stores becomes available to pages.

## Prior requests

- 2026-11-17 (main session, ADR 0054 C7): F-cookie, as above. Blocked; the in-place tombstone was ruled instead.

## Reopen when

A browser that loads osionos is measured refusing a shrinking localStorage write on a full origin. Then decide again, from scratch, where the marker lives. A cookie whose removal waits until the cookie is known to be on disk would be one candidate.
