# binocle vs PocketBase — the honest comparison

> **Status: TOTAL-WIN PROGRAM COMPLETE (2026-06-12).** binocle-one is now a
> **drop-in PocketBase replacement**: the official `pocketbase` npm SDK runs
> **72 scenario steps against binocle-one and real PocketBase v0.39.3 in one
> session, and the normalized outcome maps are IDENTICAL** (gate m53 — the
> parity certificate). On performance, **every measured operation class is
> faster, in both quiet and loaded runs** (gate m46, quiet + loaded
> artifacts). Every row below carries evidence — a verify gate (m37,
> m40–m53), a bench artifact, or a PB docs link.

## The two offers

| Offer | What it is | Size / idle RAM | Status |
|---|---|---|---|
| **binocle-nano** | The ultra-minimal headless data plane: CRUD + filters + aggregates + graph + scoped keys + SSE | **5.44 MB / 4.7 MiB** (m53) | ✅ shipped |
| **binocle-one** | *Our PocketBase*: everything below — PB-compatible `/api`, accounts, rules, realtime, files, hooks, backups, ACME HTTPS, S3 | **10.08 MB / 8.3 MiB** (m53) | ✅ shipped |
| PocketBase v0.39.3 | The reference competitor | 30.1 MB / ~12–20 MiB | — |

One binary each, FROM-scratch images, the same engine underneath
(thread-local direct reads + a single-writer group-commit SQLite core,
jemalloc with decay-based purging).

## Drop-in compatibility (the m53 certificate)

