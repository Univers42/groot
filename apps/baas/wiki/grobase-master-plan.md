# Grobase Master Plan — beating Supabase, measured

> Every number in this document cites a benchmark artifact under
> `mini-baas-infra/artifacts/`. A claim without an artifact is not in this plan.
> Methodology: [`scripts/bench/METHOD.md`](../mini-baas-infra/scripts/bench/METHOD.md).
> Gate bars: [`scripts/bench/budgets.json`](../mini-baas-infra/scripts/bench/budgets.json).

Last measured: 2026-06-11 · box: 20 vCPU / 31 GiB / Linux 6.17 (env block in every artifact).

---

## 1. The thesis in one paragraph

Grobase has a world-class chassis — a Rust hot path that serves reads in **p95 2.4 ms**,
five live-measured tiers from a 5 MB single binary to a 3.1 GiB platform, eight engines behind
one API. What it lacked was *proof*: no load numbers, no p99s, no multi-tenant validation, and
offers whose rate limits were invented rather than measured. This plan closes that gap — it
builds the measurement layer, runs it (against our own stack and against self-hosted Supabase),
validates the multi-tenant story to 10,000 tenants, and rewrites the offers so every advertised
number is a measured number. The wedge that makes someone choose Grobase over Supabase is not a
feature checkbox; it is **a backend you can read the cost and capacity of, that grows from a
weekend project to a 10K-tenant platform on one codebase.**

---

## 2. The claims ledger

| Claim | Value | Artifact |
|---|---|---|
| Read latency (list 30, filtered, warm) | p50 1.9 ms · p95 2.4 ms · p99 3.4 ms | `artifacts/bench/load-essential-crud.json` `.median.ops.list` |
| Write latency (insert, warm) | p50 9 ms · p95 117 ms · **p99 583 ms** | same `.median.ops.insert` |
| Mixed CRUD @ 20 rps (1 tenant) | p95 12 ms (best run); high variance from writes | `load-essential-crud.json` `.runs[]` |
| **Read capacity (single pool, p95 ≤ 50 ms)** | **~400 rps at p95 < 2 ms; cliff at 500+** | `artifacts/bench/capacity-essential.json` |
| Bulk provisioning throughput | ~13 tenants/sec (10K ≈ 13 min), 0 OOM restarts | `make scale-seed` run log |
| 10K-tenant fan-out p99 | _<run `make verify-m39 SCALE=10000`>_ | `artifacts/bench/multitenant-10000.json` |
| vs Supabase footprint + latency | _<run `grobase-vs-supabase.sh` on a freed box>_ | `artifacts/bench/grobase-vs-supabase.json` |
| vs PocketBase (already shipped) | 5.1 MB vs 30.1 MB · 2.0 vs 13.1 MiB idle · faster | `artifacts/nano-vs-pocketbase.json` |

`make verify-m38` and `make verify-m39` keep the first set honest in CI (smoke modes); the deep
numbers are reproduced by the make targets in §8.

---

## 3. What the benchmarks already proved (and exposed)

**The read path is exceptional and the write path is the bottleneck.** Reads are flat at p95
2.4 ms; inserts spike to p95 117 ms / p99 583 ms (worst run p99 2.5 s). The cause is the
synchronous outbox-CDC write the `/data/v1` insert path performs (the row change is written to
`public.outbox_events` for realtime/webhooks before the response returns). **This is the single
highest-leverage latency fix in the system** — async/batched outbox emission would collapse the
write tail. Tracked as **D-write-tail** in §7.

**A single pool serves ~400 rps of reads, then falls off a cliff.** Capacity discovery
(`capacity-essential.json`) found reads flat at **p95 < 2 ms from 25 to 400 rps**, then a hard
cliff at 500–800 rps: p99 jumps to **8–10 seconds** with 5xx errors. That cliff is the per-mount
connection-pool saturating (one mount = one pool = N connections). It is the measured justification
for two things: the **v2 tier rps numbers** (advertised rates sit at or below 400 so a single
tenant never alone saturates its pool — §6), and the **B4 pool-policy + supavisor multiplexing**
work (to lift the per-tenant ceiling and to hold a 10K-mount fleet, §7).

**Three scale bugs were found and fixed while building the harness — each was silently voiding a
promise:**

1. **Kong's edge rate limit throttled the product.** The `/data/v1` route carried a 300-requests-
   per-minute *per-IP* cap. A single application server is the normal deployment shape, so the
   edge limit rejected **76 % of a 20 rps run** — every tier's advertised rps was a lie below the
   edge ceiling. Raised to sit above the largest tier (`kong.yml`, measured before/after). The
   real limiter is the per-tenant token bucket in the Rust plane.
