# osionos foundation — Phase 3: record sub-items + hybrid content storage

> Status: **DESIGN + prepared migration (NOT applied).** Phases 1–2 are implemented, agent-
> verified, and committed. Phase 3 touches the **BaaS data plane** (schema + edges + bridge),
> so per the project's migration discipline it must be applied **with the stack up** and pass
> the **shadow → parity → cutover** gates — never blind. This document is the executable plan.

## Why this is the foundation

The user's model: *"everything is a distributed database; each table has attributes; one
record is data shaped as a note; relate all nodes with each other."* Phases 1–2 already give:

- **Folders** (a page flagged `surface:"folder"`) that group + connect (Phase 1a/1b).
- A **page metadata inspector** with typed properties + page↔page **relations** (Phase 1d).
- The file tree in the **Second Brain graph**, folders as distinct "gap" nodes (Phase 1c).
- A Home **Database mode** that browses the live BaaS: **mount = database → resource = table →
  node.data = record** via `/query/v1/graph/overview` (Phase 2).

Phase 3 closes the loop: **records can own sub-items** (child records / pages), and a note's
**content** is stored the right way (hybrid), so relations stay traversable.

## Decision (confirmed): hybrid content storage

A node is split across two representations that live in the **same mount** (so one `/txn` is
ACID):

| Concern | Where it lives | Why |
|---|---|---|
| Identity + scalar properties (title, status, dates, numbers, owner…) | **relational columns** (or a `props jsonb`) on the node row in its table (mount) | queryable, indexable, aggregatable (`op:aggregate`), RLS-enforced |
| Relations / folder membership / **sub-items** | rows in the dedicated **`edges` mount** (`from`,`to`,`type`) | the one thing only an agnostic layer can show; powers the graph (`explicitEdges`) |
| Block **content** (the document body) | a **`content jsonb`** column on the node row (a co-located JSON document) | preserves the document as one unit; no shredding of blocks into rows |

This matches what already exists: the editor persists blocks through the **outbox**
(`usePageSync`), the graph reads `og_nodes`/`edges`, and `/graph/overview` already returns each
node's `data` (the row) + `edges`. We are formalizing storage, not inventing a new plane.

## Sub-items = a typed self-relation in the `edges` mount

A **sub-item** is a child record/page owned by a parent record. Represent it as an edge:

```
edges row: { id, from: "<mount>:<resource>:<parentPk>", to: "<mount>:<resource>:<childPk>",
             type: "sub_item", directed: true }
```

- **Read:** `/graph/overview` (and `/graph` focus) already return `edges`; group `type:"sub_item"`
  by `from` to render expandable sub-rows under a record in the Database mode. No new endpoint.
- **Write:** one `/txn` (single mount) inserts the child node row **and** its `sub_item` edge
  **atomically** when child + edges share the mount (see `txn-contract.md`; builder pattern in
  `apps/osionos/app/src/features/second-brain/baas/buildNoteTxn.ts` / `buildRecordTxn.ts`).
- **Folder membership** reuses the same mechanism with `type:"contains"` — so the Phase 1c
  folder→file edges (currently derived client-side from `parentPageId`) become **real `edges`
  rows**, and folders then appear as connectors in the BaaS-backed graph automatically through
  the existing `explicitEdges` source (no client folder-graph code needed long term).

## Prepared migration (sketch — apply via Makefile, then verify)

Additive only (no drops — honours the no-deletion-without-gates rule). Adjust table/mount names
to the live schema in `models/*.sql` before running.

```sql
-- 1) Hybrid content column on the notes/records table (idempotent).
ALTER TABLE <records_table> ADD COLUMN IF NOT EXISTS content jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE <records_table> ADD COLUMN IF NOT EXISTS props   jsonb NOT NULL DEFAULT '{}'::jsonb;

-- 2) Sub-item / containment edges live in the dedicated edges mount (already exists for graph).
--    Ensure a type check + an index for fast "children of X" lookups.
ALTER TABLE <edges_table> ADD CONSTRAINT edges_type_known
  CHECK (type IN ('relation','contains','sub_item','tag','reference')) NOT VALID;  -- validate after backfill
CREATE INDEX IF NOT EXISTS edges_from_type_idx ON <edges_table> (from_id, type);

-- 3) RLS: child rows + edges inherit the parent's workspace/owner policy (reuse existing policy).
```

## Implementation steps (do WITH the stack up)

1. **Schema**: finalize the SQL above against `models/*.sql`; apply with `make` (the migration
   target), not by hand. Confirm RLS still isolates per workspace.
2. **Bridge mapping**: persist `content` (blocks) + `props` on the node row; write relation /
   `contains` / `sub_item` as `edges` rows. The outbox already detects store changes.
3. **osionos client** (small, additive, ≤200-line files):
   - `baasDatabaseData`: also return `overview.edges`; add `subItemsOf(edges, recordId)`.
   - `DatabaseBrowserParts.RecordsTable`: expandable sub-rows for `sub_item` children + a count.
   - "Add sub-item" / "Add record" → `/txn` via the existing `buildRecordTxn` builder.
4. **Folder edges cutover**: write `contains` edges on file/folder create/move; switch the Phase
   1c graph to read folder edges from `explicitEdges` (drop the client-derived page-tree edges
   once parity is confirmed).

## Verification gates (required before cutover / any deletion)

- **Shadow + parity**: new hybrid writes produce identical reads through the existing path; the
  graph shows the same nodes/edges with the new `edges`-mount source as the client-derived one.
- **`/txn` atomicity**: creating a record + its `sub_item`/`contains` edge in one mount returns
  `guarantee:"atomic"`; a forced failure rolls back both.
- **RLS isolation**: account A cannot read account B's records, sub-items, or content.
- **CI green** with forward routing. Only then remove the client-side folder-edge derivation.

— Phases 1–2 are live in the desktop build; Phase 3 lands here once the stack is up to verify.
