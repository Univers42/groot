# 0056. The localStorage page cache rotates whole workspace keys under a ceiling, and never leaves a durable write less room than today

- Status: accepted.
  - L1a (a whole-key LRU under a ceiling) is PROCEED-WITH-CONDITIONS LB1 to LB16.
  - L1 as worded, with a sub-key or content-first order inside a workspace, is BLOCKED.
  - L1b (cache cleanup at sign-out or account change) is BLOCKED until B1 to B3 hold.
  - L2 is PROCEED-WITH-CONDITIONS A1 to A6.
  - The refresh-result cleanup is PROCEED-WITH-CONDITIONS S1 to S3 and is moved ahead of everything.
  - L4 outbox compaction is BLOCKED.
  - L5 is PROCEED-WITH-CONDITIONS R1.
  - L3a is not ruled here.
  - L3b, L3c, L4 journal reaping and L4 pruning are rung 0.
- Date: 2026-11-17
- Deciders: devil (ruling); osionos main session and builder (live with it)

## Context

This rules on the plan `scratchpad/contracts/ls-budget-plan.md`, units L0 to L5. The user's requirement, verbatim: "the localstorage is just a buffer that load faster information like a cache redis nothing else. so we don't want it to be overloaded we need to rotate the buffer efficiently".

The code was read in osionos worktree `osionos-p1-fix` at fc0d7b408 (osionos develop), read only. Paths are relative to that repo.

**The page cache has one key per workspace, not shards.**
- The key is `osio:pages:<workspaceId>` (`src/store/pageStore.helpers.ts:22,407-409`).
- Its value is the whole page array as one JSON string (`:353-364`).
- The PS1 shard design was never built.
- Every key under the prefix except `osio:pages:outbox*` is loaded as a workspace (`:370-386,413-415`).
- The cache is loaded once, at module init, and every key is loaded, whatever account owns it (`src/store/usePageStore.ts:90`).

**Today's room-making removes everything and then switches the cache off.**
- `evictPageCaches` removes every workspace key, the active one included, and sets `pagesCacheEvicted` (`pageStore.helpers.ts:286,290-302`).
- `flushScheduledPagesCachePersist` then writes nothing for the rest of the session (`:336`).
- `setItemEvictingPageCaches` uses it for unconfirmed pages (`src/store/sync/pendingPages.ts:67-72`) and for the KDS flag (`knownDatabaseDurableCopy.ts:89`). `saveOutboxLedger` uses it as well (`src/store/sync/pageStamp.ts:39-41`).
- A cache write that is refused removes only that one key (`pageStore.helpers.ts:353-364`).
- Probe P3a shows that this guarded eviction removes the active workspace and no durable key, and that the cache stays off afterwards.
- Probe P3b shows that a guarded write which still does not fit has removed every cache anyway.

**Nothing cleans the page caches at sign-out or at an account switch.**
- `signedOutState` touches the auth keys only (`src/features/auth/model/useUserStore.ts:417-429`).
- The in-session switch empties the store, but `hydratedRef` stays true (`src/store/sync/usePageSync.ts:141`).
- The outbox forgets every ledger id that is not in the current desired set, with no network call (`usePageSync.ts:207`).
- It keeps only the pages the current account may publish (`usePageSync.ts:205`).
- `keepPendingPages([])` removes the pending key (`pendingPages.ts:67-72`).

**The outbox ledger, and why stale metadata publishes.**
- The ledger stores the stamp the server confirmed. It advances only on a confirm (`src/store/sync/pageFlush.ts:104`).
- The stamp folds in the content as `∅` when the content is not loaded (`pageStamp.ts:74-88`).
- A newer metadata-only row is refused over an unclean page (`mergeServerPages.ts:53-61`).
- A content-unloaded page publishes metadata without a `baseVersion` (`src/store/sync/pageOutbox.ts:102-108`).
- The bridge writes such a PATCH as the legacy request, with no precondition (`scripts/bridge-api.mjs:4586-4595`).
- It accepts a past `updatedAt` as is, so the row moves back in time (`bridge-api.mjs:877-883`).