2. **Control-plane crypto OOM-crashlooped under bulk provisioning.** tenant-control's Argon2id
   (32 MiB/op) and adapter-registry's scrypt (16 MiB/op) had no concurrency bound; a 16-way bulk
   provision crash-looped both services (8 and 17 restarts) under their 48–64 MiB limits, surfacing
   as connection EOFs. Bounded each with a semaphore (`ARGON2_MAX_CONCURRENT` / `SCRYPT_MAX_CONCURRENT`,
   default 2) and right-sized the limits. Provisioning is now stable at 13/s with zero restarts.
3. **The pool registry's 256-pool default cannot hold a multi-tenant fleet.** One pool per mount,
   LRU-capped at 256 — 10K tenants × 1 mount = 10K keys ≫ 256 → eviction churn. New `/metrics`
   counters (`baas_data_plane_pools_open`, `..._pool_events_total{event}`) make the churn
   observable; the per-tier `DATA_PLANE_MAX_POOLS` policy is §6.
4. **Provision silently ignores the `plan` field.** `POST /v1/provision` accepts a `plan` in its
   spec, but `Reconciler.CreateTenant(slug, name, ownerUserID)` (reconcile.go) has no plan
   parameter — so every provisioned tenant defaults to `free`, which under v2 resolves to `nano`
   (sqlite-only). A tenant provisioned with a postgresql mount + `plan: pro` is created as `free`
   and then 403s its own mount (`engine_not_in_package`). Surfaced by the scale seeder. The fix is
   to thread `spec.Plan` into `CreateTenant`; tracked as a control-plane gap. The scale experiment
   works around it with `PACKAGE_ENFORCEMENT=0` in `docker-compose.scale.yml` (tiering is m28's
   gate, orthogonal to plane-mechanics measurement).

---

## 4. The four-way comparison

_(measured rows filled from artifacts; spec rows marked.)_

| Axis | Grobase | Supabase | PocketBase | Firebase |
|---|---|---|---|---|
| Read p95 (warm) | **2.4 ms** (measured) | _<vs-supabase>_ | ~5.2 ms (measured) | spec: managed |
| Self-host floor | 5.1 MB / 2 MiB (measured) | multi-GB stack | 30 MB / 13 MiB (measured) | n/a (cloud only) |
| Engines | 8 | 1 (Postgres) | 1 (SQLite) | proprietary |
| Isolation models | 4 per mount | RLS | single-tenant | security rules |
| Tenants/host (measured) | _<from §5>_ | per-project | 1 | n/a |
| Grow path | Nano→Max, one codebase | vertical Postgres | migrate off | locked in |

The honest framing carries to the marketing site (`apps/baas/site` `/compare`): every competitor
gets a "choose them if" box. Supabase wins today on Studio polish and ecosystem; Grobase wins on
multi-engine, isolation choice, cost transparency and the no-rewrite grow path.

---

## 5. The 10,000-tenant story (validated at 1,000; scale-tested)

**Provisioning works and is bounded.** The Go bulk provisioner seeded **1,000 tenants (+keys
+postgresql mounts) in 57 s (~18/s), zero errors, zero control-plane OOM restarts** — the Argon2/
scrypt concurrency bounds from §3 hold under sustained provisioning. `artifacts/scale/tenants-1000.jsonl`.

**The fan-out experiment found the real ceiling — and it is the key-verification throughput, not
the data plane.** Driving a zipf-skewed 400 rps across all 1,000 tenants, the data plane stayed
**featherweight: RSS 51 MiB, `pools_open` 38, `pool_events_total{event="evicted"} = 0`** (the 4096
cap held — zero churn). Raising Postgres to 2,000 connections changed nothing (same wall), ruling
out connections. The metric that told the truth was the **verify cache: ~10% hit rate (605 hits /
5,317 misses)**. Every miss funnels to tenant-control's **Argon2id** verify, which is bounded to
**2 concurrent** (the semaphore from §3 that fixed the OOM) — so ~40 verifies/sec max. At 400 rps
with 90% misses the demand is ~360/sec; verifies queue, the data plane's 10 s upstream timeout
fires, and the client sees **502** (tenant-control sat at 152 MiB / **1.58% CPU** — not working,
*waiting in the semaphore queue*).

So the measured multi-tenant ceiling is: **`steady_tenants ≈ verify_cache_working_set` before the
Argon2id verify throughput (a single tenant-control × the concurrency bound) becomes the wall.**
The data plane never broke a sweat (51 MiB for 1,000 tenants). The fixes are concrete and in §7:
enlarge + lengthen the verify cache (keep more keys warm), **horizontally scale the stateless
tenant-control** (N replicas = N× verify throughput), and add a **cheaper verify fast-path** (Argon2
only on first-seen; a keyed-hash check on the warm path). `artifacts/bench/multitenant-1000.json`.

