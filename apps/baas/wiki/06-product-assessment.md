# 06 — Product assessment: is this a *good* BaaS product yet?

> Honest, evidence-based evaluation against the stated vision: an **engine-agnostic** BaaS (à la DreamFactory) that does **all operations, not just CRUD**, lets visualization-only users lean on **Trino**, and can **connect/disconnect layers** to run as an **OLAP** or **OLTP** model with different resource footprints.

**Bottom line up front:** This is an *excellent architectural foundation and an impressive engineering demonstrator* — but it is **not yet a good product** by the bar of DreamFactory / Supabase / Hasura, and it falls short of *its own vision* in concrete, verifiable ways. The good news: almost every gap is a *missing implementation on a correct foundation*, not a design dead-end. The bad news: the gaps are in the **core value proposition** (the operations and the OLAP/OLTP intelligence), not the periphery.

---

## 1. The hard evidence (don't trust the brochure)

### 1.1 It is not even *full CRUD* — and Postgres is the worst

The Rust adapters' actual operation dispatch (`crates/data-plane-pool/src/*.rs`):

| Engine | list | get | insert | update | delete | upsert | batch | aggregate/join |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| **postgresql** | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| mongodb | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| mysql | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| redis | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| http | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |

- **Postgres — the flagship OLTP engine — cannot UPDATE or DELETE** through the unified query plane (`postgres.rs` `dispatch_op` handles only List/Get/Insert; everything else → `NotImplemented`). That is a showstopper for a product.
- **The capability descriptors lie.** `EngineCapabilities::postgresql()` advertises `write: true, upsert: true, transactions: true` — none of update/delete/upsert are implemented. The new capability *planner* I added (good) validates against the **advertised** caps, so it happily lets an `update` through to an adapter that then 501s. Advertised ≠ implemented is a trust problem.
- **No `batch` on any engine.** `max_batch_size` is advertised and even enforced by the planner, but no adapter implements batch.

### 1.2 "All operations, not just CRUD" — mostly aspirational

What exists beyond CRUD:
- `POST /v1/admin/raw` — arbitrary engine-native statement, **`service_role`/`admin` only**. Powerful, but it's an escape hatch, not a tenant-facing API.
- `POST /v1/admin/migrate` — DDL batch (schema-per-tenant), admin-gated.
- `POST /v1/transactions*` — multi-statement tx (Postgres only, 30s TTL, no reaper).

What does **not** exist as first-class tenant operations:
- **Aggregations** (count/sum/avg/group-by), **joins** / relationships, **window functions**, **full-text / pattern search**, **sorting beyond a single column**, **pagination cursors** (only limit/offset), **bulk ops**, **RPC / stored procedures** at the data-plane level.
- The rich `cost { latency_class, pattern_search, joins }` model is **defined and unused** — the very thing that should power "beyond CRUD" routing.

> DreamFactory exposes filtering, relationships, aggregation, stored procedures, and scriptable endpoints across 20+ connectors. Hasura/Supabase give relationships, aggregates, RPC, realtime. This platform, at the *unified* API level, gives single-table CRUD (partial) on 5 engines.

### 1.3 Engine-agnostic — true in shape, thin in breadth

- **5 engines** (postgres/mongo/mysql/redis/http), and the 6 stubs (jdbc, cassandra, neo4j, elasticsearch, qdrant, influx) were **deleted** (`m7`). The `EngineAdapter` trait is a genuinely clean extension point — but breadth is a fraction of DreamFactory's.
- `http` and `redis` are "engines" in name; their operation semantics are necessarily loose.

### 1.4 OLAP vs OLTP layer-switching — ~30% realized

Your vision: *the BaaS can connect/disconnect layers to be an OLAP model or an OLTP model, with different resource footprints and contexts.*

**What's real (deployment-time):** the plane/edition orchestration (this session's Makefile + `docker-compose` profiles) genuinely lets you stand up:
- an **OLTP-leaning** stack — `query`/`prod` editions: Rust engine pools + realtime + outbox + Redis (light, low-latency), or
- an **OLAP-leaning** stack — `analytics` edition: **Trino + Iceberg (lakehouse) + MySQL** (heavy, analytical).

The **resource footprint genuinely differs**, and you can add/drop the analytics plane live (`make up-analytics` / `make down-analytics`). That part of the vision **works**.

**What's missing (the product-level part):**
1. **No first-class "workload mode"/context.** OLAP vs OLTP is a *deployment* choice, not a per-tenant/per-project/per-query runtime context.
2. **No unified OLAP+OLTP query plane.** Trino is reachable only via a **separate** Kong `/sql` route — it is **not** integrated into `/query/v1` or the SDK. A client must *know* whether to hit the OLTP query API or the OLAP SQL endpoint. There's no single surface that routes for them.
3. **No cost-driven routing.** The capability `cost` model (which classifies `latency_class` native/adapter/fdw/remote and `joins` native/limited/none) is exactly what should decide "send this aggregation/join to Trino, this point-read to the engine pool" — but it's unused. The router forwards by a static engine allow-list, not by workload.
4. **No automatic columnar/lakehouse path.** Iceberg + Trino exist but nothing tiers OLTP data into the lakehouse for analytics, or routes scans there.

