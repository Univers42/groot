# 0026. A page's content carries a version, and blocks can be appended atomically

- Status: accepted (schema half of AI-P4b-1a, on a branch, not pushed)
- Date: 2026-10-21
- Deciders: owner, after the P4b risk ruling (PROCEED-WITH-CONDITIONS, record
  `p4b-verdict.md`, `~/.cache/osionos-ai-records/`)

## Context

- A page's content is one JSONB array of blocks and every writer replaces the whole
  array, so two writers erase each other and the row keeps no trace that it happened.
- The P4b ruling named the conditions this change must satisfy: **C15** (the version is
  a CONTENT version — `OLD.content IS DISTINCT FROM NEW.content`, the predicate the
  index enqueue already uses in `models/osionos-ai-rag-migration.sql`), **C17** (a
  version a writer sends is validated, never free text), **C20** (the append is a
  Postgres function reached by RPC, not a PostgREST row write), **C21** (the append is
  idempotent) and the unknowns **U1** (can a conditional PATCH tell 0 rows from 1?)
  and **U4** (does the exposed schema serve `public` functions over RPC?).
- The conditions and their evidence are in the ruling; this ADR does not restate them.

## Decision

- `models/osionos-page-version-migration.sql` — one file, applied as a unit:
  `public.osionos_pages.version`, the `BEFORE UPDATE` trigger that owns it, the
  idempotency ledger `public.osionos_page_append_keys`, and the function
  `public.osionos_page_append(page_id, blocks, after_block_id, idempotency_key)`.
  The trigger runs before every other trigger on the table, so the version is settled
  before the after-triggers read the row.
- The append is reached over PostgREST RPC, following the rule the tree already uses
  for `public.osionos_bridge_upsert_workspace` (`models/osionos-bridge-migration.sql:361-362`):
  `REVOKE … FROM PUBLIC; GRANT EXECUTE … TO service_role`. It is **not** SECURITY
  DEFINER: the caller is `service_role`, which already holds the grants, so the table
  ACL stays the gate.
- `scripts/verify/page-version.sh` proves it on throwaway containers only (ai-pv-*),
  including the revert proof: with the content predicate removed from the trigger,
  the metadata check fails.
- Registered in `scripts/apply-models-migrations.sh` (ORDERED_FIRST, after
  `osionos-page-search-migration.sql`) and in the desktop edition's
  `apps/osionos-electron/native/firstrun.mjs` list, so both apply it.

## Consequences

- The bridge and the client half of P4b are **not** here. This change gives them the
  two things they need: a version to make a conditional write against, and an append
  that cannot lose another writer's blocks.
- A writer that sends a `version` gets the conflict handling for free only once the
  bridge reads it back; until then the column is inert and costs one comparison per
  update.
- The ledger grows one row per append. The prune statement is documented in the
  migration; no scheduler ships with it.
- The version is bumped by the content change alone, so the archive cascade, the
  record-note refresh and the marketplace writes keep the version still — a page that
  was only renamed does not 409 its open editors.