This is the program working as designed: the measurement layer turned "can it do 10K tenants?" from
a guess into a **named, observable bottleneck with a quantified fix** — and corrected a plausible
wrong answer (Postgres connections / pool churn) along the way. The data plane is not the limit;
**control-plane verify throughput is**, and it scales horizontally.

- **Reproduce**: `make scale-seed SCALE=10000` → `make verify-m39 SCALE=10000` (under the scale
  compose override). The dials to watch on `/metrics`: `pools_open`, `pool_events_total{event}`,
  `cache_events_total{cache,result}` (verify/mount hit rate — the line between every request and an
  Argon2id round-trip), `ratelimit_tracked`.

Acceptance bars live in `budgets.json` `.scale`. The 100K path is [§ product-plan/09](product-plan/09-100k-tenant-path.md).

---

## 6. The offers, criticized and rebuilt

**What was wrong (every point artifact- or code-grounded):**

- `free → essential` alias mapped the *free* plan onto the **$13/mo-to-run** tier — upside down.
- **nano** is the marketing wedge yet had **no entry in `packages.json`**.
- **basic and essential were identical** in engines AND capability mask — they differed only in
  rps (10 vs 20). Indefensible as two products.
- rps values 10 / 20 / 200 / 2000 were **invented**. Measured reads sustain far more than 200 rps
  at p95 2.4 ms; the limiter exists to protect the **write** path, not the read path.
- `max`'s 50 mounts/tenant against the global 256-pool default means ~6 max-tenants can thrash the
  whole plane.

**The rebuilt matrix** (`config/packages/packages.json`, mirrored in the Go control plane, m28-gated):

_<final table filled from capacity numbers; nano added; basic=CRUD-only, essential gains
aggregate; rps = measured_capacity × fair_share × 0.5; pool_policy aligned with §3.3; each tier
carries `_tenancy_guidance` citing its m39 artifact; aliases fixed free→nano.>_

Applied across the single source of truth: `packages.json` → `wiki/cost-analysis.md` →
`wiki/service-tiers.md` → `apps/baas/site/src/data/tiers.ts`. Versioned offer sheet:
[`offer-sheet-v2.md`](offer-sheet-v2.md).

---

## 7. Roadmap (sequenced, each with a measured gate)

Legend: **✅ landed** (code + unit tests in-tree, flag-gated where it changes behavior) ·
**◐ partial** · **○ next**. "Landed" means the mechanism ships and is unit-verified; the
*measured* gate (the live re-bench) is run when the box is freed — the harnesses in §8 produce it.

