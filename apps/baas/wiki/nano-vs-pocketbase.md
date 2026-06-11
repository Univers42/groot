# binocle vs PocketBase — the honest comparison

> **Status: GAP-CLOSING IN PROGRESS.** This is a living document: every row carries evidence
> (a gate, a bench artifact, or a PB docs link), and rows flip from GAP → ✅ only when a verify
> gate proves them. Sources: [PocketBase v0.39 docs](https://pocketbase.io/docs/), our
> `make verify-m37` / `verify-m38` gates, `scripts/bench/nano-vs-pocketbase*.sh` artifacts.

## The two offers

| Offer | What it is | Size / idle RAM | Status |
|---|---|---|---|
| **binocle-nano** | The ultra-minimal data-plane binary: CRUD + filters + aggregates + graph + scoped keys + SSE, headless | **5.1 MB / 2.0 MiB** (measured, m37) | ✅ shipped |
| **binocle-one** | *Our PocketBase*: nano + user auth (email/password, OAuth2 matrix, OTP/MFA) + typed collections + files + realtime filtering + embedded admin UI | budget **≤12 MB / ≤15 MiB** | 🔨 building (this plan) |
| PocketBase v0.39.3 | The reference competitor | 30.1 MB / ~12 MiB (measured) | — |

## Where binocle WINS today (evidence-backed)

| Capability | binocle | PocketBase | Evidence |
|---|---|---|---|
| Footprint | **5.1 MB / 2.0 MiB idle** | 30.1 MB binary / ~12 MiB idle | `artifacts/nano-vs-pocketbase.json`, m37 |
| **Server-side aggregation** — count/sum/avg/min/max + `group_by` | ✅ `op=aggregate` | **❌ none** | [PB records API](https://pocketbase.io/docs/api-records/) documents no aggregation |
| **Filter DSL** | full injection-safe AST: `$eq $ne $lt $lte $gt $gte $like $ilike $in $between $null` + `$and/$or/$not` | `= != > >= < <= ~ !~ && \|\|` (no `$in/$between/$null` equivalents beyond sugar) | `data-plane-core/src/filter.rs` (validated once, lowered per engine) |
| Graph / relationship subgraph queries | ✅ `/data/v1/graph` (BFS ≤3, multi-mount) | ❌ | m34 parity gate |
| Scoped machine API keys (mint/revoke, read/write/admin) | ✅ `/nano/v1/keys` | superuser tokens + impersonation only | m37 §3/§6 |
| **Engine graduation** — same API onto Postgres/MySQL/Mongo/… (cloud tiers), no rewrite | ✅ 9 engines, conformance-gated | ❌ SQLite forever ([their FAQ](https://pocketbase.io/faq/)) | m27 conformance, `service-tiers.md` |
| Atomic batch | ✅ | ✅ | par |
| Security primitives | constant-time compares, fail-closed 401/404, SSRF-guarded egress, audit tracing | good but less explicit | `security-audit.md`, m37 §4 |
| Insert/list latency (sequential, same box) | 4.9 / 5.2 ms | 5.0 / 5.6 ms | par — `artifacts/nano-vs-pocketbase.json` |

## Where PocketBase WINS today — the gaps `binocle-one` closes

| # | Capability | PocketBase | binocle today | Plan |
|---|---|---|---|---|
| G1 | **User auth** — email/password, OAuth2 (30+ providers), OTP, MFA, verification, reset, refresh | ✅ | API keys only | **B1** users+JWT → **B2** OAuth matrix (one OIDC+PKCE flow + presets) → **B3** OTP/TOTP/SMTP |
| G2 | **Typed collections API** (field types, validation, create via API/UI) | ✅ | raw SQL escape hatch (`/nano/v1/raw`) | **C** structured DDL for the sqlite adapter → `/data/v1/schema/ddl` works everywhere |
| G3 | **Per-record authorization** (`@request.auth` rules) | ✅ | key scopes + owner-scoping; ABAC engine compiled-in but keyless | **B1** wires user identity → owner-scoping per user + ABAC field masks live |
| G4 | **File storage** (upload/serve, thumbnails, protected files; S3) | ✅ | ❌ | **D** (S3 stays cloud-tier MinIO; documented) |
| G5 | **Realtime filtering** (per collection/record, rule-checked) | ✅ | global SSE mutation feed | **E** `?topics=` + owner-filtered events |
| G6 | Relation `expand` (≤6 levels) + `fields` projection | ✅ | graph endpoint (different shape); no projection | **E** projection; expand-by-relation stays a documented difference (graph is our answer) |
| G7 | **Admin dashboard UI** | ✅ polished Svelte | headless | **F** embedded brotli SPA at `/_/` (≤1.5 MB compressed) |
| G8 | Hooks/extending (JS VM, Go framework, cron) | ✅ | ❌ in nano/one (cloud tiers have server automations) | post-F roadmap (declarative automations first, WASM later) — honest GAP |
| G9 | Email/SMTP | ✅ | ❌ | **B3** (`lettre`) |
| G10 | Migration files/versioning | ✅ | raw endpoint | post-F roadmap — honest GAP |
| G11 | Backups API | ✅ | volume copy (no API) | post-F roadmap — honest GAP |

## Concurrent load — MEASURED (oha, same box, official PB binary, 8 s/run)

| | **binocle-nano** | PocketBase v0.39.3 | Factor |
|---|---|---|---|
| insert @ c=1 (RPS) | **3529** | 2364 | 1.5× |
| insert @ c=16 | **6437** | 2513 | 2.6× |
| insert @ c=64 | **9402** | 2560 | **3.7×** |
| **100k-row insert @ c=64** | **11,159 RPS** (~9 s total) | 2025 | **5.5×** |
| insert p99 @ c=64 | **74 ms** | 260 ms | 3.5× |
| list 30 @ c=64 (RPS) | 14,307 | **18,061** | PB 1.3× (honest loss) |
| list 30 p99 @ c=64 | **8.1 ms** | 30.0 ms | 3.7× |
| **RSS under c=64 load** | **12.7 MiB** | 477.8 MiB | **37×** |
| disk after 100k rows | **11.9 MB** | 264 MB | 22× |
| boot → first 200 | **6 ms** | 566 ms | 94× |

Write throughput comes from the **single-writer + group-commit** engine (a dedicated writer
thread coalesces up to 128 queued writes into one transaction, savepoint-per-job; replies only
after COMMIT). This was earned, not assumed: the FIRST run of this bench measured our naive
pooled writes collapsing to 48 RPS @ c=64 — the table above is the third run, after the fix.
**Honest loss kept on the board:** PB serves ~1.3× more list RPS at high concurrency (we win the
tail). Artifacts: `mini-baas-infra/artifacts/nano-vs-pocketbase-load.json`.

## Benchmark method (kept honest)

- Same box, both/all systems in containers, official PB release binary, identical driver
  (`oha` for concurrency; sequential curl numbers are labelled as curl-dominated).
- Reported: RPS + p50/p95/p99 at c=1/16/64, RSS idle + under load, 100k-row insert (disk after),
  boot-to-first-200. Artifacts: `mini-baas-infra/artifacts/nano-vs-pocketbase*.json`.
- We do not claim "N× faster" from curl loops; the concurrency table above is the load-tested one.

*Last updated: 2026-06-12 (Phase A + the group-commit engine fix).*
