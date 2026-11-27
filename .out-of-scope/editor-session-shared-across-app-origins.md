# One editor session shared between production and beta frames is out of scope

- Decided: 2026-11-27 · by devil (connector trusted-browser ruling, TB3–TB4)
- Holds while: production and the beta share one storage partition (`ts.net` on the Public Suffix List) and the beta runs develop

## The concept

The connector's editor frames share one `/api/fs` session over `BroadcastChannel("osionos-editor")`,
so a new frame opens files without asking again. Under this concept that keeps working whichever
app origin, production or beta, frames the editor.

## Why not

- **One partition.** Production and the beta are one site, so their node frames share a
  partition (web-terminal Amendment 1, A1).
- **The channel ignores origin.** It answers any asker (`src/editor-client/session.ts:66-70`,
  osionos d9bc375ca).
- **The frame can claim production.** Before the parent speaks, the frame's wire origin falls back
  to the first configured origin (`session.ts:87`). The socket opens before linking
  (`nodeFsClient.ts:98-118`).
- **The node does not check.** It does not bind a session secret to the origin it was opened under
  (`node-credentials.mjs:53`, `fs-service.mjs:150`).

Together, these let a beta-framed editor work on production-bound folders with no beta step-up.
The owner's R5 override accepted the beta only because "R4 still binds each secret to the origin
that received it" (groot ADR 0041:73-75).

## Prior requests

- 2026-11-27 (connector trusted-browser design, D1): one device store for terminal and editor. It
  left the channel as is.

## Reopen when

Either of these changes:

- Production and the beta stop sharing a partition, for example the beta moves to a different
  registrable domain.
- The owner withdraws the beta (W15) and the node lists one app origin only.
