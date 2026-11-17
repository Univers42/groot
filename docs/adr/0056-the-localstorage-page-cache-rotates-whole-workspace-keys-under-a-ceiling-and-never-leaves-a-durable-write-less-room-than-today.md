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
  - L1a landing, 2026-11-17 (section at the end), on `feat/page-cache-rotation` 4ebe37b74:
    - develop is PROCEED-WITH-CONDITIONS LL1 to LL7;
    - live after P1 is PROCEED-WITH-CONDITIONS LL8 to LL11;
    - LL12 follows the switch;
    - L5 as built is PROCEED for develop.
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
- **LB5. Room parity.** A refused durable write evicts in LB4 order until it fits. If it still does not fit, every candidate is removed, which is exactly today's end state (P3a and P3b). ADR 0054 C7 (at least 64 characters free after eviction) and ADR 0055 J-C5 then keep their meaning. Every candidate here includes any key L1a itself writes, such as its index. The P3a fixture passes under L1a only with this tab's active workspace declared; the L1a landing section corrects this sentence (LL1, LL2).
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

## Landing ruling, 2026-11-17: S1–S3 and A1–A4 (osionos `fix/auth-storage-full`)

The commits are `d5ec93204` (S1–S3) and `30ea874d3` (A1–A4), on top of `fc0d7b408`. They change `useUserStore.ts` and `sessionRefresh.ts` and add four test files.

**Evidence.** Probes are in `/mnt/storage/dlesieur/scratch/devil-auth-sf/` (`run.sh head|base|mainpatch`).
- **Branch head:** the 9 auth canvas files, DS1–DS4 and the builder's stall probe pass 105/105 (`out-head.txt`).
- **Pre-fix base `fc0d7b408`:** DB1 passes 1/1 (`out-base.txt`). It is a characterisation test: it asserts the observed pre-fix outcome (both ticks throw `QuotaExceededError`, `first` is sent twice, no notice, the session stays in memory).
- **`origin/main` (4b6e8fdf2) plus `git diff fc0d7b408 30ea874d3`:**
  - the patch applies cleanly, and 104/104 pass (`out-mainpatch.txt`);
  - the two touched files, `pnpm-lock.yaml`, `package.json` and all 8 submodule gitlinks are identical between `origin/main` and `fc0d7b408`;
  - `origin/main` does not contain P1 (`38c38cf36`).
- **The builder's reported gates match the logs:**
  - typecheck rc 0, lint rc 0, canvas 5645/5645;
  - auth e2e: 25 passed and 1 skipped, plus `sign-out-everywhere` 1 passed;
  - six mutants red.
- **`gates_rc=1` is not a gate failure.** It is the last `grep "^not ok"` in `gates.sh` finding nothing under `pipefail`.

**Corrections to this ADR.**
- **F4 as written is wrong.** DB1 shows the real pre-fix outcome when the record write is refused:
  - the next tick resends the rotated-out token, and the bridge revokes the whole family;
  - the local sign-out then throws on the same refused record write (`threw:QuotaExceededError` twice);
  - so the tab keeps a dead session with no notice, and resends the reused token on every tick.

  Live behaves this way today.
- **A3 as written was incomplete.** "The next run adopts it with one `rotate` call" holds for the run right after. It says nothing about a published pair whose own access token is due, which is the stall below.

**Rulings on the findings.**

