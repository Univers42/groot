# Leaving archived pages out of `/api/pages/all` is out of scope

- Decided: 2026-11-23 · by devil (osionos #243 ruling)
- Holds while: the client store treats "absent" and "archived" as different states, and `/all` is applied authoritatively

## The concept

60 % of the largest workspace's rows are archived (5,248 of 8,772, measured 2026-11-23). Without them, `/api/pages/all` would ship about 61 % fewer bytes and need no new protocol.

## Why not

- The store distinguishes archived from absent in three places. Trash lists archived store rows (`src/pages/trash-view/ui/TrashView.tsx:70`). The IDE answers `archived` for an archived row and treats an absent one as gone (`src/features/ide/model/inboundView.ts:61`). The tab prune reads absence as deletion (`src/widgets/workspace-grid/model/useLayoutPagePrune.ts:45`). 55 client files read `archivedAt`.
- Old clients apply `/all` authoritatively and drop every persisted id it omits (`src/store/sync/mergeServerPages.ts:119-122`). Changing the default would empty their Trash.
- An opt-in live-only list needs a "known archived" channel and an authoritative drop scoped to live pages. That makes it option C (a partial store), which needs its own ruled design.

## Prior requests

- 2026-11-23 (coordinator, #243 S0): raised as a cheaper alternative to the manifest.

## Reopen when

A design gives archived pages their own complete, authoritative channel (for example a lazy trash list with its own pulled-at stamp), and the IDE, prune and Trash consumers are moved onto it under a parity test.
