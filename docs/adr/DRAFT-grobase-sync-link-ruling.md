# DRAFT: a grobase sync link polls a Postgres source on a (ts, pk) cursor and writes to a Postgres target first, through the registry, the kill switch and a dedicated caller class

- Status: draft, untracked. Ruled by devil 2026-11-24. Full ruling, with E1–E20 and SL1–SL31: `/mnt/storage/dlesieur/scratch/grobase-interop/RULING.md`.
- Scope: the grobase interop MVP, `/mnt/storage/dlesieur/scratch/grobase-interop/DESIGN.md`, decisions R1–R8. Code read: grobase `origin/main` 5cfcae06.
- Deciders: devil. The grobase builder lives with it.

## Context

Paths are short: `pool/` is `data-plane-pool/src`, `srv/` is `data-plane-server/src`, `core/` is `data-plane-core/src`.

- **Sort order.** `sort` is a `BTreeMap`. The Postgres and Mongo lowerings emit it in key-name order, so a `(updated_at, id)` sort becomes `ORDER BY id, updated_at`. Sources: `core/operation.rs:115`, `pool/postgres/filter.rs:224-245`, `pool/mongo/filter.rs:280-297`.
- **Mongo upsert, the quickstart's target:**
  - It ignores `op.filter` and keys on `data.id`, then `data._id` (`pool/mongo/query.rs:375`).
  - It always adds `owner_id` to the filter, even for `tenant_owned` (`pool/mongo/query.rs:384`). Reads skip it (`pool/mongo/filter.rs:256`).
  - With no `id` mapped, every row overwrites one document.
- **Postgres upsert** keys on `filter` with `ON CONFLICT`, and adds no owner for `tenant_owned` (`pool/postgres/crud.rs:154-180`).
- **MySQL upsert** uses `ON DUPLICATE KEY UPDATE`, which fires on any unique key (`pool/mysql/query.rs:195`).
- **Introspection** reports no unique indexes (`core/schema.rs:87-100`).
- **Sources other than Postgres:**
  - A Mongo poll compares an ISO string against a BSON Date and returns 0 rows silently (`pool/mongo/convert.rs:181`).
  - On an http source, `$gt` is undefined (`pool/http/query.rs:81-97`).
- **http engine.** Every non-2xx answer is 502 (`pool/http/pool.rs:190`). The SSRF guard is `guard_and_resolve`, with an `ALLOW_INTERNAL` escape (`pool/http/validate.rs:98-115`).
- **Limits and timeouts:**
  - The tier `max_rows` silently lowers the limit (`srv/routes/query.rs:155`).
  - The data plane has no per-query timeout (grep, no `statement_timeout`).
  - The control-plane client reads at most 1 MiB of a response (`tenants/dataplane.go:44-45`).
- **The internal `/v1/query`:**
  - It runs with `emit_outbox=false` (`srv/routes/query.rs:41`).
  - It sits behind `require_service_auth` (`srv/routes/mod.rs:155`), which defaults to off (`inbound_auth.rs:58`).
  - Caller policy admits only QueryRouter (`caller_policy.rs:52`).
  - It does not re-check `enabled`.
- **Registry and kill switch:**
  - `GetConnection` is scoped to the tenant and returns `Location` (`adapterregistry/connection.go:34-57`). Under KS3 it will answer 423.
  - The dispatcher holds the registry token (`orchestrators/compose/base/storage.yml:74`). In the monolith it also holds the vault key, so it could skip the registry.
- **Unknown when this was written:**
  - The poll defaults and their load on a source (U8, unmeasured).
  - The kill switch U1 is not on main.
  - The SSRF ruling's `internal/egress` is not built.

## Decision

The sync link is built with these properties:
- **Engines.** It reads a Postgres source only. It writes to a Postgres target, and to an `http` target once the SSRF guard exists.
- **Paging.** Fix B: every query carries one sort key. One query drains a tie group on `pk`, the other advances on the cursor field up to a source-clock bound. A page is "drained" only when it returns fewer rows than `min(batch, tier max_rows)`.
- **Resolving mounts.** Every batch resolves both mounts through the registry over HTTP, never by decrypting in-process. The worker calls `/v1/query` under its own caller class, proven with inbound auth and caller policy on enforce.
- **Kill switch.** A 423 pauses the link and replays the gap when the connection reopens.
- **Cycles.** They are refused on physical location plus entity.
- **What is stored.** `cursor_key` is a single value, overwritten in place and hard-deleted. Errors are stored as enum codes only.
- **Rollout.** Everything is off behind `SYNC_LINKS_ENABLED`. The API is experimental. Admin scope is required.

## Alternatives considered

- **The design as written, with a pg to Mongo quickstart first.** It loses because two source rows collapse into one target document with no error (`pool/mongo/query.rs:375-384`).
- **A multi-key sort on the existing `BTreeMap`.** It loses because the order follows key names, not the caller's order (`pool/postgres/filter.rs:231`).
- **Decrypting DSNs in the dispatcher.** It loses because it skips `enabled`, and so the kill switch (`storage.yml:74`). See `.out-of-scope/sync-link-in-process-dsn-decrypt.md`.
- **Mongo, http or MySQL as a source.** It loses on silent zero rows or undefined `$gt`. See `.out-of-scope/sync-link-non-postgres-source.md`.
- **Cross-tenant links in the MVP (R6).** It loses because consent scope and revocation are unruled, and tenant match is enforced only under enforce mode. See `.out-of-scope/sync-link-cross-tenant.md`.

## Consequences

- **Verdict: PROCEED-WITH-CONDITIONS SL1–SL31.** The conditions are listed in the ruling.
  - R1–R5, R7 and R8 proceed under conditions. R6 is BLOCKED.
  - Also BLOCKED:
    - the Mongo target, until SL29: a data-plane PR fixes the `tenant_owned` owner filter and refuses an upsert with no id
    - the MySQL target, until SL30: introspection reports unique keys
    - all sources other than Postgres
- **Build order:**
  1. KS1–KS3 and `internal/egress`.
  2. The D1 caller class.
  3. The migration (096 or later) and Fix B.
  4. The pg-to-pg worker, with AT1–AT12 and the SL28 tests.
  5. The benchmarker sets the defaults.
  6. The http target.
  7. The Mongo PR, then the Mongo target.
  8. The pg-to-Mongo quickstart.
- **What this makes harder:**
  - Hard deletes are never propagated, which leaves a GDPR erasure gap. Tenants are told so, and the docs use a soft-delete column (SL25).
  - The poll defaults stay provisional until measured (SL9).
- **Side issues to file in grobase:**
  - F-A: a Mongo upsert with no id overwrites an arbitrary document.
  - F-B: the `tenant_owned` owner filter differs between upsert and read.
  - F-C: the design's "no auth layer" claim is stale.
  - F-D: the http engine maps 4xx to 502.
  - F-E: the design's ADR numbers 0007–0010 collide. The real numbers start at 0033 or later.
