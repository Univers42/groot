# DRAFT. The full page list reads flat, bracketed by a membership gate before and a proof after

- Status: proposed (draft, unnumbered). devil 2026-11-23, osionos #243 follow-up: D (read, then proof) BLOCK; D′ (gate, read, proof) PROCEED-WITH-CONDITIONS F243-1–F243-27; E not preferred.
- Date: 2026-11-23
- Code read: osionos worktree `osionos-343` at 70a4a7c2b (paths without a prefix).
- Full ruling: `/mnt/storage/dlesieur/scratch/pv243/p3/RULING-flat-read.md`. Measurements beside it: `shape.out`, `shape-http.out`, `oracle.out`.

## Context

- `/api/pages/all` reads the page list embedded two levels under the caller's member row (`scripts/bridge-api.mjs:1821-1835`). PostgREST casts each embed to jsonb. Measured locally on a synthetic 8,772-page workspace: 175–181 ms in psql against 36–38 ms for the flat aggregate; through PostgREST, 196.0 ms against 54.8 ms (`p3/shape.out`, `p3/shape-http.out`).
- The request is already more than one snapshot: the access map reads the member row again (`:1086-1093`, `:1105-1110`).
- Reading the pages before any membership check costs a non-member 43.5–51.5 ms of SQL, against 0.30–1.32 ms today. A workspace id that does not exist costs 0.12–0.28 ms (`p3/oracle.out`). That gap is a size and existence oracle, and a 5.5 MB read amplifier.
- `listPageRows` maps a body-less 2xx to `[]` (`:1754`). `db-max-rows` caps top-level rows only, and a flat read makes the pages top-level. Grobase allows any `PGRST_*` setting through `.env.postgrest` (`grobase:orchestrators/compose/base/auth-api.yml:170-174`).
- Unknown when this was written: the live row cap, the latency per extra Kong call, how the 2.1 s splits, tie counts on real data, the workspace size distribution.

## Decision

For `/api/pages/all` only, the bridge proceeds in this order:
1. Prove membership with the embed-free anchor statement (`limit=2`, `singleAnchorRow`).
2. Read the rows flat, ordered `updated_at.desc,id.asc`, failing closed on a non-array body, a row from another workspace, or a truncated count.
3. Prove membership again with the same statement before the access filter runs.

The chunked list keeps the embed.

## Alternatives considered

- **D, flat read then proof, no gate**: BLOCK. It runs the full read for non-members, which makes the timing oracle above.
- **E, one statement with an `!inner` proof per row**: not preferred.
  - It needs the anchor anyway to tell "non-member" from "empty workspace".
  - The measured shape embeds no `user_id`, so a dropped nested filter cannot be detected.
  - It costs +19.7 ms and +17 % body against D.
- **Keep the embed**: correct, but it spends ~140 ms of Postgres CPU per call on the jsonb double-parse in the largest workspace.

## Consequences

- The conditions F243-1–F243-27 in the full ruling are the acceptance criteria. The ones most likely to be skipped:
  - F243-6: a truncated read is never a 200.
  - F243-14: a non-member triggers zero page reads.
  - F243-19: byte identity on real PostgREST, including tied rows.
  - F243-23: kill if any workspace size regresses at median by more than max(5 ms, 10 %).
- Small workspaces pay two extra BaaS round trips. F243-22 measures this on the production path before promotion.
- This change does not close #243 and does not lift the S1–S6 BLOCKs in `DRAFT-page-list-243-ruling.md`.
- Rollback is the previous bridge image (beta shares the prod bridge, so there is no beta stage).
