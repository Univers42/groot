# Polling a Mongo, http or MySQL source for a sync link is out of scope

- Decided: 2026-11-24 · by devil (draft ADR `docs/adr/DRAFT-grobase-sync-link-ruling.md`, SL3)
- Holds while: no engine other than Postgres has passed a tie-group, cursor-type test (AT5 style) through the data plane

## The concept

A sync link should be able to read changed rows from any CONNECT engine: Mongo collections, MySQL tables, or a REST API mounted with the `http` engine. The same `updated_at` cursor and `$gt` filter would apply to all of them.

## Why not

- **Mongo.** A filter value that is an ISO string stays a string. A string `$gt` never matches a BSON Date, so the poll returns 0 rows with no error (`data-plane-pool/src/mongo/convert.rs:181`).
- **http.** The filter goes raw into the query string and sort is sent as JSON. The remote API decides whether `$gt` means anything (`data-plane-pool/src/http/query.rs:81-97`).
- **MySQL.** The cursor round trip and the tie order have never been proven. The `BTreeMap` sort order applies there too (`data-plane-core/src/operation.rs:115`).
- What would have to change, per engine: a test where a tie group larger than the batch and a native date cursor are all delivered, through the real adapter.

## Prior requests

- 2026-11-24 (interop design D2): one capture path for "a CONNECT source", engine-agnostic.

## Reopen when

That engine has the AT5-style test green on main. Rule on each engine separately.