| ID | Move | Why (measured) | Status |
|---|---|---|---|
| **D-write-tail** | Async/**batched** background outbox emission on `/data/v1` writes (worker drains a bounded queue, coalesces ≤64/INSERT; non-blocking enqueue, drop-counted) | insert p99 583 ms vs read 3.4 ms — a 2nd synchronous DB round-trip was on the write tail | **✅ landed** — `outbox.rs` `BackgroundOutbox`; `/metrics` `outbox_events_total{stage}`. Gate: insert p99 ≤ 50 ms (re-bench) |
| **R1** | Query-router out of the data path | −127 MiB Node; essential → fits basic VM | **✅ realized** — bypass ON by default, Kong `/data/v1`→Rust direct (m36), and the PACKAGE tiers (`basic := go rust`) never start the query-router. TS code retained per the deletion gate (shadow editions only) |
| **B4-verify** | **Argon2-only-on-first-seen** verify cache in tenant-control (SHA-256(key)→identity, TTL'd, revoke-flushed) | **the measured 1K-tenant ceiling**: 10% cache hit → Argon2 @ 2-concurrent = ~40 verify/s wall (502s) | **✅ landed** — `verifycache.go`; repeat verify skips DB **and** Argon2 → cold-start Argon2 becomes a one-time warmup. `TENANT_CONTROL_VERIFY_CACHE_TTL_MS` (default 60 s). Gate: fan-out p99 ≤ 2× baseline, 0×502 |
| **B4-pools** | **DSN/credential-keyed shared pools** for `shared_rls` (per-request RLS scoping makes the pool tenant-stateless) | 256-pool default ≪ 10K mounts; per-tenant pools waste connections | **✅ landed** (flag-gated `DATA_PLANE_SHARE_POOLS`, off=parity) — `effective_pool_key`; 10K shared_rls tenants on one DB → 1 pool. schema_per_tenant/db_per_tenant correctly keep per-tenant pools. Gate: m39 pool-eviction = 0 |
| **B4-limiter** | Redis Lua token-bucket backend (authoritative across replicas) | in-process buckets desync across N replicas (each admits the full rate) | **✅ landed** (feature `ratelimit-redis`, off=in-process fast path) — `RateLimiter` enum, shared `refill_and_take` math, fail-open. Gate: multi-instance 429 correctness |
| **Plan-wiring** | Thread the provision `plan` field → `CreateTenant` | provision silently dropped `plan` → every tenant defaulted to free; the scale run had to disable enforcement | **✅ landed** — `reconcile.go`→`findOrCreateBySlug`; the `PACKAGE_ENFORCEMENT=0` scale workaround is removed (scale now runs WITH tiering, the prod shape) |
| **D2-realtime** | Fan-out Mutex→per-worker channels (C1), drop counters (C2), Arc-shared event (C3), payload serialize-once (H1) | router 1.8K routes/s @10K subs; held-across-await mutex; 617 ns/client serialize | **◐ partial** — C1 **✅** (gateway dispatcher → per-worker queues, no shared mutex; `fanout.rs`), C2/C3 already in `router.rs` (batch `Arc` dispatch + `dispatch_failures`). H1 (writer serialize-once) ○ next |
| **R2** | Fold 6 Node orchestrators → Go (one binary, not six runtimes) | −359 MiB; essential $13 → $6.5/mo | **◐ started** — consolidated `cmd/orchestrator` host + `SubService` seam + first port (`logsvc`, parity with the Node log-service, unit-tested) shipped as a 32 MiB shadow service (`profiles: background`). Remaining 5 services port into the same binary one at a time (shadow→parity→retire). Gate: footprint + m32 |
| **Wedge** | Cost-routed OLAP/OLTP plane (product-plan/05) + SaaS quotas/metering (product-plan/06) | the differentiator nobody ships cleanly | **○ next** — per those plans' gates |

Every behavior-changing lever (B4-pools, B4-limiter) ships **off by default** so the live baseline is
byte-parity; flip the flag to measure the win. R2 changes the benchmark numbers, so it runs **after**
the baseline freeze — the improvement is itself a measured deliverable.

### 7.1 Live re-bench (2026-06-11, rebuilt images, 50 `pro` `shared_rls` tenants on one DSN)

Ran on the running stack with the rebuilt data-plane + tenant-control, scale override applied,
`make scale-seed SCALE=50` then list+insert across every tenant. Measured from the new `/metrics`:

| Lever | Evidence | Result |
|---|---|---|
| **B4-pools** | `baas_data_plane_pools_open` with `DATA_PLANE_SHARE_POOLS=1` vs `=0` | **1 vs 50** — 50 shared_rls tenants on one DSN collapse to a single pool (at 10K: 1 vs 10K). `pool_events_total{evicted}=0` (no churn). **Gate PASS.** |
| **B4-verify** | `cache_events_total{cache=verify}` | 52 hit / 51 miss — the fast path populates; each tenant's first verify misses (one-time Argon2), repeats hit, skipping DB + Argon2. |
| **D-write-tail** | `outbox_events_total{stage}` | enqueued→written off the request path, `dropped=0 failed=0` — the background worker commits the event asynchronously (handler no longer pays the INSERT round-trip). |
| **Plan-wiring** | adapter-registry `/databases` status | 50× **201** (was 50× **403**) — `pro` tenants register postgresql mounts under `PACKAGE_ENFORCEMENT=1`, no workaround. The re-bench also surfaced + fixed a *second* drop site: the `plan` field was lost at the HTTP boundary (`ProvisionRequest` had no `Plan`; `Compile()` didn't map it) — now wired end-to-end. |

The stack was restored to base config (new images retained, flags at parity defaults) after the run.

---

## 8. Reproduce everything

```bash
cd apps/baas/mini-baas-infra            # drive only via the Makefile

make bench-load PACKAGE=essential WORKLOAD=crud      # read+write latency split
make bench-capacity PACKAGE=essential WORKLOAD=read  # clean read ceiling
make bench-capacity PACKAGE=essential WORKLOAD=crud  # realistic mixed ceiling
make bench-mem PACKAGE=essential DURATION=30m         # RSS drift under load
bash scripts/bench/realtime-fanout.sh                 # realtime delivery distribution
bash scripts/bench/grobase-vs-supabase.sh             # head-to-head (solo, on-demand)

make scale-seed SCALE=10000                           # bulk provision (resumable)
make verify-m39 SCALE=10000                           # the 10K validation
make scale-teardown SCALE=10000

make verify-m38 && make verify-m39                    # CI smoke gates (skip when stack down)
make verify-all                                       # everything, cheap modes
```

Every command writes a JSON artifact under `artifacts/`; this document cites them by path.
