# 0051. An object database is never deleted by a stale or empty read, and stays cached locally

- Status: accepted with conditions. Devil ruling: part (a) G1 PROCEED-WITH-CONDITIONS A1–A6. Part (b) S1+S2 BLOCK, lift L1–L8.
- Date: 2026-11-16
- Deciders: devil (risk ruling). The osionos web and bridge owners live with it.

## Context

Code is osionos `f0bd56c52` (live web `main-f0bd56c5`). G1 is the uncommitted diff in
`/mnt/storage/dlesieur/wt/osionos-objdb-guard`.

- Live account facts from the plan: the known-database state (KDS) is 4,646,686 chars. Its localStorage write is
  refused on every load (the quota measured 5,242,879 chars, see the `ps1-page-cache` verdict), so the
  "Browser storage is full" toast shows every time. The state holds 186 databases: 175 were pushed to the server
  and 11 are seed. The GET list is 4,266,259 bytes and takes 287 ms.
- Deletes are inferred from absence. `removed` is every baseline key missing from the state being pushed
  (`objectDatabaseBridgeSync.ts:169`). Each one becomes a hard PostgREST DELETE with no soft delete
  (`scripts/bridge-api.mjs:4838-4848`).
- No user path deletes a database. "Delete database" is `onClick: onClose`
  (`src/shared/notion-database-sys/src/components/topBar/MenuComponents.tsx:45`). So every non-empty `removed`
  in production is accidental.
- F0 is reachable. A body-less 2xx reads as `empty` (`scripts/bridge-baas-body.mjs:33-35`, its own Ponytail
  admits "the lost one reads as no rows"). The GET handler turns a non-array into `200 {databases: []}`
  (`scripts/bridge-api.mjs:4766-4773`). Hydrate then completes (`objectDatabaseBridgeSync.ts:241-248`) and the
  push deletes every baseline key the seed-only store lacks. A 204 cannot trigger it, because the client
  throws (`packages/http-gate/src/client.ts:77`).
- G1 restricts deletes to databases this tab's pushed states have held (`heldDatabaseIds`). G1 misses one case,
  the stale capture. The flush captures `pendingState` (`knownDatabaseState.ts:189`) and pushes it in a later
  task (`:203-205`). If that capture predates hydrate, it runs after hydrate filled the held set, and every
  hydrated database is deleted, even with a healthy list. The harness `stale-capture.test.ts` (devil
  scratchpad, local docker) printed `DELETEs: ["db-deals","db-leads"]` against the G1 diff.
- The union base is the side with strictly more pages (`objectDatabaseSlice.ts:122`). The definition comes
  from the base (`:126`), and the base's views win on equal ids (`:134`). The pre-hydrate placeholder has
  one starter row (`object_database.tsx:652-698`). Against a server database with 1 record, the placeholder
  is the base: the result is named "Untitled database", keeps only the title property, and its view replaces
  the server view of the same id. The result is non-pristine, so it is pushed. Against 0 records the same
  thing happens on the first edit. The bridge guard does not catch a typed placeholder
  (`scripts/bridge-object-db-guard.mjs:5-7`). Proved by the harness `placeholder-union.test.ts`.
- Hydrate never retries. `hydrationDone` is set before the call and failures are swallowed
  (`objectDatabaseBridgeSync.ts:258,263-264`). Only realtime nudges re-run it.
- The push loop loads the baseline at `:174` and saves it at `:200`. That save can overwrite a concurrent
  hydrate's removal of a database missing on the server (`:228-229`).
- Unknown when this was written:
  - how many of the 175 server databases have ≤1 record (no saved list);
  - how often the upstream answers body-less;
  - whether `b2b-backup` covers `osionos_object_databases`;
  - the G1 gates. canvas-all 5471/5471 and quality exit 0 were reported by the coordinator, not re-run by the devil.

## Decision

A remote delete is decided against the store's current state at push time, never against a captured
snapshot or an empty read. The preferred rule removes the absence-inferred DELETE loop outright until a
real delete intent exists. Server-confirmed databases stay in the persisted state until a pre-hydrate
placeholder can no longer win a union, and until hydrate retries.

## Alternatives considered

- **G1 as written**: it still deletes every hydrated database on a stale capture (harness above). It ships
  only with A1.
- **G2, refuse an empty list when the baseline is non-empty**: withdrawn by the planner. With no hydrate retry
  (`:258,263-264`) and a baseline nothing clears, an account that really holds zero databases would never
  finish hydrating.
- **S1+S2, drop clean user databases from the persisted state**: this makes the placeholder union, the
  missing retry, the stale capture and the baseline clobber reachable on every account and every load. Today
  they are reachable only on the overflowing one. Blocked.
- **Move the KDS to IndexedDB** (the 2026-11-16 note in the storage-full memory): it keeps a full local copy,
  with a ms-scale local async load instead of a 287 ms network read with failure modes. It is not ruled here
  and needs its own plan and ruling.

## Consequences

- (a) G1 ships web-only after A1–A6. Rollback is the previous web tag. G1 only narrows the delete set, so a
  rollback restores today's exposure and loses nothing.
- (b) S1 stays out until L1–L8 are met and re-ruled. The toast stays on the overflowing account. That is
  visible and costs no data.
- Open, separate ruling: an in-session account switch (`src/features/auth/model/useUserStore.ts:582`, `src/app/App.tsx:236-240`) resets the
  baseline but not the KDS store. B's hydrate can then auto-repair A's databases into B's account
  (`objectDatabaseBridgeSync.ts:228-229`). This was read in the code but not reproduced, and it is
  security-sensitive.