**Auth writes.**
- `applyRefreshed` persists before it sets state (`useUserStore.ts:467-474`).
- The bridge-session write is not caught (`:201`). Neither are the context, workspaces and personas writes (`:104,122,165`).
- `rotateHolding` publishes the result for the other tabs only after the adopt returns (`src/features/auth/model/sessionRefresh.ts:215-216`).
- Nothing removes `osionos:refresh-result:<userId>` except a final refresh failure (`sessionRefresh.ts:220`).
- Every logout outcome except 204 signs out "this device only", so the server does not revoke the token (`src/features/auth/model/bridgeLogout.ts:41-48,83-92`).

**Durable keys the plan would have treated as caches or as safe.**
- `osio-header-templates.v1` holds the only copy of the templates of non-UUID databases (`src/features/template-designer/model/headerTemplateStore.ts:19,56-57,67-79`).
- `pageConfigStore`'s quota-safe writer drops the whole write silently when even the 0-version copy is refused (`src/shared/config/pageConfigStore.ts:258-278`).
- True caches do exist:
  - `osionos:geocode-cache` (`placeGeocode.ts:26`);
  - `osio-sb-graph-snapshot` (`graphSnapshot.ts:22`).

**Dead tabs' KDS journals do not accumulate.**
- The readiness discard removes every journal found (`knownDatabaseDurableCopy.ts:171`; `knownDatabaseJournalApply.ts:126-151`).
- Abandoned loads are the exception.

**Measured on the live Firefox 158 profile, 2026-11-17.** The coordinator ran `ff-ls-breakdown.py` and `ff-ls-shape.py`, and the devil re-ran both with `python3 -I`.

| Item | Characters |
| --- | --- |
| Origin total (93.4 %) | 4,897,982 |
| KDS legacy | 3,351,473 |
| Outbox ledger (4,064 entries) | 789,580 |
| `osionos:page-configurations` | 481,029 |
| `osionos.chat.v1` | 123,773 |
| Asset library | 9,692 |
| Page-cache keys | 0 (none on disk) |
| Free after page-cache eviction | 344,898 |
| Origin total after L0 (estimated) | about 1.55 M |
| Free after L0 (estimated) | about 3.69 M |

The quota is 5,242,879 to 5,242,880 characters, measured on Firefox, and in headless Chrome 154 on a file:// origin (PS1).

**Probes.** They are in `/mnt/storage/dlesieur/scratch/devil-ls-budget/`. Run `./run.sh tests/canvas/devil-ls-<name>.test.ts`; this runs docker with `--network none`. The result was 8/8 ok (`out-1.txt`, `out-2.txt`).
- **P1a.** Stripping a page's content inside a cached workspace makes the page unclean. The other device's newer title is refused, and the outbox PATCHes `title: "Plan"` with no content and no `baseVersion`.
- **P1b.** Control: after whole-key eviction, the newer row is taken whole and nothing publishes.
- **P1c.** An evicted workspace followed by a failed hydrate is forgotten, not deleted. An empty authoritative list wipes nothing.
- **P1d.** The same stale PATCH happens when a cache outlives its ledger entries. This is account A, then B, then A again: B's flush forgets A's ids, and A's cache stays on disk.
- **P3a and P3b.** Today's room-making, as described above.
- **P4.** A boot as account B erases account A's pending-pages key, which is the only on-disk copy of an unconfirmed edit. That draft is also loaded into B's store.
- **P5.** The adopt throws a quota error after the rotation answered. No result is published, and the next run sends the rotated-out token again.

**Unknown when this was written:**
- the size of the active workspace's cache after L0, since the profile currently holds 0 cache keys;
- Chromium's quota for the live origin: `tests/canvas/page-pending-pages.test.ts:12` records about 2.62 M characters on the live demo origin, while PS1 measured 5,242,879 on file://;
- whether A's cached pages loaded into B's store are reachable by B (P4 loads them, rendering not tested);
- the in-session A→B→A switch with an unconfirmed edit, read but not probed. It is listed as F11.

