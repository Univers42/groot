# binocle-one vs binocle-nano vs PocketBase — deep 3-way head-to-head

> **What this is.** A focused, *realistic* head-to-head between the three single-binary backends:
> **binocle-nano** (our 5 MB headless floor), **binocle-one** (*"our PocketBase"* — 6.4 MB, accounts +
> OAuth + MFA + files + admin UI), and the official **PocketBase v0.39.3**. It answers "which is more
> performant, in resources and in latency" — and, honestly, where each one wins.
>
> **Every number is measured** on one shared box (20 vCPU, ~31.9 GiB, kernel 6.17) via
> [`scripts/bench/nano-one-pb-load.sh`](../mini-baas-infra/scripts/bench/nano-one-pb-load.sh) (oha,
> c=1/16/64, RSS sampled mid-load, 100k-row run, boot-to-first-200). Fresh run 2026-06-15. Dataset:
> [`scripts/bench/compare-3way-data.json`](../mini-baas-infra/scripts/bench/compare-3way-data.json);
> charts via `make bench-compare DATA=… OUT=…`.

---

## 0. The one honesty caveat that matters

The **single-node** comparison (§1–§3) is apples-to-apples: three single-binary app backends, same box,
same workload. **Multi-tenancy (§4) is NOT.** PocketBase has **no native multi-tenancy** — it is one app
per process. binocle-nano/one are single-tenant-*by-default* SKUs **built on the multi-tenant data
plane**: they grow into the 10K/50K/100K platform on the same SDK; PocketBase cannot. So "PocketBase at
N tenants" is modeled honestly as **N instances** (§4), never faked as a single-process number.

---

## 1. TL;DR — who wins what (fresh measured)

| Dimension | binocle-nano | binocle-one | PocketBase | Winner |
|---|---|---|---|---|
| Idle RSS (MiB) | **2.0** | 2.2 | 13.1 | **binocle** ~6× |
| Binary / image (MB) | **4.9** | 6.4 | 30.1 | **binocle** ~5–6× |
| RSS under load (MiB) | **14.0** | 16.4 | 496 | **binocle** ~30× |
| Disk after 100k rows (MB) | 18.9 | **18.0** | 303 | **binocle** ~16× |
| Cold start (ms) | 6 | **5** | 379 | **binocle** ~70× |
| Insert rps @ c16 | **17,441** | 16,983 | 2,469 | **binocle** ~7× |
| Insert p99 @ c16 (ms) | **1.9** | 2.1 | 87.4 | **binocle** ~45× |
| **List rps @ c16** | 12,794 | 11,739 | **28,088** | **PocketBase** ~2.2× |
| List p99 @ c16 (ms) | **1.7** | 1.9 | 2.4 | ~tie |
| Multi-tenancy | ✅ (grows into platform) | ✅ | ❌ none | **binocle only** |

**The shape of it:** binocle wins **resources, writes, and cold-start decisively**; **PocketBase wins
read throughput** (an honest, real win — its read path is excellent); **binocle-one costs ~nothing over
nano** on the hot path (the full app backend — accounts/OAuth/MFA/files/admin UI — is free at runtime);
and **multi-tenancy is binocle's alone**.

---

## 2. Resources

![idle footprint](assets/competitive-3way/idle_footprint_mib.svg)
![RSS under load](assets/competitive-3way/rss_under_load_mib.svg)
![disk after 100k rows](assets/competitive-3way/disk_after_100k_mb.svg)
![cold start](assets/competitive-3way/cold_start_ms.svg)

PocketBase idles at **13 MiB** and balloons to **~496 MiB under load** (Go runtime + SQLite page cache);
binocle-nano/one hold **14–16 MiB under the same load** — a ~30× difference at the moment it matters. On
disk, 100k rows cost binocle ~18 MB vs PocketBase ~303 MB. Cold start: **5–6 ms vs 379 ms** (binocle is a
static scratch binary; PocketBase boots a Go server + opens SQLite + migrations).

**binocle-one vs binocle-nano:** +0.2 MiB idle, +1.5 MB image, +2 MiB under load — the entire app backend
(accounts, OAuth2 matrix, TOTP MFA, files, the `/_/` admin UI) costs essentially nothing because it's the
same engine + the same group-commit writer.

---

## 3. Performance — latency & throughput by concurrency

![insert rps vs concurrency](assets/competitive-3way/insert_rps_vs_concurrency.svg)
![insert p99 vs concurrency](assets/competitive-3way/insert_p99_vs_concurrency.svg)
![list rps vs concurrency](assets/competitive-3way/list_rps_vs_concurrency.svg)
![list p99 vs concurrency](assets/competitive-3way/list_p99_vs_concurrency.svg)