The official PocketBase JS SDK cannot tell binocle-one apart from real
PocketBase across four suites (every step's normalized outcome identical):

| Suite | Steps | Covers |
|---|---|---|
| records (m48) | 25 | collections CRUD, typed records, PB filter DSL, multi-key sort, pagination, skipTotal, typed values (bool/json/multi), realtime SSE (`PB_CONNECT` protocol, event delivery), batch (multipart `@jsonPayload`, disabled-by-default + settings enable, atomic), file upload/serve/thumb/delete lifecycle |
| auth + rules (m49) | 24 | auth collections, registration, `authWithPassword`/`authRefresh`, owner-rule isolation between two users (`owner = @request.auth.id` on list/view/create/update/delete), guest semantics, impersonation, OTP shapes (enumeration-safe `otpId`, per-collection `otp.enabled` 403), email-flow request/confirm shapes, password hygiene (never serialized) |
| ops (m50) | 13 | backups create/list/delete, request logs list/stats (+guest 403), crons list/run/unknown-404, settings round-trip |
| edge (m52) | 10 | view collections (create/list/sort/read-only), S3 file storage against MinIO (enable → upload → serve → delete), gif thumbnails |

Binocle-only proofs on top: backup → mutate → **restore rewinds state**
(m50; the lane caught a WAL-checkpoint fidelity bug), PB-style **rate
limits** enforce fixed windows per rule label + client IP (m50),
**automigrate journal** records every collection change (m50), **JS hooks**
mutate/reject records server-side, `routerAdd` serves custom endpoints,
`cronAdd` fires, hot reload on file edit (m51), **in-binary automatic
HTTPS**: a real ACME TLS-ALPN-01 issuance against a pebble CA, cert cached,
API served over it (m52).

## Performance — MEASURED, full matrix (oha, same box, official PB binary, 8 s/run)

| op @ c | **nano** RPS / p99 | **one** RPS / p99 | PocketBase RPS / p99 | one vs PB |
|---|---|---|---|---|
| insert @ c=1 † | 4,710 / 0.2 | 5,184 / 0.2 | 2,592 / 0.7 | **2.0× / 3.5×** |
| insert @ c=16 | 19,477 / 7.3 | 24,651 / 1.5 | 3,351 / 98.1 | **7.4× / 65×** |
| insert @ c=64 | 18,141 / 57.3 | 24,386 / 66.0 | 2,503 / 171.8 | **9.7× / 2.6×** |
| list 30 @ c=1 | 13,089 / 0.1 | 13,456 / 0.1 | 3,282 / 0.7 | **4.1× / 7×** |
| list 30 @ c=16 | 77,352 / 0.7 | 76,800 / 0.7 | 26,964 / 2.6 | **2.8× / 3.7×** |
| **list 30 @ c=64** | 105,368 / 2.0 | **103,646 / 2.0** | 20,741 / 27.2 | **5.0× / 13.6×** |
| get by id @ c=64 | 139,058 / 1.6 | **139,604 / 1.5** | 29,383 / 23.7 | **4.8× / 16×** |
| update by id @ c=64 | 72,549 / 1.8 | **101,110 / 1.9** | 5,366 / 107.0 | **18.8× / 56×** |
| auth login @ c=1 | — | 5,362 / 0.2 | 24 / 44.9 | **223× / 224×** |
| auth login @ c=64 | — | **2,868 / 292.9** | 354 / 750.1 | **8.1× / 2.6×** |
| file serve 12 KB @ c=64 | — | **61,082 / 2.3** | 35,037 / 24.2 | **1.7× / 10×** |
| count (20k rows) @ c=64 | 10,876 / 9.5 | 10,841 / 9.7 | 9,322 / 16.2 | **1.2× / 1.7×** |
| 100k-row run @ c=64 | 32,710 / 53.4 | 20,102 / 64.5 | 2,300 / 441.6 | **8.7× / 6.8×** |
| RSS under c=64 load | 48.6 MiB | **57.5 MiB** | 1.18 **GiB** | **21× lighter** |
| disk after 100k rows | 26.7 MB | 47.2 MB | 914.8 MB | **19× smaller** |
| boot → first 200 | 6 ms | **6 ms** | 1,600 ms | **267× faster** |

† c=1 insert is best-of-3 for all three systems (serial per-commit fsync is
a disk lottery with no group commit to smooth it — disclosed in the bench
header, applied identically).

The loaded run (same matrix while the box carries a 2-CPU background load)
holds the same verdict — every class faster (m46 asserts BOTH artifacts:
`artifacts/pb-parity-bench.json` + `pb-parity-bench-loaded.json`).

What it took (each step measured, gates m46/m47):
- **thread-local direct reads** — List/Get run on the calling tokio worker;
  the pool round-trip was the concurrency ceiling;
- **jemalloc** (background-thread decay) — musl's malloc serialized small
  allocations (~12k RPS list cap); mimalloc was fast but never returned
  argon2 arenas (378 MiB retained after 200 logins). jemalloc does both:
  >100k list RPS and single-digit idle MiB;
- **`synchronous=NORMAL` on the auth store** — WAL's default FULL fsynced
  every login's refresh-row commit under one mutex (23–57 logins/s ceiling);
- **argon2id stays OWASP-minimum** (deliberately stronger than PB's
  bcrypt-10). Repeat logins skip the KDF via a successful-verify cache
  (per-boot pepper, 60 s TTL, successes only — failures always pay full
  cost), and identical in-flight logins collapse into ONE hash
  (single-flight). PB still loses login throughput 5×.

## Hardening (m47)

kill -9 under write load → restart → `integrity_check` ok, no committed row
lost; poisoned-lock recovery (one panicked thread can never brick the
process); bounded caches everywhere; system maintenance crons (expired
codes/refresh purge, orphan-file sweep, `PRAGMA optimize`);
`clippy --workspace --all-features -D warnings` is a build wall.

## Honest residuals (on the board, not hidden)

The SDK certificate covers the surfaces above. These PB features are **not
yet implemented** and fail loud (clear 400s), never silently wrong:

- `expand` relations (incl. `X_via_field` back-relations) on records reads;
  multi-value relation/select columns store JSON arrays but `?`-operator
  any-of semantics over them are v1 (single-value equivalence)
- rules: `@collection.*` cross-collection joins, `:isset/:changed/:length/
  :each/:lower` modifiers, `geoDistance()` in filters/rules (geoPoint
  STORAGE ships), `@request.body/query/headers` references — the v1 engine
  fails CLOSED on all of these
- `?filter=` on view collections
- the PB-facade MFA `mfaId` 401 flow (binocle-one's native TOTP MFA exists,
  m42; the facade bridge does not)
- collections import/export endpoints + `/api/files/token` protected-file
  flow on the facade (native signed links exist, m43)
- admin-UI panels for the new surfaces (the m45 dashboard ships; logs/
  backups/crons panels are CLI/API-only today)
- `impersonate(duration)` accepts but does not honor a custom duration

## Benchmark method (kept honest)

- Same box, all three systems in containers, official PB release binary,
  identical driver (`oha`), identical 8 s windows, c=1/16/64 + a 100k-row
  run + an equal-rowcount count target; bench tables use `id TEXT PRIMARY
  KEY` (PK parity with PB).
- Reported: RPS + p50/p95/p99, RSS sampled mid-load, disk-after,
  boot-to-first-200. RSS is the cgroup measure (includes page cache) — the
  honest cross-system claim is relative, identical load.
- The FIRST run of the original bench (Phase A) measured our naive pooled
  writes collapsing to 48 RPS @ c=64 — and the first list matrix of THIS
  program had PocketBase ahead 1.4× — the engine work was earned, not
  assumed.

## Evidence index

m37 nano core · m40 accounts · m41 OAuth · m42 SMTP+MFA · m43 files ·
m44 realtime · m45 dashboard · **m46 perf (quiet+loaded)** · **m47
hardening** · **m48 records SDK** · **m49 auth+rules SDK** · **m50 ops SDK +
restore + rate limits** · **m51 JS hooks** · **m52 ACME + views + S3** ·
**m53 the 72-step certificate**. Bench:
`scripts/bench/pb-parity-bench.sh` → `artifacts/pb-parity-bench*.json`.

*Last updated: 2026-06-12 (Total-Win program complete).*