| # | Finding | Ruling |
|---|---|---|
| 1 | **Stall.** The record is refused and the result is published, so every later run adopts the same pair and never rotates. DS1: `["refreshed","adopted","adopted","adopted"]`, one rotate call. | **Registered residual, not a landing gate.** <br>• Strictly better than live in the same state: the session lasts until the published access token expires (1 h at the default `OSIONOS_APP_SESSION_TTL_SECONDS`), the A4 notice is shown, and the family stays alive on the server. <br>• It heals itself once the record fits (DS2: `[…,"adopted","refreshed"]`, the head `n1` is rotated, never `first`). <br>• If the result is refused too, it falls back to a notified sign-out (DS3). <br>• **The coordinator's candidate (`prev` = the disk token) alone is a no-op.** In DS1 `publishedPrev` already equals the disk token `osb_rt.u1-first.sig`. The fix is ST1 below, and it needs its own ruling. |
| 2 | The `pagehide` listener now reached from the user store, and the test's no-op `addEventListener` | **Accepted.** <br>• No runtime change in the browser: `App.tsx` and 18 other modules already import `pageStore.helpers`. <br>• `pageStore.helpers.ts:367` is the only module-level `pagehide` registration. The others are registered at runtime: `knownDatabaseUnload.ts:30` inside a function, `syncLedgerPersist.ts:221` lazily, `usePageSync.ts:269` in an effect. So the order of the listeners is unchanged. <br>• No import cycle: `pageAccess` imports only types plus `share/types` and `appMeta`, which import nothing at runtime. <br>• The fake-window edit is a fix to the test environment. |
| 3 | Context, workspaces and personas writes refused after making room are dropped without a notice; the lease write uses a bare `setItem` | **Residual under A5, which stays open.** <br>• Before the fix these writes threw, and the sign-in or sign-out aborted. <br>• In bridge mode the record also carries the persona and the workspace lists, and its refusal raises the A4 notice. <br>• The lease: condition AL1. |
| 4 | A refused record rewrite at sign-out | **Condition LV1 before live.** <br>• DS4: with the rewrite refused, the account's refresh token stays on disk, the tab shows the user as signed out, a reload restores the session, and the notice wrongly says "Browser storage is full / can't be kept". <br>• A shrinking write should never hit the quota in Firefox or Chromium (they account by delta), but that is browser-source knowledge and was not measured here. S2 must hold either way. |
| 5 | The sticky notice is never withdrawn | **Accepted residual.** <br>• It over-warns, which is the safe direction. <br>• It comes back after a dismissal only when a write is refused again: once per rotation, or once per tick during the stall. |
| 6 | Tab B keeps its session in memory after tab A signs out | **Existed before the fix; registered.** <br>• After the fix, B writes neither a result nor a record (S3 test; `savePersistedWorkspaces` skips records that are absent, `useUserStore.ts:132`), so S2 holds on disk. <br>• Dropping B's session when the record disappears is a separate security unit. |
| 7 | `useUserStore.ts` is 908 lines (it was 890) | **Existing violation, registered.** <br>• The extraction is a separate refactor commit. It is never mixed into this fix. |
| — | Found while reading: when `unchanged()` is false (a step-up mid-flight), the result is still published, and other tabs adopt the old family's pair. | **Existed before the fix** (`writeJson` was unconditional). Registered. |

**Develop: PROCEED-WITH-CONDITIONS.**
- **AL1. The lease write.** Either it goes through the injected writer, with a test, or the `sessionRefresh.ts` header Caveat gains one line.
  - The line says that on a full origin the lease write is dropped, so the both-rotate window grows from milliseconds to one refresh round trip (at most `REFRESH_TIMEOUT_MS`, 8 s).
  - It also says the failure is closed: a reuse sign-out.
  - `devil caveat --strict` passes.
- **AL2. No probe or devil file is committed.** `git diff --stat fc0d7b408..<head>` lists only the 7 files above, plus AL1 and LV1 if they land here.
- **AL3. Gates on the final head.** Typecheck rc 0, lint rc 0, the full canvas suite, and the 9 auth files. The evidence cites the rc line of each gate, not `gates_rc`. If `origin/develop` has moved past `fc0d7b408`, they are re-run after the merge.

**Live without P1: PROCEED-WITH-CONDITIONS.** The build is a cherry-pick onto the live base. Promoting develop is not allowed, because P1 is still suspended on C7.
- **LV1. DS4 inverted.** With the bridge-session key refused, `dropLocalSession('u1')` leaves no key that holds u1's refresh token. Every notice shown is true.
  - One fail-safe way: remove the record key when its rewrite is refused on a sign-out. The other accounts then become memory-only, and the A4 notice becomes true for them.
- **LV2. The live base is read at promotion time.** It is the source commit recorded on the running web image, not taken from memory.
  - The build is that commit plus `d5ec93204`, `30ea874d3`, AL1 and LV1, and nothing else.
  - `git log <base>..<build>` shows no P1 commit.
  - `git diff --stat` touches only `useUserStore.ts`, `sessionRefresh.ts` and `tests/canvas/`.
  - If the base is not `4b6e8fdf2`, the apply check and the 9 auth files are re-run on it.
- **LV3. Full gates on that build tree.**
  - Typecheck, lint and the full canvas suite.
  - Auth e2e: bridge-stub 25 passed with only the known skip at `rememberComputer.spec.mjs:30`, plus `sign-out-everywhere`.
  - The production image build, run locally, because those CI jobs run only on develop and main.
- **LV4. Before the switch.** The build commit is reachable on `origin`. A rollback tag of the current live web image is recorded. The deploy runs under the standing go.
- **LV5. After the switch.**
  - The served bundle contains `Your sign-in can't be kept across a reload`.
  - It lacks a string unique to the P1 diff, chosen by the builder before the switch.
- **LV6. Before develop reaches main.** `git merge-tree` shows that the cherry-picks and the originals merge without conflict.