## Decision

The page cache is a cache: whole workspace keys, rotated least-recently-used first, under a soft ceiling. Safety does not come from the ceiling. It comes from two rules:
- a durable write that needs room gets at least the room today's eviction gives it;
- the cache never refills room that a durable write needed in the same session.

**L1a conditions.** These are acceptance criteria, each with a test.

- **LB1. Only registered keys are candidates.** The candidates are `osio:pages:<ws>` (as matched by `isWorkspaceCacheKey`). `osionos:geocode-cache` and `osio-sb-graph-snapshot` may also be registered, but this is not required, because their size is unmeasured.
  A test evicts down to zero and asserts that these keys are byte-identical afterwards:
  - `osio:pages:outbox` and `osio:pages:outbox:recovering`;
  - `osio:pending-pages.v1`;
  - `osionos.kds.idb`, every `osionos.kds.journal.v1.*`, and the legacy KDS key;
  - `osio-header-templates.v1`;
  - `osionos:page-configurations` and `osionos:account-asset-library`;
  - the chat, agent and realtime histories, and `osionos.liveWriteOutbox.v1`;
  - every auth key;
  - `pg:recents`.
- **LB2. The eviction unit is the whole key.** A cache value is never rewritten to a smaller one: no content strip, no page subset, no dropped fields. Evidence: P1a, with the bridge facts above.
- **LB3. No format change to `osio:pages:<ws>` values.** The LRU index lives outside the `osio:pages:` prefix.
- **LB4. Eviction order.**
  1. Registered non-page caches, oldest last-used first.
  2. Workspace keys other than this tab's active workspace, oldest first.
  3. This tab's active workspace, last.

  With a missing or corrupt index, use storage order with the active workspace last. Ties break by key order.
- **LB5. Room parity.** A refused durable write evicts in LB4 order until it fits. If it still does not fit, every candidate is removed, which is exactly today's end state (P3a and P3b). ADR 0054 C7 (at least 64 characters free after eviction) and ADR 0055 J-C5 then keep their meaning. The P3a fixture passes unchanged under L1a.
- **LB6. At most three `setItem` attempts per guarded write:** as is, after a targeted eviction sized by `storedLength`, and after evicting everything. Measured at about 2.3 M characters, one `setItem` costs 4.8 ms p50 in Chromium (ADR 0055), and this path runs at pagehide.
- **LB7. Ratchet.** Once a durable write needed room in a session, the family's total stays at or below what was left after that eviction, for the rest of the session. Today's switch-off is the special case where nothing was left.
  The plan's "never disabled" without this refills the 344,898 characters freed on the live profile. The uncaught auth writes then throw, which is F4.
  Test: after a guarded eviction, a flush of a workspace larger than the remaining allowance writes nothing.
- **LB8. Ceiling and triggers.**
  - The ceiling is 1,000,000 `storedLength` units for the whole family. It carries a Caveat: it bounds churn, it is not a safety bound, and the Chromium quota is unmeasured.
  - The triggers are:
    - (a) a refused write, under LB5;
    - (b) after a cache flush, when the total is over the ceiling;
    - (c) once at boot, after the module-init load.
  - Sizes come from the index, which is updated on this tab's writes and recomputed at boot and on a refusal. There is no per-flush scan of every cache value.
- **LB9. One workspace over the ceiling is not cached.** Its key is removed, which is today's `writeWorkspaceCache` failure path. It is never written partially. It is marked oversized, with its size, and skipped for the rest of the session. It is reported by L5, and it boots from the server, as it does today.
- **LB10. The cache's own overflow never switches it off for the session.** Only LB7 limits it.
- **LB11. Multi-tab behaviour.**
  - Removing a key never changes any tab's in-memory store. No storage listener is added for cache keys; today only `useUserStore.ts:887` listens.
  - Triggers (b) and (c) do not evict a key stamped by any tab within the last 60 s. Only (a) may, under LB5.
  - The index is last-writer-wins across tabs. Its Caveat says that ordering degrades and safety does not.