**Writes — binocle's decisive win.** PocketBase's single-writer SQLite **serializes** under write
concurrency: insert rps *drops* from c1→c16 (2,593 → 2,469) and its p99 tail **explodes** (0.7 → **87.4
ms** @ c16 → **123 ms** @ c64). binocle's group-commit writer *climbs* (8,525 → 17,441 → 19,852 rps) with
a flat tail (0.2 → 1.9 → 9.9 ms). On the 100k-row run: **nano 20,797 rps / p99 10 ms** vs **PocketBase
2,797 rps / p99 137 ms**.

**Reads — PocketBase's honest win.** PocketBase's read path is genuinely fast and *wins* list throughput
at c16 (**28,088 rps** vs binocle ~12–13K). Reads don't hit the single-writer wall. At c64 the gap
narrows (PB 21,125 vs ~14K) and PB's list p99 rises (26 ms vs ~8 ms), but on read RPS, credit where due.

**Takeaway:** if your workload is **write-heavy or mixed**, binocle is far ahead (throughput *and* tail);
if it's **read-dominated single-tenant**, PocketBase is a strong, simple choice.

---

## 4. Multi-tenancy — the structural reality (10K / 50K / 100K tenants)

![RAM to host N tenants](assets/competitive-3way/rss_vs_tenants.svg)

This is the one axis that is **not** a fair fight, and the chart is **log-scale** for a reason.

| Tenants | binocle (one process, SHARE_POOLS) | PocketBase (1 instance / tenant) |
|---|---|---|
| 10,000 | **~2.6 MiB**, 1 pool, 0 × 5xx · `measured` | ~128 GiB (10,000 × 13.1 MiB) · `modeled` |
| 50,000 | **~3 MiB** · `modeled` (flat) | ~640 GiB · `modeled` |
| 100,000 | **~3 MiB** · `modeled` (flat) | ~1.25 TiB · `modeled` (+ 100,000 processes/ports/SQLite files) |

binocle holds the **whole fleet in one process**: isolation is per-request (RLS re-stamps tenant + owner
every request), so a shared pool carries no tenant state → **RAM is decoupled from tenant count**
(measured flat across 200 → 24,887 tenants, `pools_open: 0` at rest — `footprint-live-24888-today.json`,
gate m46). At 100K that is **~440,000× less RAM** than PocketBase-as-N-instances.

PocketBase has **no native multi-tenancy**. Your only fully-isolated option is **one instance per tenant**
→ RAM grows linearly (the steep line). The alternative — one app with a manual `tenant_id` field in a
shared SQLite — keeps RAM flat-ish but funnels **every tenant's writes through one SQLite writer** (the
§3 insert wall, now × all tenants) and has **no engine-level isolation** (a rule bug = cross-tenant leak).
Either way, the dense-SaaS shape is binocle's, not PocketBase's.

> **Realism note.** binocle's 10K is measured and at-rest density is measured to 24,887 tenants; 50K/100K
> are `modeled` (the serve path is N-independent — RSS + pool count flat). A fully-measured 100K *load*
> p99 needs a quiet/isolated node (this box is k6/oha-CPU-bound); the harness
> [`scripts/scale/load-100k.sh`](../mini-baas-infra/scripts/scale/load-100k.sh) is ready for it.

---

## 5. Verdict

- **Choose binocle-nano** if you want PocketBase's single-binary simplicity but **6× smaller, ~70× faster
  cold start, ~7× write throughput with a ~45× tighter write tail, ~30× less RAM under load** — headless.
- **Choose binocle-one** if you want all of that **plus** PocketBase's feature set (accounts, OAuth2
  matrix, TOTP MFA, files, an embedded `/_/` admin UI) — for ~0 runtime cost over nano — *and* a no-rewrite
  path to a 10K–100K-tenant platform on the same SDK.
- **Choose PocketBase** if you want the most **mature single-app ecosystem** and a polished Svelte admin,
  and your workload is **read-dominated, single-tenant** — its read throughput is excellent and it's a
  lovely single-file tool. It is **not** a multi-tenant platform, and its **write tail collapses under
  concurrency**.

---

## 6. Reproduce

```bash
cd apps/baas/mini-baas-infra
make nano-build one-build                                  # the two binocle SKUs (scratch images)
DUR=8s BIG_N=100000 bash scripts/bench/nano-one-pb-load.sh # the 3-way single-node run → artifacts/nano-one-pb-load.json
# refresh the dataset from the fresh run, then render the charts:
make bench-compare DATA=/b/compare-3way-data.json OUT=/b/artifacts/bench/compare-3way
cp artifacts/bench/compare-3way/charts/*.svg ../wiki/assets/competitive-3way/   # tracked snapshot
```
The multi-tenant density numbers come from gate `m46-share-pools-isolation.sh` +
`artifacts/scale/footprint-live-24888-today.json`; the 100K *load* is `scripts/scale/load-100k.sh` on a
quiet node. See also the broader 9-contender report: [`competitive-benchmark-report.md`](./competitive-benchmark-report.md).