**ST1, the stall fix, a follow-up that needs its own ruling.** It touches the auth chain and concurrency.
- **The property to build.** The head of the chain is the published pair when its `prev` equals the refresh token on disk; otherwise it is the disk token.
  - `currentTokens` and `readTokens` return the head, so the `unchanged()` guard compares heads.
  - A due head is rotated.
  - A rotation from a head that is not the disk token publishes `prev` = the disk token.
- **The tests:**
  - in the DS1 setup over 4 due ticks, the bridge receives 4 distinct refresh tokens, each exactly once;
  - a second store on the same storage, between two ticks, adopts and does not rotate;
  - a reload, as a fresh module on the same storage, resolves to the latest published pair;
  - DS2 and DS3 still pass.

## Landing re-check, 2026-11-17: LV1 `89ef8ab25` and AL1 `3267dbdd9`, and the live cherry-pick

This section covers `git diff 30ea874d3..3267dbdd9 -- src/`. Develop is at `3267dbdd9`. The gate logs under `/mnt/storage/dlesieur/scratch/auth-sf/logs/c4-*` show:
- typecheck rc 0 and lint rc 0;
- canvas 5649/5649;
- the 9 auth files 104/104;
- bridge-stub rc 0 and `sign-out-everywhere` rc 0.

`c4-devil-ds4.log` shows 3/4. The one failure is the old DS4, which asserted the state before LV1. That failure is expected.

**Evidence.** Everything is in `/mnt/storage/dlesieur/scratch/devil-auth-sf/`.
- **`run.sh head`** (`3267dbdd9`) **and `run.sh cherry`** (the live candidate below): the 9 auth files plus my probes pass **111/111** on each tree.
- **DS4, inverted by LV1:** `{"recordStays":false,"keysHoldingU1":[],"u2OnDisk":false,"u2Live":true,"titles":["Browser storage is full"]}`.
- **DQ1:** with the fake origin exactly full, a sign-out with u2 remaining rewrites the smaller map, and the fallback never runs: `{"bridgeRemovals":0,"u2OnDisk":"osb_rt.u2-first.sig"}`.
- **DQ2a, the LV1 double failure:**
  `{"keyOnDisk":false,"outA":"refreshed","published":null,"outC":"signed_out","calls":[T1,T1],"signedOut":["refresh_token_reused"]}`.
  Tab A rotates u2 and publishes nothing. Tab C, a second tab of u2, resends the replaced token, and the server revokes the family.
- **DQ2b, the control (the A4 state, record kept):** `{"outA":"refreshed","publishedPrev":T1,"outC":"adopted","calls":[T1]}`.
- **M1, `browser/quota.mjs`** (Playwright 1.59.1, Docker, `--network none`). The origin is filled to 5,242,877 characters, so a new 16-character key is refused.

  | Write on the full origin | Chromium 147 | Firefox 148 | WebKit 26.4 |
  |---|---|---|---|
  | same size, other text | ok | ok | ok |
  | shrink by 1 | ok | ok | ok |
  | shrink to half | ok | ok | ok |
  | remove, then a smaller set | ok | ok | ok |
  | grow past the original | `QuotaExceededError` | `QuotaExceededError` | `QuotaExceededError` |

  None of the three refuses a write that does not grow on quota grounds. My previous ruling marked this as unmeasured; it is now measured.
- **M2:** tab A runs `removeItem` then `setItem` 3,000 times while tab B polls the key.

  | Engine | Reads of the gap | Polls | `null` storage events |
  |---|---|---|---|
  | Chromium | 3,820 | 4.86 M | 3,000 |
  | WebKit | 215 | 0.95 M | 3,000 |
  | Firefox | 0 | 0.54 M | 3,000 |

  So another tab can read the key as absent between the two calls in Chromium and WebKit.
- **The live candidate** was built in a shared scratch clone: `4b6e8fdf2` plus `d5ec93204`, `30ea874d3`, `89ef8ab25` and `3267dbdd9`.
  - The cherry-pick has rc 0. The tree is `96644623b4495e21c3bd2ebff15c991ca1c57bbc`.
  - It changes 7 files: `sessionRefresh.ts`, `useUserStore.ts` and 5 under `tests/canvas/`.
  - Both source files are byte-identical to develop `3267dbdd9`.
  - P1 `38c38cf36` is not an ancestor.
  - The submodule gitlinks are identical to `3267dbdd9`.
  - `git merge-tree --write-tree <candidate> 3267dbdd9` has rc 0.
- **A trap: the shared osionos repo's local `main` is `32bd04385`** (2026-10-19). It and `origin/main` are not ancestors of each other: there are 1,083 commits on one side and 3,652 on the other.

