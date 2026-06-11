# Nano Edition — the single-binary, PocketBase-class tier

The floor below [`basic`](./service-tiers.md): **one static Rust binary, embedded SQLite, no
separate processes.** This is the tier for a landing page, a prototype, a single small app — the
people who reach for PocketBase. The goal is to **match PocketBase's rock-bottom cost and single-file
simplicity, beat its performance, and add the features it structurally can't have** — while keeping a
non-dead-end path up to the cloud tiers (`basic → max`) on the *same codebase*.

Every number below is grounded in a live measurement or a cited source; projections are labelled as
such. "Real, not marketing" is the bar.

---

## 1. What we're up against (measured reality, not slogans)

**PocketBase** ([pocketbase.io](https://pocketbase.io/faq/)): Go + `modernc.org/sqlite` — a
**pure-Go SQLite** (C transpiled to Go, no cgo). One binary: REST + SQLite + auth + file storage +
realtime (SSE) + an embedded Svelte admin. A `goja` JS VM powers hooks.

| PocketBase | Figure |
|---|---|
| Binary (standalone) | **~15 MB** ([source](https://pocketbase.io/faq/)) |
| Binary (as a Go framework + your code) | ~50 MB |
| RAM idle | ~20 MB |
| RAM under load (100k-row bench) | 90–150 MB |
| SQLite driver | **pure-Go (`modernc`)** — portable, but slower than C SQLite |
| Engines | **SQLite only, forever** |

**TrailBase** ([trailbase.io](https://trailbase.io/reference/benchmarks/)) — the honest prior art:
it is *already* a Rust + **C-SQLite** PocketBase alternative, and it proves the thesis that the
language/driver choice is worth real money:

| TrailBase vs PocketBase (their bench) | Result |
|---|---|
| Insert throughput (100k) | **~11× faster** |
| Read / insert latency | **~5× lower**, "sub-millisecond reads" |
| RAM under load | 90–150 MB (same class as PocketBase) |
| Stack | **Rust + C SQLite + WASM** |

**The honest takeaway:** "Rust + C-SQLite beats Go + pure-Go-SQLite" is *settled* — TrailBase already
demonstrates ~10× on micro-benchmarks. So our nano edition does **not** get to claim "we invented the
fast SQLite backend." Our edge over **both** PocketBase and TrailBase is the **feature set and the
graduation path** (below), riding the same Rust performance class — not a novel speed claim.

---

## 2. Why this is mostly *assembly*, not *invention*

The expensive part already exists and is measured:

- **The data plane is built and tiny.** `data-plane-router-rust` serves the full `/data/v1` surface —
  CRUD, schema, DDL, **graph/subgraph**, **ABAC + field masks**, owner-scoping, per-tenant
  token-bucket rate limits — and idles at **3.3 MiB RSS** (measured, `make bench-footprint`).
- **The SQLite engine is in-process already.** `rusqlite` with `bundled` (real C SQLite, WAL,
  file-per-mount) runs *inside* that 3.3 MiB process — **0 MiB of its own**, no server.
- **Today's compiled binary is 29 MB** (`30,326,296` bytes), and that's the *un-optimized ceiling*:
  it links **all nine** engine drivers (mongodb, tiberius/MSSQL, mysql, redis, postgres, http, …) and
  builds with **default release flags** — the workspace has **no `[profile.release]`** block at all
  (no `strip`, no `lto`, no opt tuning), dynamically linked to glibc.

So "nano" is: **take what's shipped, feature-gate it down to SQLite, absorb auth in-process, embed a
UI, and compile it small.** That's an integration + packaging job, not a green-field backend.

---

## 3. Architecture — one process, four parts

```
┌─────────────────────────────────────────────────────────┐
│  binocle-nano   (one static musl binary, FROM scratch)   │
│                                                          │
│  axum HTTP ──► /data/v1  (CRUD · schema · ddl · graph)   │  ← reuse data-plane-server
│            ──► /auth     (Argon2id verify · JWT issue)   │  ← absorb, in-process
│            ──► /_/        (embedded admin UI, brotli)     │  ← served from memory
│                                                          │
│  rusqlite (bundled C SQLite, WAL, file-per-mount)        │  ← 0 extra process
│  [optional] tokio-postgres feature ─► external Postgres  │  ← the graduation hook
└─────────────────────────────────────────────────────────┘
        one file · one port · one SQLite file on a volume
```

- **HTTP + data:** reuse `crates/data-plane-server` (`run_query`, `run_describe_schema`,
  `run_apply_schema_ddl`, `graph.rs`) behind axum — already the `/data/v1` handlers.
- **Auth absorbed:** today `auth.rs` *calls* Go `tenant-control` over HTTP for the Argon2id key
  verify. Nano swaps that one reqwest hop for an **in-process** `argon2`-crate verify against a local
  `_keys` table + `jsonwebtoken` for JWT. No gotrue, no Go control plane, no network hop.
- **Admin UI embedded:** ship a *small* SPA as `include_bytes!` brotli blobs, served from memory
  (PocketBase does exactly this with Svelte). **This is the main size variable — see the caveat.**
- **Engine-agnostic by feature flag:** default build = `sqlite`. A `--features postgres` build (or a
  runtime mount DSN) lets the *same binary* point a mount at external Postgres/MySQL. This is the
  graduation hook PocketBase can never have.

---

## 4. The <50 MB / high-speed recipe (grounded projection)

Starting point is **measured**: 29 MB binary (9 engines, default flags) → 54 MB image.

| Lever | Effect | Basis |
|---|---|---|
| Feature-gate to **sqlite-only** (drop mongodb, tiberius, mysql, redis, http, external-pg) | removes the bulk of the driver code + transitive deps (bson, bb8, tds, …) | the pool crate pulls all nine today |
| Add `[profile.release]`: `lto="fat"`, `strip=true`, `codegen-units=1`, `panic="abort"`, `opt-level="s"` | strip+lto alone routinely cut a Rust binary **30–50%** | none of these are set today |
| **Static musl** + `FROM scratch` | image ≈ binary (no glibc/libssl/libstdc++ base — those are ~25 MB of the current image) | distroless base is the other half of the 54 MB |
| Embedded admin UI, brotli, lazy-loaded | adds back the UI weight (the size wildcard) | PocketBase's UI is several MB of its binary |

**Projected nano:** **~12–18 MB binary, ~15–22 MB image (single file), ~12–25 MB idle RAM.** That
beats PocketBase's ~50 MB framework build, matches its ~15 MB standalone, and — because it's **real
C SQLite + Rust, no GC** — runs in the TrailBase performance class (sub-ms reads, ~5–11× PocketBase
on their bench). The data plane already idles at **3.3 MiB**; auth + UI + SQLite page-cache put a
realistic idle around PocketBase's ~20 MB or below.

> **Speed vs size honesty:** `opt-level="z"` is the *smallest* but can hurt throughput; for a backend
> we recommend `opt-level="s"` or `3` + `lto="fat"` — a few hundred KB larger, meaningfully faster.
> Size-extreme ("z") is a build flag away if a user truly needs the smallest file.

---

## 5. What nano does that PocketBase (and TrailBase) don't

| Capability | Nano | PocketBase | TrailBase |
|---|---|---|---|
| Single binary, embedded SQLite, ~$2/mo | ✅ | ✅ | ✅ |
| Real C SQLite + Rust (no-GC, sub-ms reads) | ✅ | ❌ pure-Go SQLite | ✅ |
| **Engine-agnostic** — same app on SQLite *or* external Postgres/MySQL | ✅ (feature/mount) | ❌ SQLite-only forever | ❌ SQLite-focused |
| **ABAC + field-level masking** (hide/redact per column) | ✅ (`abac.rs`, shipped) | ❌ row rules only | ❌ row ACLs |
| **Graph / relationship subgraph** (Obsidian-style) | ✅ (`graph.rs`, shipped) | ❌ | ❌ |
| **Multi-tenant DNA in single-tenant clothes** — owner-stamping + scopes + capability mask already there | ✅ | ❌ | ❌ |
| **Graduate to a cloud stack with no rewrite** (nano → basic → … → max, one codebase) | ✅ | ❌ (migrate off) | ❌ |
| Tiering / rate-limits / capability honesty in the same core | ✅ (shipped) | ❌ | partial |

The pitch is not "a faster SQLite box" (TrailBase has that). It's **"the lightest backend that already
has cloud-grade authorization (ABAC + masks), graph, and a real upgrade path — so you never have to
migrate off it."**

---

## 6. Honest caveats & gaps

- **The admin UI is the size risk.** Our existing osionos editor is far too heavy to embed; nano needs
  a *purpose-built minimal* admin SPA (collections, auth, logs). Until that exists, nano ships
  "headless" (API + a JSON/`curl` admin) and the embedded UI is a follow-up. PocketBase's polished UI
  is a real advantage we'd be matching over time, not on day one.
- **No JS hooks VM.** PocketBase embeds `goja` so users script hooks in JS. Nano's equivalent is
  either *nothing* (declarative automations — which we already have server-side) or a **WASM** hook
  runtime later. Day one: declarative automations + webhooks, not arbitrary JS.
- **Realtime:** the Rust realtime crate exists but adding it to nano grows the binary; an SSE-only
  minimal realtime (PocketBase-style) is the lean default, full event-bus is an upgrade.
- **TrailBase exists.** We are not first to "Rust + SQLite BaaS." Position on features + graduation,
  and benchmark *honestly* against both PB and TrailBase rather than implying we invented the class.
- **musl + rusqlite-bundled** compiles fine (C SQLite under musl is well-trodden); dropping
  mongodb/tiberius actually *removes* the drivers that most complicate a static build.

---

## 7. Build roadmap (gated — this is the data-plane/security track)

Additive; reuses the shipped crates; no existing tier changes.

1. **`sqlite` (+ optional `postgres`) cargo features** on `data-plane-pool` / `data-plane-server`, so
   `--no-default-features --features sqlite` drops the eight other drivers. Prove the binary shrinks.
2. **`[profile.release]`** (lto/strip/opt/panic) in the workspace — measure the delta on the *current*
   binary first (free win even for the full router image).
3. **New `binocle-nano` bin target** = axum app wiring `/data/v1` + in-process `argon2`/`jsonwebtoken`
   auth (port `auth.rs`'s verify from an HTTP call to a local `_keys` query) + a static-mount default
   (`DATA_PLANE_MOUNTS` already honored by `EnvMountResolver`).
4. **Static musl CI** (`x86_64-unknown-linux-musl`) → `FROM scratch` image. Publish the measured
   binary/image size + an idle-RAM reading as the proof artifact.
5. **Minimal embedded admin UI** (brotli `include_bytes!`), lazy-loaded — the last, optional piece.
6. **Bench vs PocketBase + TrailBase** on the same box (insert/read latency, idle + loaded RAM) and
   publish the honest table.

Steps 1–4 are the security/data-plane core (the natural continuation of the shipped `basic` tier);
5–6 are packaging + proof. **No TS is deleted** and no cloud tier is touched.

---

## 8. Cost (see [`cost-analysis.md`](./cost-analysis.md) for the full model)

A single small binary on Fly's floor preset (`shared-cpu-1x`, 256 MB = $2.02/mo) + a small SQLite
volume:

- **Always-on:** ~$2.02 compute + ~$0.15–0.45 volume ≈ **~$2–3 / month**.
- **Scale-to-zero** (a landing page that sleeps): compute → ~0, just the volume ≈ **< $1 / month**.

**This is the same infra floor as self-hosting PocketBase** — you can't undercut a single small binary
by much. So nano's cost story is *"PocketBase's price, with cloud-grade auth + graph + a real upgrade
path,"* and it's **~3× cheaper than our own `basic` tier** (463 MiB, ~$6/mo) for anyone who doesn't
need the multi-container flexibility yet.

> **Tier-ladder correction:** `basic` was previously called "PocketBase-class." More precisely:
> **nano = PocketBase-class (one binary, ~15 MB)**; **`basic` = the lean *microservice* step above it**
> (11 containers, 463 MiB) — more moving parts, but horizontally scalable and a stepping stone to the
> cloud tiers. Nano trades that flexibility for radical size/simplicity, exactly like PocketBase.

**Sources:** [PocketBase](https://pocketbase.io/faq/) · [TrailBase benchmarks](https://trailbase.io/reference/benchmarks/)
· live `data-plane-router` binary (29 MB) + image (54 MB) + 3.3 MiB idle (`make bench-footprint`, 2026-06-11).
