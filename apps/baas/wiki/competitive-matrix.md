# Grobase Competitive Parity Matrix — vs Supabase & Firebase

> **Source:** 6-agent code audit, 2026-06-13. Where older wiki docs (06/07) disagree, the code wins.

**Thesis.** Grobase (the productized form of `mini-baas`) is **Supabase-shaped**: it runs the same open core — `gotrue` (auth), `postgrest` (auto REST), Supabase `studio`, `supavisor`, `pg-meta`, and `kong` — so anyone fluent in Supabase is immediately at home. (Auth ships in **two distinct backends**: the **default vendored gotrue stack** the multi-engine tiers run — Google/GitHub/FortyTwo only, every `*_ENABLED` defaulting false — and **binocle-one**, a separate `cargo build --features one` binary with 11 OAuth2-PKCE presets + any-OIDC + TOTP; the stronger OAuth/OIDC/MFA story lives in binocle-one, not the default stack, and is not yet surfaced in the `@mini-baas/js` SDK — see the Auth section note.) On top of that it adds two things neither Supabase nor Firebase has: a **custom Rust multi-engine data plane** (one uniform API over Postgres/MySQL/Mongo/SQLite/MSSQL/Redis/HTTP, including wrapping a customer's *existing* database) and a **Go control plane** that puts **thousands of tenants on shared infrastructure** (~10K — 9,775 seeded — tenants collapsed to a single connection pool, proven by gate m46). Grobase's competitive **edge is multi-engine + dense multi-tenancy** — Supabase is Postgres-only and single-project-per-backend; Firebase is Firestore-only and closed. The honest weaknesses are managed-cloud table stakes: no metering/billing, thin tenant self-service, and several developer-experience gaps (storage SDK, functions triggers/cron, multi-language SDKs, GraphQL).

Companion docs (ship together, cross-linked):
- [marketability-readiness.md](./marketability-readiness.md) — the four marketability bars and where we stand.
- [roadmap-to-market.md](./roadmap-to-market.md) — Phase 0 + Track A (OSS) + Track B (cloud) + Track C (scale/HA).

Related: [grobase-master-plan.md](./grobase-master-plan.md), [product-plan/06-saas-multitenancy-quotas-billing.md](./product-plan/06-saas-multitenancy-quotas-billing.md), [product-plan/09-100k-tenant-path.md](./product-plan/09-100k-tenant-path.md), [security-audit.md](./security-audit.md), [cost-analysis.md](./cost-analysis.md), [offer-sheet-v2.md](./offer-sheet-v2.md), [nano-vs-pocketbase.md](./nano-vs-pocketbase.md).

---

## Legend

| Glyph | Meaning |
|-------|---------|
| **[v]** | Have it — first-class, shipped, on by default |
| **[~]** | Partial — built but off-by-default, via one engine only, presign-only, stub, or DIY |
| **[x]** | Missing — not implemented (planning docs only) |
| **[+]** | Differentiator — capability **neither competitor** ships |
| **N/A** | Not applicable to this product shape |

Status tiers used in the scorecard: **PARITY+** (at or above competitor) / **PARITY** / **PARTIAL** / **GAP**.

Competitor cells use the audited source glyphs: `v` = first-class, `~` = partial/via-extension/paid/DIY, `x` = none. Effort: **S** (days) / **M** (1–3 wks) / **L** (>3 wks or net-new subsystem). Priority: **P0** = needed for OSS launch parity / **P1** = needed for managed-cloud launch / **P2** = nice-to-have or differentiator polish.

---

## Full Parity Matrix (rows 1–91)

### Database

| # | Capability | Supabase | Firebase | Grobase | Gap (what is missing) | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----------------------|:------:|:---:|----------------|
| 1 | Relational SQL DB | v | x | **[v]** | — (PG incl. Cockroach over pgwire, MySQL/MariaDB, MSSQL, SQLite) | — | — | `data-plane-pool/src/postgres.rs`, `mysql.rs` |
| 2 | NoSQL document DB | ~ | v | **[v]** | — (native Mongo adapter + Redis-KV) | — | — | `data-plane-pool/src/mongo.rs`, `redis.rs` |
| 3 | ACID transactions | v | ~ | **[~]** | Multi-statement txn PG+MySQL only; Mongo/SQLite/MSSQL `begin()` = NotImplemented | M | P1 | `postgres.rs` (BEGIN+RLS), `mysql.rs` |
| 4 | Joins / relational queries | v | ~ | **[x]** | No joins/relationships as a tenant op (graph BFS subgraph ≠ joins) | L | P1 | `data-plane-core/src/operation.rs` (no join op) |
| 5 | Composite / custom indexing | v | v | **[~]** | Via DDL/migrate on PG/MySQL; no first-class index API | M | P2 | `data-plane-pool` DDL path |
| 6 | Native full-text search | v | ~ | **[x]** | No FTS op exposed | L | P2 | not in `operation.rs` |
| 7 | Vector / embeddings | v | v | **[x]** | No pgvector / vector search | L | P2 | planning only |
| 8 | Geospatial | v | ~ | **[x]** | No PostGIS / geo op | L | P2 | planning only |
| 9 | Schema migrations | v | ~ | **[v]** | — two surfaces: **migration batch** (`/v1/admin/migrate`) on **PG + MySQL only**, vs **single-op schema DDL** (`/data/v1/schema/ddl`) on **PG / MySQL / Mongo / SQLite** | — | — | `data-plane-pool` migrate + schema-ddl paths |
| 10 | DB branching / preview DBs | v | x | **[x]** | No branching | L | P2 | — |
| 11 | Read replicas / PITR / backups | v | ~ | **[~]** | Whole-cluster only: `pg_dump -Fc` daily 14d→MinIO + optional WAL/PITR (gate m47). No per-tenant restore, no read replicas | M | P1 | `services/pg-backup`; gate m47 |
| 12 | Foreign data wrappers / external sources | v | x | **[+]** | — Grobase goes further: `tenant_owned` wraps a customer's **existing** DB as a native mount | — | P2 | `isolation.rs` (TenantOwned) |

### Auth

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 13 | Email / password | v | v | **[v]** | — (gotrue; binocle-one native) | — | — | vendored gotrue |
| 14 | Magic link / email link | v | v | **[v]** | — (gotrue) | — | — | gotrue |
| 15 | Phone / SMS OTP | v | v | **[~]** | gotrue supports it but no SMS provider wired by default (roadmap A2 will own the wiring) | S | P1 | gotrue config |
| 16 | Anonymous sign-in | v | v | **[~]** | gotrue supports it but it is **not enabled by default** — needs `GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED` | S | P1 | gotrue config |
| 17 | Social OAuth | v | v | **[~]** | Built in **binocle-one** (11 OAuth2-PKCE presets + any-OIDC), **not surfaced in the `@mini-baas/js` SDK**; default vendored gotrue wires only Google/GitHub/FortyTwo and all are config-gated (a client-id is required — not literally on-by-default), with every `GOTRUE_EXTERNAL_*_ENABLED` defaulting to false | M | P0 | binocle-one OAuth matrix; vendored gotrue |
| 18 | SAML enterprise SSO | ~ | ~ | **[x]** | No SAML | L | P2 | — |
| 19 | OIDC generic provider | v | ~ | **[v]** | — any-OIDC, but only in the **binocle-one** binary (`cargo build --features one`), not the default multi-engine stack | — | — | binocle-one |
| 20 | MFA TOTP | v | ~ | **[~]** | gotrue MFA is **enabled by default** (`GOTRUE_MFA_ENABLED=true`) but **unexposed in the SDK**; **binocle-one** has its own TOTP + recovery codes (separate `--features one` build), also unsurfaced in container tiers/SDK | M | P1 | binocle-one MFA; gotrue config |
| 21 | MFA SMS | v | ~ | **[x]** | No SMS MFA | M | P2 | — |
| 22 | Passkeys / WebAuthn | v | ~ | **[x]** | No passkeys | L | P2 | — |
| 23 | Auth↔DB authz wiring | v | v | **[v]** | — JWT → GUC (`app.current_tenant_id`/`current_user_id`) + owner predicate; ABAC + field masks | — | — | `postgres.rs` (`apply_rls_context`), control-plane `jwt.go` |
| 24 | Act as OAuth provider | v | x | **[~]** | **binocle-one** (the `--features one` build) is an OAuth *client* (PKCE), not a full OAuth2.1 *server*; the default gotrue stack is not an OAuth server either | L | P2 | binocle-one |
| 91 | Email deliverability / SMTP provider | v | v | **[~]** | gotrue + Mailpit, **dev-only** (no prod SMTP wired) | M | P1 | gotrue; Mailpit → Track A2/A6 |

> **Two auth backends — read the rows accordingly.** Grobase ships **two distinct** auth implementations and the rows above mix them: **(a)** the **default vendored gotrue stack** that the multi-engine tiers actually run — it wires only **Google / GitHub / FortyTwo**, and every `GOTRUE_EXTERNAL_*_ENABLED` (plus anonymous sign-in) defaults to **false**; and **(b)** **binocle-one**, a **separate `cargo build --features one` binary** with **11 OAuth2-PKCE presets + any-OIDC + TOTP/recovery**. The `[~]` OAuth/OIDC/MFA strength on rows 17/19/20/24 lives in the **binocle-one binary**, not in the default multi-engine stack, and none of it is surfaced through the `@mini-baas/js` SDK.

### Auto API

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 25 | Auto REST over schema | v | x | **[v]** | — PostgREST v12.2.3 (PG) + multi-engine `/v1/query` (always-on) with an opt-in `/data/v1/query` bypass (`DATA_PLANE_BYPASS_ENABLED=1`), PostgREST-style filters | — | — | postgrest (v12.2.3); `data-plane-server/src/routes.rs` |
| 26 | Auto GraphQL | v | ~ | **[x]** | No GraphQL — `"graphql"` appears only in planning docs, zero impl | M | P1 | planning only |
| 27 | Fluent client query builder | v | v | **[~]** | SDK REST builder is options-object, not fluent (no `.eq/.in/.or/.single/.range` chaining) | M | P0 | `sdk/src/domains/rest.ts` |
| 28 | Server Admin SDK | v | v | **[v]** | — `admin`, `schema` domains (serviceRoleKey) | — | — | `sdk/src/domains/admin.ts` |

### Realtime

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 29 | Realtime DB-change subscriptions | v | v | **[~]** | WS fanout + SSE works, but PG CDC = per-table TRIGGERS + LISTEN/NOTIFY (not WAL/logical-rep; needs `CREATE TRIGGER` per table). Mongo = native change streams | M | P1 | `realtime-db-postgres` (triggers), `realtime-db-mongodb` |
| 30 | Broadcast / pubsub channels | v | x | **[x]** | No first-class broadcast primitive (code grep for `broadcast`/`presence` hits only a tokio channel, a test fixture, and IRC docstrings — not client-facing primitives) | M | P1 | realtime workspace |
| 31 | Presence (who is online) | v | ~ | **[x]** | No presence primitive (same grep caveat as row 30 — tokio channel + test fixture + IRC docstrings, nothing client-facing) | M | P1 | realtime workspace |
| 32 | Realtime scale | v | v | **[~]** | In-process + IRC bus. A **JS realtime client EXISTS** (`sdk/src/domains/realtime-client.ts`, via `engine().subscribe()`) **but is mongodb-only** — SDK caps set `stream:false` for postgresql, so PG `subscribe()` is a compile error despite the Rust PG producer; no mobile client; no multi-node fanout proof; not surfaced as a top-level `client.realtime`/`.channel` API | M | P1 | `realtime-bus-irc`, `realtime-bus-inprocess`, `sdk/src/domains/realtime-client.ts` |

### Storage

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 33 | Object / file storage | v | v | **[~]** | MinIO + storage-router, but SDK exposes **only** `presign()` — no upload/download/list/createBucket. The **server is also presign-only** (storage-router exposes only `POST /sign`; no upload/download/list/createBucket route) — closing this needs **server endpoints**, not just SDK methods. Presign supports **PUT + GET**, so upload/download already work via the signed URL | M | P0 | `sdk/src/domains/storage.ts` (`presign` is the only method); storage-router (`POST /sign`) |
| 34 | Access rules on files | v | v | **[v]** | — ABAC-gated, owner-prefixed, TTL-clamped presign | — | — | storage-router (`POST /sign`) |
| 35 | Signed URLs | v | v | **[v]** | — presigned URLs (the one thing storage does well) | — | — | storage-router |
| 36 | On-the-fly image transforms | v | ~ | **[x]** | No transforms | M | P1 | — |
| 37 | CDN delivery | v | v | **[x]** | No CDN integration | M | P2 | — |
| 38 | Resumable uploads | v | v | **[x]** | No TUS/resumable | M | P2 | — |

> Note: storage-router README advertises a `.bucket().signPut()` SDK API that **does not exist** — stale doc, flagged for Phase 0 reconciliation.

### Functions

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 39 | Serverless functions | v | v | **[~]** | Deno worker-per-invocation, 5s timeout, **sandboxed perms (no env/fs-write/run/ffi; network NOT restricted — `net:inherit`)**, Kong-routed — but **HTTP invoke only**, in `functions`/`extras` profile (not lean default) | M | P0 | `functions-runtime/src/server.ts` (invoke-only, `TIMEOUT_MS=5000`) |
| 40 | DB / event triggers | ~ | v | **[x]** | No DB/event triggers | L | P1 | — |
| 41 | Scheduled / cron | v | v | **[x]** | No cron/scheduling | M | P1 | — |
| 42 | Function secrets | v | v | **[x]** | env disabled in worker (no secrets) | M | P1 | functions-runtime |
| 43 | Durable queues | v | ~ | **[x]** | No queues | L | P2 | — |
| 44 | Edge / regional invocation | v | ~ | **[x]** | Single-node, no edge/regional | L | P2 | — |

> Also missing in functions: CLI/local-dev, streaming, warm pool, cgroup CPU/RAM caps; per-**user** namespacing (not per-tenant).

### Events / Webhooks

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 87 | Webhooks / event-delivery | v | v | **[~]** | **SHIPPED** (`sdk/src/domains/webhooks.ts` + webhook-dispatcher), but **admin-only / ip-restricted**, no browser self-serve; retry/backoff + HMAC story still to document | M | P1 | `sdk/src/domains/webhooks.ts`; webhook-dispatcher |

### Push

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 45 | Managed push (mobile/web) | x | v | **[x]** | No push/messaging (parity with Supabase; clear Firebase win) | L | P2 | — |

### SDKs / Client

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 46 | JS / TS SDK | v | v | **[v]** | — `@mini-baas/js`, Supabase-shaped (`createClient`/anonKey/serviceRoleKey/`.from()`) + **[+]** novel capability-typed `engine<E>()` client | — | — | `sdk/src/index.ts`, `types.ts` |
| 47 | Flutter / Dart | v | v | **[~]** | Generated Dart client `sdk-dart` (openapi-generator; `dart analyze` clean) from `openapi/grobase-public.json` — not yet hand-polished/pub-published | M | P1 | `sdk-dart/`, `sdk/scripts/codegen-polyglot.sh` |
| 48 | Swift / iOS | v | v | **[x]** | No Swift SDK | L | P2 | — |
| 49 | Kotlin / Android | v | v | **[x]** | No Kotlin SDK | L | P2 | — |
| 50 | Python | v | v | **[~]** | Generated Python client `sdk-python` (urllib3) — pip-installs + imports (5 API groups) | M | P1 | `sdk-python/`, `sdk/scripts/codegen-polyglot.sh` |
| 51 | Go / C# / Rust | ~ | v | **[~]** | Rust realtime client exists; no general Go/C#/Rust data SDK | L | P2 | `realtime-client` |
| 52 | Unity / C++ / game | x | v | **[x]** | No game SDKs | L | P2 | — |
| 53 | Offline persistence + auto-sync | x | v | **[x]** | No offline sync/local cache (parity with Supabase; clear Firebase win) | L | P2 | — |

> Also: `.transaction()` on the engine client is a no-op wrapper; no schema→types generation (only engine catalog gen); OpenAPI spec dir is **empty** (blocks all multi-lang codegen).

### Dashboard

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 54 | Table / data editor | v | v | **[~]** | Studio = **vendored Supabase Studio unmodified** (Postgres-only, single-project, **not tenant-aware**, ip-restricted) | L | P1 | `services/studio/Dockerfile` (`FROM supabase/studio`) |
| 55 | SQL editor | v | x | **[~]** | Via vendored Studio only (not multi-tenant) | — | P1 | vendored Studio |
| 56 | User management UI | v | v | **[~]** | binocle-one has a 27KB admin UI at `/_/`; no multi-tenant tenant-facing UI | M | P1 | binocle-one `/_/` |
| 57 | Logs / usage viewer | v | v | **[x]** | No tenant-facing logs/usage viewer | L | P1 | observability is global-only |
| 58 | Visual schema designer | v | x | **[x]** | None (Studio not wired to mount control plane) | L | P2 | — |

### Dev Tooling

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 59 | CLI | v | v | **[x]** | No `baas` CLI (Makefile + Docker Compose only) | L | P0 | — |
| 60 | Local dev full parity | v | ~ | **[~]** | Full Docker Compose stack runs locally, but no emulator/CLI ergonomics | M | P1 | root Makefile, editions |
| 61 | Type generation from schema | v | x | **[x]** | No schema→types gen (only engine catalog gen) | M | P0 | SDK codegen |
| 62 | Branching / preview envs | v | ~ | **[x]** | None | L | P2 | — |
| 63 | CI/CD integration | v | v | **[~]** | CI gates exist (m-series, security scans); no first-class deploy integration | S | P1 | `scripts/verify/*` |

### Observability

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 64 | Server / DB logs | v | v | **[~]** | Loki + Promtail wired, but **single-tenant**, no `tenant_id` label — a tenant cannot see their own logs | M | P1 | observability stack |
| 65 | Metrics / reports | v | v | **[~]** | Prometheus + Grafana (4 dashboards), all 3 planes expose `/metrics` (gate m19) — but **global-only**, no `tenant_id` label | M | P1 | gate m19 |
| 66 | Security / perf advisors | v | ~ | **[x]** | No advisor | M | P2 | — |
| 67 | Crash reporting | x | v | **[x]** | None (parity with Supabase; Firebase win) | L | P2 | — |
| 68 | Client analytics | x | v | **[x]** | None (parity with Supabase; Firebase win) | L | P2 | — |
| 69 | Customer alerting | ~ | v | **[~]** | Alert rules exist (gate m52) but operator-facing, not per-customer | M | P1 | gate m52 |

### Security / Compliance

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 70 | Row / record-level authz | v | v | **[v]** | — RLS GUC + owner predicate on PG; owner-scoped writes on all engines; ABAC + field masks | — | — | `postgres.rs`, `mongo.rs` (identity-stamped `owner_id`/`tenant_id`) |
| 71 | App attestation / anti-abuse | x | v | **[x]** | No App Check equivalent (Firebase-unique) | L | P2 | — |
| 72 | SOC 2 | v | v | **[x]** | No SOC2 (audit-ready posture planned, not done; formal SOC2 deferred) | L | P2 | [security-audit.md](./security-audit.md) |
| 73 | HIPAA | v | v | **[x]** | No HIPAA. Both competitors are **BAA-gated HIPAA-eligible** (BAA required) — not on by default | L | P2 | — |
| 74 | ISO27001 / GDPR | v / v | v / v | **[x]** | No certs; GDPR-shaped controls exist but not attested. (Supabase is now **fully ISO/IEC 27001:2022 certified**, Apr 2026 — supabase.com/blog/supabase-is-now-iso-27001-certified) | L | P2 | — |
| 75 | Network restrictions / PrivateLink | v | ~ | **[~]** | WAF ip-restricts admin; single flat bridge network (no plane isolation/NetworkPolicy) | M | P1 | residual in security-audit |
| 76 | Audit logs | ~ | ~ | **[~]** | Writes traceable; **reads not audited**; no tenant-scoped audit log | M | P1 | residual |
| 89 | Data residency / region selection | v | v | **[x]** | No region/residency selection | L | P1 | → Track C3 |
| 90 | Rate-limiting / DDoS / abuse protection | ~ | ~ | **[~]** | WAF CRS (`owasp/modsecurity-crs:4-nginx-202604040104`) + per-tenant token bucket | M | P1 | gate m51 (multi-instance rate-limit) |

> **[+] Differentiator (not a numbered row):** in-stack **ModSecurity v3 + OWASP CRS WAF** as the sole public listener — `services/waf/Dockerfile` (`FROM owasp/modsecurity-crs:4-nginx-202604040104`). Neither Supabase nor Firebase ships an in-stack WAF. Recent audit fixed: MSSQL MITM, HTTP-engine SSRF, timing side-channels, Mongo NoSQL injection, cross-owner `$or` leak, bytea corruption. Open residuals: `ANON_KEY`/`SERVICE_ROLE_KEY` are shared HS256 JWTs signed by one `JWT_SECRET` (runtime-generated; `.env` is gitignored and never git-tracked — **not** a committed secret), so the cloud needs per-deployment keys + the RS256 issuer flip; Vault not enforced; flat network; adapter-registry trusts `X-Baas-*` headers.

### Self-host

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 77 | OSS / self-hostable (prod) | v | x | **[+]** | — OSS, Docker-Compose-first, multi-arch on Docker Hub; **tiny footprint** (nano 5.16MB, essential ~660 MiB / 13 services[†]) beats both | — | P0 | [offer-sheet-v2.md](./offer-sheet-v2.md) |
| 78 | Local emulator (dev) | v | v | **[~]** | Compose stack is the "emulator"; no dedicated emulator/CLI | M | P1 | root Makefile |

> [†] Essential-tier footprint **re-baselined post-cutover** to **~660 MiB across 13 services** (commit `4325a24`; was ~950 MiB / 19 services before the FLIP orchestrator cutover retired Node six). Gate m32 is the already-shipped footprint gate.
>
> [‡] **Measured head-to-head vs self-hosted Supabase** (2026-06-13, same box, same probe — `scripts/bench/grobase-vs-supabase.sh`): Supabase self-host = **2884 MiB / 13 containers**; the **like-for-like Grobase parity shape** (Postgres + auth + REST + realtime + storage + functions + gateway) = **~448 MiB** (~600 MiB incl. the Studio dashboard) → **~5–6× lighter for the same feature surface**. PostgREST read latency is at **parity** (both run the same PostgREST — they trade ±0.1–0.4 ms across runs). Full service-for-service map + per-service RSS (e.g. Supabase realtime 269 MiB vs our Rust realtime 20 MiB): [grobase-vs-supabase-offer.md](./grobase-vs-supabase-offer.md). The edge is footprint + multi-engine + dense multi-tenancy, not raw read speed.

### Multi-tenancy

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 79 | Many tenants on shared infra (product) | x | x | **[+]** | — **NEITHER competitor does this.** SHARE_POOLS: **~10K (9,775 seeded) tenants → 1 pool, 0× 5xx**, ~30 MiB RSS. Postgres SHARE_POOLS on/off is **byte-identical** (neutrality probe); cross-engine (mysql/mongo) isolation is proven by **owner-scoped no-leak** (gate m46) — note the bench table has no RLS | — | P0 | gate m46 (`scripts/verify/m46-share-pools-isolation.sh`); `mount.rs::effective_pool_key`, `lib.rs::pools_shared` |
| 80 | One-backend-per-tenant pattern | ~ | ~ | **[v]** | — `tenant_owned` (distinct DSN) + `schema_per_tenant` + `db_per_tenant` (declared) | — | — | `isolation.rs` |
| 81 | Auth-level multi-tenancy | ~ | ~ | **[v]** | — per-request isolation via JWT→GUC, not per-pool | — | — | `isolation.rs`, `postgres.rs` |
| 88 | Organizations / teams / members / invites | v | v | **[x]** | ABAC per-principal exists, but **no org / membership / invite model** | L | P1 | → Track B4 |

### Pricing

| # | Capability | Supabase | Firebase | Grobase | Gap | Effort | Pri | Notes / anchor |
|---|-----------|:--------:|:--------:|:-------:|-----|:------:|:---:|----------------|
| 82 | Free tier | v | v | **[~]** | Self-host is free; no managed free tier yet (no billing system) | L | P1 | [offer-sheet-v2.md](./offer-sheet-v2.md) |
| 83 | Flat base + usage | v | ~ | **[x]** | No billing/Stripe; tier pricing modeled but not charged | L | P1 | offer-sheet-v2; product-plan/06 |
| 84 | Per-MAU auth pricing | v | ~ | **[x]** | No metering, so no per-MAU billing. (Firebase: **Identity Platform IS per-MAU** — 50K free then per-MAU; the `~` reflects legacy Firebase Auth) | L | P1 | no `tenant_usage` code |
| 85 | Egress pricing | $0.09/GB | ~$0.12/GB | **[x]** | No egress metering/billing. (Firebase: **~$0.12/GB** Cloud Storage/GCP egress; **Hosting is $0.15/GB**) | L | P2 | — |
| 86 | Dedicated compute add-on | v | x | **[~]** | Tiers basic→max exist as shapes; no self-serve dedicated-compute purchase | L | P2 | [service-tiers.md](./service-tiers.md) |

---

## Differentiation — what neither Supabase nor Firebase offers

| # | Differentiator [+] | Supabase | Firebase | Proof |
|---|--------------------|:--------:|:--------:|-------|
| D1 | **Multi-engine / bring-your-own-DB** | Postgres-only | Firestore-only | 7 working adapters (`data-plane-pool/src/{postgres,mysql,mongo,sqlite,mssql,redis,http}.rs`); `tenant_owned` wraps a customer's existing DB (`isolation.rs`) |
| D2 | **Dense multi-tenancy on shared infra** | per-project backend | per-project | **~10K (9,775 seeded) tenants → 1 pool, 0× 5xx, ~30 MiB RSS** — Postgres SHARE_POOLS on/off byte-identical (neutrality probe); cross-engine (mysql/mongo) isolation proven by owner-scoped no-leak (bench table has no RLS) — gate m46 (`scripts/verify/m46-share-pools-isolation.sh`); `mount.rs::effective_pool_key`, `pool/src/lib.rs::pools_shared` |
| D3 | **Engine-agnostic uniform API** | n/a | n/a | One operation contract over heterogeneous engines; capability-honest planner asserts at boot no engine advertises an op it can't run (`data-plane-pool/src/capability_honesty.rs`, `data-plane-core/src/capability.rs`) |
| D4 | **Per-tenant cost efficiency at idle** | per-project min cost | per-project | Marginal ~$0.40–1.00/tenant on a shared pro host; data path 3.3 MiB Rust vs 127 MiB Node (~38×) — [cost-analysis.md](./cost-analysis.md) |
| D5 | **In-stack OWASP WAF** | none in-stack | none in-stack | ModSecurity v3 + OWASP CRS as the sole public listener — `services/waf/Dockerfile` (`FROM owasp/modsecurity-crs:4-nginx-202604040104`) |

---

## Scorecard

Tallied across the 91 numbered rows (Grobase cell). Each Count is the exact length of its row list, and the four sum to 91:

| Tier | Glyph | Count | Notes |
|------|-------|:-----:|-------|
| **PARITY+** (differentiator — beats both) | [+] | **3** | 12, 77, 79 (+ the WAF differentiator D5, which is not a numbered row). Rows 80/81 are marked [v] but are also competitor-beating |
| **PARITY** (first-class, on by default) | [v] | **15** | 1, 2, 9, 13, 14, 19, 23, 25, 28, 34, 35, 46, 70, 80, 81 |
| **PARTIAL** (built-but-off / one-engine / stub) | [~] | **32** | 3, 5, 11, 15, 16, 17, 20, 24, 27, 29, 32, 33, 39, 47, 50, 51, 54, 55, 56, 60, 63, 64, 65, 69, 75, 76, 78, 82, 86, 87, 90, 91 |
| **GAP** (missing) | [x] | **41** | 4, 6, 7, 8, 10, 18, 21, 22, 26, 30, 31, 36, 37, 38, 40, 41, 42, 43, 44, 45, 48, 49, 52, 53, 57, 58, 59, 61, 62, 66, 67, 68, 71, 72, 73, 74, 83, 84, 85, 88, 89 |

Headline: roughly **a fifth of rows are parity-or-better today** (18 of 91: [+]3 + [v]15), **a third are partial (mostly off-by-default or single-engine)** (30 of 91), and the gaps cluster in three places — managed-cloud commerce (metering/billing/dashboard), DX surface (storage SDK, functions triggers/cron, CLI, codegen, multi-lang SDKs), and advanced data ops (GraphQL, joins, FTS, vector).

### Top 8 P0 gaps to close for OSS launch parity

These are the [v]/[~] table-stakes that block a credible OSS self-host launch (full detail in [roadmap-to-market.md](./roadmap-to-market.md), Track A):

| Rank | Row(s) | Gap | Why it's P0 | Effort |
|:----:|--------|-----|-------------|:------:|
| 1 | 33, 34, 36 | **Storage DX** — SDK is presign-only; ship upload/download/list/createBucket + transforms | First thing a dev tries; stale README actively misleads | M |
| 2 | 39, 40, 41, 42 | **Functions DX** — add DB/event triggers, cron, secrets | "Edge Functions" is a headline BaaS feature; invoke-only is below table stakes | L |
| 3 | 27, 61 | **SDK fluent builder + type generation** — `.eq/.in/.or/.single/.range`, schema→types | Supabase's signature DX; options-object feels foreign | M |
| 4 | 47, 50 | ✅ **DONE** — OpenAPI 3.1 spec committed + **Python & Dart SDKs generated** (A3/A4); Swift/Kotlin next | (was the single blocker for all multi-language SDKs) | M |
| 5 | 59 | **`baas` CLI** — deploy, local-dev, migrate | Both competitors have one; gates functions/codegen DX | L |
| 6 | 17, 20 | **Surface OAuth + MFA in the SDK** (built in binocle-one, not exposed) | Capability exists; only the SDK seam is missing | M |
| 7 | 26 | **GraphQL** — `pg_graphql` passthrough | Frequently a hard requirement; zero impl today | M |
| 8 | — | **Security audit-ready posture** — add blocking CI secret-scan + cargo-audit/govulncheck gates, flip RS256 issuer + per-deployment keys, close header-trust/network residuals | Launch gate; residuals are launch-blockers ([security-audit.md](./security-audit.md)) | M |

> Not P0 but high-leverage for the *cloud* launch (Track B): metering (84), billing/Stripe (83), per-tenant observability (57, 64, 65), tenant self-service dashboard (56, 57). These are the largest net-new build — see [marketability-readiness.md](./marketability-readiness.md) Bar 4.

### Canonical gate numbers for the work this matrix scopes

New gates are numbered **above the shipped m1–m53 range** (never reuse a shipped number). The closing work in [roadmap-to-market.md](./roadmap-to-market.md) maps as:

| Gate | Scope |
|------|-------|
| **m54** | Phase 0 — vs-Supabase benchmark |
| **m55** | A1 — Storage DX (rows 33, 34, 36) |
| **m56** | A2 — Functions DX (rows 39–42; also owns SMS/SMTP wiring, rows 15, 91) |
| **m57** | A3 — SDK parity / codegen (rows 27, 61) |
| **m58** | A4 — multi-language SDKs (rows 47–51) |
| **m59** | A5 — GraphQL + realtime (+ stretch joins/FTS/vector) (rows 4, 6, 7, 26, 29–32) |
| **m60** | A6 — security audit-ready (rows 72–76 posture) |
| **m61** | A7 — OSS packaging |
| **m62–m67** | Track B (cloud) — incl. Organizations/teams (row 88 → B4), email deliverability (row 91 → A2/A6 + B) |
| **m68–m71** | Track C (scale/HA) — incl. data residency/region (row 89 → C3) |

Already-shipped gates this matrix cites: **m32** (essential-tier footprint, row 77 / C3 footnote), **m46** (share-pools isolation, rows 79–81 / D2), **m51** (multi-instance rate-limit, row 90).

---

## Sources

**Wiki docs (relative):**
- [marketability-readiness.md](./marketability-readiness.md) · [roadmap-to-market.md](./roadmap-to-market.md) · [grobase-master-plan.md](./grobase-master-plan.md)
- [product-plan/06-saas-multitenancy-quotas-billing.md](./product-plan/06-saas-multitenancy-quotas-billing.md) · [product-plan/09-100k-tenant-path.md](./product-plan/09-100k-tenant-path.md)
- [security-audit.md](./security-audit.md) · [cost-analysis.md](./cost-analysis.md) · [offer-sheet-v2.md](./offer-sheet-v2.md) · [nano-vs-pocketbase.md](./nano-vs-pocketbase.md) · [service-tiers.md](./service-tiers.md)

**Key code anchors (verified for this matrix):**
- Data plane core: `mini-baas-infra/docker/services/data-plane-router/crates/data-plane-core/src/{operation,capability,isolation,mount}.rs` — op set (Insert/Update/Delete/Upsert/Batch/Aggregate), honest capability flags, 4 isolation models, `effective_pool_key`.
- Engine adapters: `.../crates/data-plane-pool/src/{postgres,mysql,mongo,sqlite,mssql,redis,http}.rs` — RLS GUC + owner predicate (`postgres.rs`), identity-stamped `owner_id`/`tenant_id` + tenant-escape guard (`mongo.rs`), honest per-adapter batch (`mysql.rs` atomic, `redis.rs` non-atomic).
- Share-pools: `.../crates/data-plane-pool/src/lib.rs::pools_shared`, `data-plane-core/src/mount.rs::effective_pool_key`; gate `mini-baas-infra/scripts/verify/m46-share-pools-isolation.sh`.
- WAF: `mini-baas-infra/docker/services/waf/Dockerfile` (`FROM owasp/modsecurity-crs:4-nginx-202604040104`) + `conf/{modsecurity,crs-setup,nginx}.conf`.
- SDK: `apps/baas/sdk/src/{index,types}.ts`, `sdk/src/domains/{storage,rest,admin}.ts` (storage = `presign()` only).
- Functions: `mini-baas-infra/docker/services/functions-runtime/src/server.ts` (invoke-only, `TIMEOUT_MS=5000`).
- Studio: `mini-baas-infra/docker/services/studio/Dockerfile` (`FROM supabase/studio:...`, vendored unmodified).
- Codegen blocker: `mini-baas-infra/openapi/` (only `.gitkeep` — spec is empty).
- Benchmark (exists, never run): `mini-baas-infra/scripts/bench/grobase-vs-supabase.sh`.

**Competitor rows:** verified against official Supabase & Firebase docs, 2026.