| # | Question | Ruling |
|---|---|---|
| 1 | LV1 as built (`useUserStore.ts:226-240`), and whether remove-then-rewrite opens a new path | **LV1 is met** (DS4 inverted, and the builder's three LV1 tests). <br>• **The gap is real** (M2, Chromium and WebKit). Another tab whose refresh of a remaining account lands in the gap gets `adopt` returning false, so nothing is published and `persistRefreshed` skips. A's rewrite then puts the old token back, `adoptStoredTokens` copies it into B's memory, and the next due refresh resends it: the family is revoked. <br>• **Losing another tab's write** after A read the map is the old last-writer-wins problem every map rewrite already has (`:128-143`, `:221-223`). LV1 does not widen it: the read and both writes run in one synchronous task. <br>• **The branch runs only if a strictly smaller write is refused.** No measured engine does that on quota (M1), and DQ1 never reaches it, so the path needs a refusal that has nothing to do with quota. **Registered residual R-LV1a**, and condition LC1. Not a live gate. |
| 2 | After the LV1 double failure, the remaining account is in memory only, and its refresh is not published | **A distinct loss path, not the A4 residual.** <br>• In A4 the record stays with the old token, so `adopt` reports it kept, the result is published, and the second tab adopts without sending anything (DQ2b). <br>• Here the record is gone, so S3 reads the state as a sign-out, publishes nothing, and the second tab resends the replaced token (DQ2a). <br>• It is reachable only through the LV1 fallback. That needs the strictly smaller rewrite refused (unreachable on quota, M1), and then the rewrite of a value smaller than the one just removed refused as well. <br>• When it does happen, it fails closed: the account is signed out with a notice. No token is left on disk and no data is lost. <br>• **Registered residual R-LV1b. No live condition.** <br>• Re-rule if a sign-out rewrite can ever grow the map, or if the S3 check changes. The fix would be a sign-out marker for S3 instead of "the record is absent". |
| 3 | AL1: the lease goes through `writeShared` and `setItemEvictingPageCaches` | **Acceptable now.** <br>• The room-maker's first eviction switches the page cache off for the session (`pageStore.helpers.ts:286-291`, `:336`). The lease therefore adds at most the single eviction per session that the A3 result write already causes on a full origin. <br>• **Under L1a the lease is not exempt from LB7.** It is a fresh key every run (`releaseLease` removes it, `sessionRefresh.ts:217-219`). Exempting it would make every hourly refresh on a full origin evict a workspace key again and spend up to three `setItem` attempts (LB6). <br>• **Condition LB17** is added to L1a. |

**New conditions.**
- **LC1. Develop follow-up, not a live gate.** The comment on the LV1 fallback (`useUserStore.ts:236-237`) becomes a `Caveat:`. It names:
  - the non-atomic pair: the gap is visible in Chromium and WebKit (M2);
  - the consequence for another account, whose refresh is unpublished and gets resent (DQ2a);
  - that the branch needs a refusal of a smaller write, which no measured engine makes on quota (M1).

  Done when the comment says this and the repo's caveat check passes.
- **LB17. Added to L1a.** The lease and the result use the LB14 room-maker and count for LB7.
  - Test: on a full origin with several workspace keys, four refresh runs evict only during the first.

**LV2–LV6 for this plan.**
- **LV1 and AL1 to AL3: met.**
- **LV2, amended.**
  - The base is `origin/main` `4b6e8fdf2`, matching the running image `main-4b6e8fdf-site`. It is never the local `main` ref.
  - The result's tree must equal `96644623b4495e21c3bd2ebff15c991ca1c57bbc`. If it does not, stop and diff.
  - Right before the push:
    - `git ls-remote origin refs/heads/main` still reads `4b6e8fdf2`;
    - `git merge-base --is-ancestor 4b6e8fdf2 <candidate>` is true;
    - the push is `git push origin <candidate>:refs/heads/main`, without `--force`.
- **LV3. Unchanged.** My 111/111 on the candidate does not replace the full gates, the e2e runs or the production image build.
- **LV4, amended.** The order is: push, then main CI green, then `STAGE=build`, then `STAGE=swap`.
  - `deploy-web-main.sh:24-25` refuses to build unless `origin/main` equals `NEW`.
  - Right before the swap, `docker image inspect track-binocle/osionos-web:main-4b6e8fdf-site` succeeds. `write_rollback` (`:49-60`) depends on that image.
- **LV5, amended.** On the served bundle, the grep is for `be kept across a reload`, without the apostrophe, because the minifier may re-quote the string. The bundle must also show `main-<new8>`, and it must lack the P1 string chosen before the switch.
- **LV6.** It passes on my candidate. Re-run it with the real cherry-picks against `origin/develop` before develop reaches main.

## L1a landing, 2026-11-17

This section rules on landing L1a and L5 as built. The subject is osionos worktree `osionos-l1a`, branch `feat/page-cache-rotation`, HEAD `4ebe37b74b3b2ff6447dbc661ea671645024919e` on base `fcff64db5`. The branch is to be rebased onto develop `63c376994` and onto `fix/kds-retire-tombstone` (ADR 0054 C7).

The worktree was read only. Every probe ran on a copy, in docker: `/mnt/storage/dlesieur/scratch/devil-l1a/run.sh`, with image `osionos-p1-fix-playground:latest`. Paths are relative to the osionos repo unless they start with `/`.

### The plan's best case

- One module, `src/store/page-cache/`, replaces `evictPageCaches`, `writeWorkspaceCache` and the session switch-off. It has 7 files; the largest is 109 lines.
- `pageStore.helpers.ts` goes from 914 to 853 lines.
- The gates are green: typecheck rc 0, lint rc 0, and the canvas suite at 5,739/5,739 (`/mnt/storage/dlesieur/scratch/l1a/logs/head-eng-*.log`).
- 26 mutants are killed, at least one per condition: LB1 to LB17, R1 and L5 (`…/logs/mutants/summary.log` and `summary2.log`).
- The node bench ran 5 times per side (`…/logs/bench-before-{1..5}` and `bench-after-perf-{1..5}`):

  | Case | Base `fcff64db5` | HEAD |
  |---|---|---|
  | `savePagesCache` enqueue | 4.4 ns | 4.4 ns |
  | 8k flush, median | 1.50–1.53 ms | 1.51–1.57 ms |
  | 8k flush, p95 | 2.07–2.16 ms | 2.13–2.23 ms |
  | Boot load, median | 3.04–3.07 ms | 3.07–3.11 ms |
  | Boot load, p95 | 3.54–3.74 ms | 3.59–3.70 ms |
  | 10k flush | a write | a skip (1,087,330 is over the ceiling) |

### What the probes found

| Probe | HEAD `4ebe37b74` | Base `fcff64db5` |
|---|---|---|
| **Q1** (`probes/devil-l1a-room.test.ts:49`). Two caches are written through `persistWorkspaceCaches`, the quota is set to the space used, and a journal is written that fits exactly once every cache is gone. | **FAIL.** The index `osio:page-cache-index.v1` (77 characters) stays through both attempts. Result: `stored=false attempts=2`, with only the durable keys left. | SKIP, since base has no index. |
| **Q2** (`:65`). Five caches, then three durable writes of 1,500 characters each on a full origin. | `results=[true,true,true] attempts=[2,2,2] cachesLeft=2 free=1816` | `attempts=[2,1,1] cachesLeft=0 free=6143` |
| **S1** (`probes/devil-l1a-stored-length.test.ts:16`). `storedLength` against the per-character rule, on 20,000 random strings with boundary and surrogate code units. | Passes. | Not applicable. |
| **S2** (`:38`). 869,455 characters, best of 5 batches of 20. | Latin-1 only: 0.000 ms. One wide character: 1.292 ms. One icon per 100 characters: 1.305 ms. A global-regex count of the same text: 0.261 ms and 0.709 ms. | Not applicable. |
| **P3a** (the devil-ls probe, with no active workspace declared). | Fails: `ws-other` is kept. | Passes. |
| **P3b** | Passes. | Passes. |

The logs are `/mnt/storage/dlesieur/scratch/devil-l1a/out/head-probes.log` and `out/base-probes.log`. The base arm ran on `/mnt/storage/dlesieur/scratch/l1a/devil-base`, a tree identical to `fcff64db5`.

### Conflict 1: LB5's "until it fits" against P3a

- **LB5's targeted eviction is the requirement.** P3a's assertion that `ws-other` is gone described today's evict-everything behaviour, not the rule.
  - My sentence in LB5, "The P3a fixture passes unchanged under L1a", was wrong. It holds only when this tab's active workspace is declared, which is the builder's variant (`tests/canvas/page-cache-wiring.test.ts:118-127`).
  - With no declared workspace and no index, LB4 falls back to storage order. `ws-active` was seeded first and is large enough on its own, so the write fits and `ws-other` stays. That is "until it fits".
  - This case only arises before `trackActiveWorkspace` has fired, in early boot (the lease, the outbox ledger). There, no key fares worse than under today's evict-all, so storage order is accepted.
- **The defect is elsewhere: the last attempt does not see today's end state (Q1).**
  - L1a adds one key outside the family, the usage index. `makeRoomAndRetry` (`src/store/page-cache/roomMaker.ts:79-91`) never removes it before an attempt. `keepRoomForSession` rewrites it afterwards (`:108`).
  - The last attempt is also skipped when the targeted pass already took every candidate (`:85`, `evicted.length < order.length`).
  - So a durable write that fits today once every cache is gone can be refused. In Q1 the margin is 77 characters. The index grows by about 40 characters per workspace key.
- **What each consumer needs:**
  - **LB5, room parity.** The final attempt runs with every family key gone and every key L1a itself writes gone. This is LL1.
  - **ADR 0055 J-C5.** "Refused after page-cache eviction" must keep meaning "does not fit with every cache gone". Otherwise J-C5 suppresses a pagehide push that is sent today, and the last edit before a close is lost. This needs LL1 and the full-origin cell in LL8.
  - **ADR 0054 C7.** The flag `"1"` is covered once LL1 holds. So is the in-place tombstone, which is a shrink and never refused (M1). The C7.3 ported tests must stay green, with their assertions unedited, on the rebased head (LL5).
- **The cost of targeting (Q2).** Every later durable write on a full origin pays one more refused `setItem`: `[2,2,2]` against `[2,1,1]`. This happens because L1a keeps caches that today are all gone.
  - It stays within LB6 (three attempts), and the number of cache keys and LB7 bound it.
  - It lands on the pagehide path, so LL8 measures it.

### Conflict 2: which call LB15's 1 ms binds

- **The 1 ms binds `savePagesCache()`, the synchronous enqueue at every call site.** It measures 4.4 ns on both sides, so it is met.
- **It does not bind the deferred flush.** PS1's 1 ms flush target came with PS1's shard format (26–31 ms per typing pause at 10k pages), and LB2 and LB3 forbid that format. The flush is bound by "not slower" instead.
- **"Not slower" means a pairwise median within +3 %.** That is the noise floor (`agents/benchmarker.md`). It applies to the synchronous boot load and to the flush, in ABBA order, with at least 5 rounds per side.
- **The node bench understates the flush.**
  - `tests/bench/page-cache-flush.bench.ts` uses `generatedTree`, whose titles are ASCII.
  - One character above 0xFF anywhere in an 870k value sends `storedLength` to its loop. Real pages carry such characters: the 📄 icon and the em dash in `src/widgets/database-view/model/homeDemoSeed.ts:108`, and the 📄 in `wikiSeedPages.ts:44`.
  - With one, the loop costs about 1.3 ms (S2). The realistic flush is then close to the builder's pre-fast-path median of 2.23–2.32 ms, against base's 1.50–1.53 ms. This is LL3.
- **When the measurements are due.**
  - The node bench with a realistic fixture is due before develop (LL3). It is cheap, and it decides which counter `storedLength` uses.
  - The prod-build ABBA is due before live (LL9). The costs it adds exist only in a browser: one index `setItem` per flush, a `getItem` of every cache key in the boot rotation task, and the extra refused `setItem` on a full origin. Develop is one revert away.

### The deviations

| Deviation | Ruling |
|---|---|
| L5's console global is installed in production, and no test fails if the `src/app/main.tsx:75` call is removed. | **Accepted.** <br>• It adds no capability: any same-origin script can already read `localStorage`. <br>• The report holds names and `storedLength` only (R1; the mutant `R1-value-in-report` is killed). <br>• The mutant `L5-global-not-installed` empties `installStorageReport` (`report.ts:74-75`); it does not remove the call. <br>• LB16's unknown has no other way out of the live profile, so the call is a live gate (LL10). |
| The regex fast path in `storedLength` (`roomMaker.ts:24,33`). | **Accepted as exact.** <br>• S1 covers 20,000 random strings. <br>• The builder's boundary and surrogate tests cover the edges (`tests/canvas/page-cache-room-maker.test.ts:62-77`). <br>• Two mutants are killed. <br>• The speed it was added for holds only for Latin-1 values (Conflict 2, LL3). |
| The index key's own size is not counted. | **Accepted for LB7 and LB8.** LB3 puts the index outside the family, and it is about 40 characters per workspace against a 1,000,000 ceiling. <br>**Not accepted for LB5:** see LL1. <br>A further problem: a refused index write removes the index (`usageIndex.ts:54-60`). Every later flush then measures every cache key with `getItem` until an index write succeeds. LB8 rules out that per-flush scan, and it happens precisely on a full origin. See LL4. |
| LB4's tier 1 is empty. | **Accepted.** No registered non-page cache exists, and LB1 allows tier 1 to be empty. A later non-page cache registers there. |
| LB17's test fails only under a mutant. | **Accepted.** <br>• Base meets LB17 by construction, because its first eviction switches the cache off. A test that passes on base is therefore correct. <br>• The test refills the origin between runs (`hydrateFillingTheOrigin`). It expects evictions `[["ws-a"],[],[],[]]` and lease attempts `[2,1,1,1]`. <br>• The mutant `LB17-lease-bypasses-room-maker` is killed. |
| `pageStore.helpers.ts` is 853 lines, with a re-export of `setItemEvictingPageCaches` and `PAGE_OUTBOX_KEY` (`:26-27`). | **Not a gate.** <br>• The file was 914 lines on base, and this change shrinks it. <br>• 7 source files import the re-exported names through it. 3 of them are `knownDatabase*.ts` files, which are C7.7 paths. <br>• Moving them now would re-fire C7.7 on the tombstone branch. <br>• This is the follow-up LL12 (b). |

### Verdicts

| Item | Develop | Live, after P1 |
|---|---|---|
| L1a: rotation, room-maker and index | **PROCEED-WITH-CONDITIONS** LL1 to LL7. | **PROCEED-WITH-CONDITIONS** LL8 to LL11, once the develop conditions hold. LL12 follows the switch. |
| L5: the report and its global | **PROCEED** as built (R1 is met). | **PROCEED-WITH-CONDITIONS** LL10. |
| Conflict 1 | LB5 stands. The P3a assertion is amended (LL2), and index parity is LL1. | Covered by the full-origin cell in LL8. |
| Conflict 2 | The 1 ms binds the enqueue, which meets it. The flush is bound by +3 % (LL3). | The prod-build ABBA is a live gate (LL9). |

### Conditions

Before develop:

1. **LL1. Index parity.**
   - When the targeted attempt is refused, the next attempt runs with these keys removed:
     - every remaining family candidate;
     - `osio:page-cache-index.v1`;
     - any other key L1a itself writes.
   - This attempt runs even when the targeted pass already took every candidate.
   - `keepRoomForSession` rewrites the index from what was kept, as it does now.
   - There are still at most three `setItem` attempts (LB6).
   - Done when:
     - Q1 is ported into the builder suite with its assertion unedited, and passes;
     - a mutant that keeps the index through the last attempt is killed.
2. **LL2. P3a is amended, not deleted.**
   - The case with no declared workspace stays in the builder suite. In it:
     - the write is stored;
     - every durable key is byte-identical;
     - `ws-active` is gone;
     - `ws-other` is **kept**, which proves "until it fits".
   - P3b and the declared variant (`page-cache-wiring.test.ts:118`) stay as they are.
   - LB5's sentence is corrected in this ADR.
3. **LL3. A realistic flush bench.**
   - `tests/bench/page-cache-flush.bench.ts` gains a fixture with one character above 0xFF in each page, such as the seeds' 📄 icon. The bench runs base against HEAD on it and records the median and p95.
   - If HEAD's median is more than 3 % over base, `storedLength` takes a cheaper counter that returns the same number:
     - the global-regex count measured 0.26–0.71 ms, against 1.29–1.31 ms for the loop (S2);
     - the new counter must pass S1 and the builder's LB14 tests unchanged.
   - The units do not change. These all count in `storedLength`:
     - the LB7 allowance;
     - the LB8 ceiling;
     - the J-C5 cap, because `knownDatabaseJournal.ts` imports the same function.
   - The bench comment states the realistic numbers, not only the Latin-1 ones.
4. **LL4. The refused-index state.**
   - A test pins how the flush behaves while the index write is refused.
   - The `Caveat:` in `cacheWriter.ts` names this state: each flush measures every cache key until an index write succeeds.
   - LL9 measures its cost. If it is more than 3 % over base, the measured sizes are kept in this tab's session while the index is refused.
5. **LL5. The rebase keeps C7 intact.** On the rebased head (develop `63c376994` plus `fix/kds-retire-tombstone`):
   - the C7.3 ported tests are green, with their assertions unedited;
   - the C7-common op sequence and `storage-write-guard.test.ts` are green;
   - Q1, Q2 and P3b are re-run;
   - the 26 mutants are re-run, and all are still killed.
6. **LL6. Gates.** Typecheck, lint with `--max-warnings 0` and the full canvas suite are green on the rebased head. They run under a timeout, and the logs are kept.
7. **LL7. A `Caveat:` in `usageIndex.ts`.** It says that the index sits outside LB7 and LB8, and that the room-maker removes it before its last attempt (LL1).

Before live, after P1 and after LL1 to LL7:

8. **LL8. The re-run that C7.7 requires.**
   - C7.7 fires for two reasons:
     - the definition of `setItemEvictingPageCaches` is replaced;
     - `knownDatabaseJournal.ts` changed: it now imports `storedLength`.
   - Every run uses:
     - the real app build of the exact live candidate sha;
     - local docker, with no live URL;
     - Chromium 147 and stock Firefox 158;
     - N ≥ 20 per cell.
   - Every cell must show 0 lost and 0 reverts.
   - The cells:
     - **RC9 first-session, all 28** (`/mnt/storage/dlesieur/scratch/rc9/matrix-first.sh`):
       - offline × {seed-title, seed-row, template-row, template-title, new-db};
       - online × {server-title, new-db};
       - each × {Chromium, Firefox} × {nav, close}.
     - **J-C7 close, 6** (`/mnt/storage/dlesieur/scratch/jc7/matrix.sh`): {Chromium, Firefox} × close × journal size {small, near 950k, over 1.2M}.
     - **New: full origin, 4.** {Chromium, Firefox} × {close, nav}, with the journal near the cap.
       - None of the 34 cells above fills the origin, so none of them reaches the code that changed.
       - After boot, the origin is filled to refusal with at least 3 workspace cache keys.
       - A run counts only if its log shows all three of these:
         - the journal's first `setItem` refused;
         - at least one cache key evicted and at least one kept, which proves the targeted path;
         - the last edit on the server after the reload.
       - The pagehide duration of each run is recorded.
   - Any later change to a C7.7 path or to `src/store/page-cache/` re-fires the whole set.
9. **LL9. The prod-build ABBA, run by the benchmarker.**
   - Chromium and Firefox, at least 5 rounds per side. The base is the build of the P1 live image.
   - The bounds:
     - the `savePagesCache` enqueue p95 is at most 1 ms at 10k pages;
     - the synchronous boot load's median is within +3 %;
     - the realistic flush (LL3's fixture) has its median within +3 %;
     - the flush with the index refused (LL4) has its median within +3 %;
     - the boot rotation task (`rotation.ts:72`) takes at most 50 ms on a profile whose family is over the ceiling, which is the shape of the live profile.
   - Going over any bound means stop and re-rule. A bound is never waived.
10. **LL10. L5 in the real build.**
    - A Playwright test on the real build (Chromium and Firefox, local docker) asserts:
      - `__osionosStorageReport` is a function;
      - its output lists a planted key's name and size, and not its planted value.
    - Before the switch, the served bundle contains `__osionosStorageReport`.
11. **LL11. The rollback target.**
    - The rollback image is the P1 live image (after P1, before L1a). It is never a pre-P1 image, which would reopen S1.
    - A rollback leaves `osio:page-cache-index.v1` orphaned. Base ignores it because it reads only the `osio:pages:` prefix (base `pageStore.helpers.ts:23,420`), and never removes it.
    - This is registered as R-L1a1. It costs about 40 characters per workspace.

After the switch:

12. **LL12.**
    - **(a)** Within 24 hours, the user runs `__osionosStorageReport()` once on the profile they use. Only names and sizes go into ADR 0052.
      - If the active workspace alone is at or over 1,000,000, LB9 means it is never cached and boots from the server every session.
      - In that case, LB8's ceiling is re-ruled before anything else lands on this path.
    - **(b)** A follow-up, not a gate. Once the tombstone has landed and C7.7's re-run has passed:
      - the 7 importers move to `@/store/page-cache/*`;
      - the re-export at `pageStore.helpers.ts:26-27` goes.
      
      That move re-fires C7.7, so it rides with the next re-run and is never done alone.

### Risk

| Axis | Score | Why |
|---|---|---|
| Blast radius | 4 | Every guarded durable write goes through the room-maker: the outbox, pending pages, the KDS journal, the C7 flag, the ledger and the lease. |
| Reversibility | 2 | Develop is one revert. Live rolls back to the P1 image, leaving only the orphaned index (R-L1a1). |
| Cost on failure | **4 (worst)** | A durable write refused while today's end state would fit means a lost edit at pagehide, because J-C5 drops the push. Q1 shows this on HEAD. |
| Confidence | 3 | The fake storage charges `key.length + value.length`, for ASCII only. Engine accounting, the cost of `getItem` and `setItem` in a browser, and the Chromium quota stay unmeasured until LL8 and LL9. |

**Registered residual R-L1a1:** the orphaned index after a rollback.

Q2's extra refused `setItem` per durable write on a full origin is not registered as a residual; LL8 measures it.

**Re-ruled 2026-11-17 by ADR 0060:** LL3 is FB1 (an exact counter with a flat cost) plus FB2 (four fixtures). LL4's threshold and LL9's flush bounds become 1.5 ms of median increment per non-Latin-1 flush (FB3, FB4); +3 % still binds the boot load and the Latin-1 flush.
LL8 and LL10 are unchanged. Options (a) a per-page cached size, (b) the shipped run-regex under an absolute bound and (c) an upper bound first are BLOCKED: `0060-the-page-cache-flush-counts-wide-characters-in-one-flat-pass-and-is-bound-by-1-5-ms-not-by-3-percent.md`.