- **LB12. A stale or evicted key never reads as "deleted"** (the ADR 0051 class). L1a adds no DELETE, no archive and no ledger removal. A missing key stays absent rather than becoming `[]`. Forget-not-delete (P1c) and the empty-authoritative no-op still pass.
- **LB13. Triggers (b) and (c) never evict a workspace that holds this tab's unconfirmed pages.** Today that cache is the second copy behind P4. Trigger (a) follows LB5.
- **LB14. One home for the code.** `storedLength` and the room-maker are lifted into one named module. `evictPageCaches`' callers go through it, and the old export goes in the same change.
- **LB15. The PS1 conditions that still apply:**
  - characterization tests of today's load and save first;
  - a fake storage of 5,242,879 characters at 70 % full keeps an edit across flush, edit and reload;
  - two module instances interleaving flushes lose nothing;
  - on a storage that throws at the N-th operation, each key is old or absent, never partial;
  - the ledger is byte-identical;
  - `savePagesCache` p95 is at most 1 ms at 10k pages, and the synchronous boot load is not slower (benchmarker, prod build).
- **LB16. L5 ships with L1a.** It reports the active workspace's size after L0, which is the unknown LB8's ceiling waits on.

**L2: auth writers make room, and preferences may drop.**
- **A1.** The writes at `useUserStore.ts:104,122,165,201` and `persistRefreshed` go through the room-maker, never a bare `setItem`.
- **A2.** `applyRefreshed` sets state first and never throws.
- **A3.** The refresh result is published through the room-maker even when the persist was refused. P5 inverted: a refused persist leaves a published result, and the next run adopts it with one `rotate` call.
- **A4.** If the session record still does not fit, a sticky notice says the sign-in will not survive a reload.
- **A5.** Preference stores keep their memory state, drop the write, and show one notice per store per session. A store holding user content is not a preference: chat, agent conversations, realtime messages, the live-write outbox and page-configurations get A1 and are visible.
- **A6.** `pageConfigStore`'s last attempt goes through the room-maker and then a notice. There is no silent drop.

**The refresh-result cleanup (from L4), first in order:**
- **S1.** `signedOutState` removes `osionos:refresh-result:<userId>` and `osionos:refresh-lease:<userId>`.
- **S2.** After a "this device only" sign-out, no refresh token for that user remains in localStorage.
- **S3.** A rotation that lands after the sign-out does not write a result for a record that is gone. This is tested with the interleaving.

**L5. R1:** it reports key names and `storedLength` only, never values, because refresh tokens live in localStorage.

**Order:**
1. S1 to S3.
2. L2.
3. L0, under ADRs 0054 and 0055 (C7 and FL1 to FL3).
4. L1a with L5.
5. Measure the active workspace and the Chromium profile, then decide on L3a.
6. Fix pending-pages scoping, then L1b.

L1a may be built before L0 is live. On the live profile it changes nothing until L0 lands, because the profile holds 0 cache keys.

## Alternatives considered

- **Sub-key LRU (content bodies before metadata, or a page subset).** This was the plan's Q1 option. It loses because of P1a. The stripped page turns unclean, the other device's newer title is refused, and the outbox sends the stale title with no precondition. The bridge writes it and moves `updated_at` back in time (`bridge-api.mjs:877-883`). The two devices then diverge silently. Recorded in `.out-of-scope/page-cache-sub-key-eviction.md`.
- **The plan's L1 as worded: "never disabled", plus sign-out cleanup, plus header templates registered as a cache.**
  - "Never disabled" refills room (F7).
  - Header templates are durable (F8).
  - Cleanup at an account change removes the cache that is today the only surviving copy after P4's pending erase (F3). That is why it was split into L1b, which is BLOCKED.
