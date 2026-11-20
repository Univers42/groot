# Folding `coverPosition` into the page outbox stamp is out of scope

- Decided: 2026-11-19 · by devil (ADR 0065, CV6)
- Holds while: the persisted outbox ledger holds stamps written without `coverPosition`, and a metadata PATCH carries no version the bridge can refuse.

## The concept

A cover reposition alone is never published, because `pageStamp` omits `coverPosition` (`src/store/sync/pageStamp.ts`). The request: append `coverPosition` to the stamp when it is defined, so any page with a position becomes unclean and publishes.

## Why not

- The ledger is persisted (`pageStamp.ts` `saveOutboxLedger`). Any change to the stamp format makes every positioned page unclean at the next boot on every device (ADR 0064 F7).
- An unclean page republishes its local title, icon, cover and properties with no `baseVersion` (`pageOutbox.ts` `pageToPatchBody`). A stale cached copy therefore overwrites another device's newer metadata. That is the P1a class (ADR 0056).
- How many (device, page) pairs are both positioned and stale lives in browsers, and no server query bounds it. UNKNOWN = FAIL.
- ADR 0065 CV2 to CV4 fix the same defect with no format change: the drag advances `updatedAt`, and a fetch takes a position only from a newer copy.

## Prior requests

- 2026-11-19 (osionos main session): option (i) of Finding A, under ADR 0064 Phase 5.

## Reopen when

Either condition holds:

- the outbox upgrades old-format ledger entries in place, so a page whose old stamp matched stays clean;
- metadata PATCHes carry a version the bridge refuses when stale.