So the **deployment-shape** half of your OLAP/OLTP vision is done; the **runtime intelligence** half (the part that makes it feel like a product, not two stacks) is not. Crucially, the foundation (capability cost model + pluggable planes) is right, so this is *buildable without rework* — but it's the single biggest piece of net-new product work.

---

## 2. Where it genuinely is strong (credit due)

- **The 3-language plane architecture is excellent** and rare: TS for expressive business glue, Go for tiny always-on control daemons, Rust for the hot-path engine pools. The boundaries are clean HTTP contracts.
- **Capability-driven engine abstraction** (`EngineAdapter`/`PoolRegistry` + `EngineCapabilities`) is the *correct* foundation for both "agnostic" and "OLAP/OLTP routing." Adding an engine is one line.
- **Auth depth**: GoTrue (JWT, MFA, OAuth), api-keys, HMAC-signed identity envelopes (strict mode), Postgres RLS, ABAC + field masks, scope-based authz for api-keys. This is more serious than most hobby BaaS.
- **Provisioning + isolation**: one-call `/v1/provision` (tenant + key + role + mount + per-tenant schema), with a real `schema_per_tenant` strategy enforced in the Rust pool. End-to-end proven live.
- **Operational maturity signals**: per-tenant pools, circuit breaker, DSN cache, outbox/CDC → Redis Streams → realtime + webhooks, WAF + Kong, secrets/Vault, cross-tier metrics + trace correlation, a disciplined shadow→parity→cutover migration model with gates.

This is well above "toy." It's a credible *platform skeleton*.

---

## 3. The gaps that keep it from "good product"

**Core value (must-fix):**
1. **Complete CRUD on every advertised engine** — especially Postgres update/delete/upsert. Until then the capability descriptors are dishonest.
2. **Beyond-CRUD as first-class tenant ops**: filtering operators, sort, pagination cursors, **aggregations**, **relationships/joins**, search — driven by the cost model.
3. **Unified OLAP/OLTP query plane**: fold Trino into `/query/v1` + the SDK; route by `cost` (joins/scan → federation; point ops → pools); make "OLAP context" vs "OLTP context" a real per-tenant/project mode.

**Multi-tenant productization (must-fix for SaaS):**
4. **Quotas / usage metering / billing** — `plan` is stored but unenforced; no per-tenant rate limits (Kong limits per-IP), no usage accounting.
5. **HA / scale** — single-node Compose; no multi-node, no horizontal scaling story, no connection-pool limits per tenant DB.
6. **Tenant DB lifecycle** — backups exist only for the platform Postgres, not registered external tenant DBs; no credential rotation drill for tenant DSNs end-to-end.

**Developer experience (should-fix to compete):**
7. **SDK completeness** — no functions, webhooks, transactions, admin/provision, or the OLAP surface in `@mini-baas/js`.
8. **Schema introspection / typed API** per registered DB (PostgREST does this only for the internal PG).
9. **GraphQL** — explicitly absent; a real differentiator vs Hasura.
10. **Admin UI** for the custom services (Studio is Postgres-only).

**Quality / trust (should-fix):**
11. **Thin end-to-end testing** — the *entire gateway query path was 404-broken* until this session, and the monorepo `tsc` was red on an orphan. That a flagship path was silently broken signals missing integration/e2e coverage and CI teeth.
12. **Identity-model complexity** — slug vs UUID coexisted inconsistently (now mostly unified); the api-key→ABAC path was broken until just now. The auth model is powerful but under-tested at the seams.

---

## 4. What it would take to be a "real good product" (prioritized)

1. **Finish the operations** — full CRUD on all engines (Postgres U/D/upsert first), then aggregations/joins/search/sort/cursor pagination, wired to the `cost` model. *This is the product.*
2. **Unify OLAP/OLTP** — one query plane that routes OLTP↔Trino by cost; make OLAP/OLTP a first-class, switchable **context** (not just an edition). Tier OLTP→Iceberg for analytics.
3. **Tenant SaaS layer** — quotas, per-tenant rate limits, usage metering, plan enforcement, billing hooks.
4. **HA + scale** — Helm/K8s from the edition manifest, horizontal scaling, pool ceilings.
5. **DX** — complete the SDK (incl. OLAP), schema introspection, optional GraphQL, an admin UI.
6. **Make the capabilities honest** — the planner should reflect *implemented* ops, and `/v1/capabilities` should report reality so the SDK's compile-time typing is true.
7. **Real test pyramid + CI gates** — e2e through the gateway for every engine×operation; block merges on red.

---

## 5. Verdict

- **As an architecture / platform skeleton:** genuinely strong, thoughtfully layered, and — uniquely — its layer/edition model already delivers the *deployment-shape* half of the OLAP/OLTP vision.
- **As a product a customer could rely on today:** **not yet.** The core promise — "any engine, all operations, OLAP *or* OLTP" — is only partially true: it's *partial CRUD on 5 engines*, Postgres can't update/delete, "beyond CRUD" is an admin escape hatch, and OLAP is a separate bolted-on endpoint rather than an intelligent, switchable context.
- **Distance to "good product":** medium-large, but **on the right foundation** — the capability/cost model and the pluggable planes are exactly what the missing pieces need. The work is *implementation and integration*, not redesign.

The most honest one-liner: **it's a beautifully engineered chassis with the engine half-built — finish the operations and make OLAP/OLTP a real runtime choice, and it becomes the product you're describing.**