- **Outbox compaction or a circular buffer (Q5).** Every ledger entry is a stamp the server already holds. Dropping one makes that page unclean: P1a and P1d's stale metadata PATCH for a content-unloaded page, and a republish storm across 4,064 pages. A shorter stamp format makes old tabs read every stamp as different. That is the C3b5 R5/R7 class. Recorded in `.out-of-scope/outbox-ledger-compaction.md`.
- **A fixed ceiling as the safety bound.** It cannot be one. No API reports the localStorage quota, the Chromium quota for this origin is unknown (2.62 M against 5.24 M), and only a refused write reports the real one. LB5 and LB7 carry the safety instead.
- **Moving the asset library and message histories to IndexedDB (L3b and L3c).** They measure 9,692 and 123,773 characters. Recorded in `.out-of-scope/asset-and-message-history-indexeddb-move.md`.

## Consequences

**Loss and security paths this ruling names.**
- **F1 (P1a).** Sub-key eviction causes a silent metadata revert. Prevented by LB2.
- **F2 (P1d).** A, then B, then A reverts the metadata of A's content-unloaded pages that another device renamed or moved meanwhile. **This exists today.** L1b (B4) closes it.
- **F3 (P4).** A boot as B erases A's pending edits, and loads A's private draft into B's store. **This exists today.**
- **F4 (P5).** A quota throw in the adopt resends the rotated-out token, which probably signs the user out. **This exists today.** Closed by A1 to A3.
- **F5.** A refresh token stays in `refresh-result` after a "this device only" sign-out. **A security issue that exists today.** Closed by S1 to S3.
- **F6 (P3b).** A guarded write that still fails has removed the active cache copy of an unconfirmed edit. **This exists today.** LB5 must not widen it.
- **F7 to F9 are opened by the plan as worded:**
  - F7: refilled room (LB7);
  - F8: header-template deletion (LB1);
  - F9: an index key under the page prefix (LB3).
- **F10.** Page-configuration settings are dropped silently. **This exists today.** Closed by A6.
- **F11 (read, not probed).** In-session A→B→A: B's flush erases the pending key. A's hydrate onto the emptied store then rewrites A's workspace cache from the server (`applyServerPages.ts`, `savePagesCache` after the merge). That cache was the last copy of A's unconfirmed edit.

**The root cause shared by F1, F2 and Q5** is a metadata-only PATCH with no precondition that the bridge accepts with a past `updatedAt`. Fixing that is a bridge contract change, a public surface, and needs its own ruling. Until it lands, any design that can make a page unclean without a user edit reverts other devices' metadata.

**Lifts.**
- **L1b is lifted when:**
  - B1: `keep()` never removes a page the current account cannot publish, or the key is per user, so that P4 inverted passes;
  - B2: an F11 probe keeps the edit;
  - B3: a test answers whether A's pages loaded at boot are reachable by B;
  - B4: then every `osio:pages:<ws>` key and `pg:recents` is dropped at sign-out and at an account change. That means all of them, not "that account's", because shared workspaces hold A's private pages and the ledger is per origin.
- **L3a (page-configurations, 481,029 characters, 31 % of the post-L0 use) needs its own plan and ruling.**
  - It is written at the roughly 1.8 s autosave and on an explicit save (`usePageActions.ts:165,194`), not at unload, so it needs no journal.
  - The last autosave before an unload may be lost in IndexedDB (I10). That loses a restore point, not the page.
  - The synchronous in-memory undo point (`usePageActions.ts:244`) must stay synchronous.
- **Rung 0, not built:**
  - L4 journal reaping, which is already done by the readiness discard;
  - L4 pruning of configurations of deleted pages and of layout keys. It is unmeasured, and deleting on an absence is the ADR 0051 class;
  - L3b and L3c.

**Who is on the hook.**
- The builder meets LB1 to LB16, A1 to A6, S1 to S3 and R1 before any merge.
- The coordinator supplies the active-workspace and Chromium measurements before the ceiling is tuned.
