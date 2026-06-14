# Grobase Managed Cloud — Service Level Agreement (DRAFT)

> **Status: DRAFT — not a binding contract.** This document is a *template* for a
> commercial SLA. Sections marked **PROVEN** are backed today by a measured artifact
> and a reproducing gate (cited inline). Sections marked **PENDING measurement** are
> structurally complete but carry **no committed number**, because the number does not
> yet exist as a measurement. **An SLA you cannot measure is dishonest** — so this draft
> refuses to print an availability %, an RTO, or an RPO we have not run. The PENDING atom
> (the exact run that would unblock the number) is named in each case.
>
> Before this becomes a customer-facing contract it requires: (a) the PENDING measurements
> below, and (b) legal review — the remedy/credit and liability language here is a
> placeholder template, **not** lawyer-reviewed.
>
> Discipline (binding): *measured, not claimed*; *honest, not certified*; flag-gated
> features stay OFF in the committed baseline (byte-parity). See
> `apps/baas/.claude/CLAUDE.md` §2.1.

Last reviewed: 2026-06-15 · Applies to: **Grobase Managed Cloud** (the hosted product).
The OSS self-host edition carries **no SLA** — you operate it; these commitments are for
the managed offering only.

---

## 1. What we will and will not commit to today

We split every clause into two buckets and never blur them:

| Bucket | Meaning | Where it appears |
|---|---|---|
| **PROVEN** | A measured artifact + a green gate back the number. We commit to it. | §3 (Performance), §4 (Density), §5 (Footprint) |
| **PENDING measurement** | The clause is real and the structure is here, but the number is not yet measured. **We commit to nothing until the named run exists.** | §6 (Availability), §7 (RTO/RPO/DR) |

This boundary is the whole point of the document. A latency p95 we have measured under
load is a promise we can keep and verify. An uptime % we have **not** measured (no
real-infra failover run exists; the 100K-tenant load figure is *projected*, not run)
would be a number invented to look good in a sales deck — so it stays PENDING.

---

## 2. Tier coverage (which plan gets which SLA)

SLA strength is keyed to the service tier. Tiers are defined once in
`config/packages/packages.json` (the single source of truth; the control plane embeds a
byte-identical copy, asserted by gate m28). The performance ceilings below are the
*advertised* per-request limits from that file — themselves derived from measurement
(`artifacts/bench/capacity-essential.json`: a single mount sustains ~400 rps of reads at
p95 < 2 ms before the connection-pool cliff; advertised rps = floor(ceiling × fair_share × 0.5)).

| Tier (packages.json) | Advertised rps / burst | Performance SLA (§3) | Availability SLA (§6) | DR / backup (§7) | Support target |
|---|---|---|---|---|---|
| **nano** (alias `free`) | 50 / 100 | best-effort, **no SLA** | none | none (single-binary, self-managed data) | community |
| **basic** | 100 / 200 | best-effort, **no SLA** | none | best-effort | community |
| **essential** | 200 / 400 | **PROVEN** p95 read target (§3) | PENDING — *standard* tier on the SLO ladder | PENDING (RPO/RTO templates, §7) | business-hours |
| **pro** | 400 / 800 | **PROVEN** p95 read target (§3) | PENDING — *standard* tier | PENDING (§7) | business-hours |
| **max** (alias `enterprise`) | 800 / 1600 | **PROVEN** p95 read target (§3) | PENDING — *premium* tier (highest target once measured) | PENDING (§7, premium RPO/RTO) | priority / named contact |

> The two availability "ladder" labels (*standard* / *premium*) are committed structure;
> the **numbers attached to them remain PENDING** until §6 is measured. We do not ship a
> tier with a printed uptime number ahead of the run that proves it.

---

## 3. Performance SLA — **PROVEN**

These are committed for **essential / pro / max** managed tenants. The numbers come from a
load run, not a brochure.

| Clause | Committed target | Measured value (artifact) |
|---|---|---|
| **Read latency (p50)** | ≤ 5 ms (gateway read, warm) | **1.63 ms** measured — `artifacts/bench/grobase-vs-supabase.json` (n=60, same `GET /rest/v1` against both stacks) |
| **Read latency (p95)** | ≤ 10 ms (gateway read, warm) | **2.20 ms** measured — `artifacts/bench/grobase-vs-supabase.json`; corroborated by the essential CRUD `list` op p95 **2.19 ms** in `artifacts/bench/load-essential-crud.json` (median of 3×60 s runs @ 20 rps, 0 server errors) |
| **CRUD error rate** | ≤ 0.5 % over a rolling 5 min window | **0.00 %** server errors across all three essential CRUD runs — `artifacts/bench/load-essential-crud.json` (`server_errors: 0`, `err_pct: 0`) |
| **Sustained read capacity (single mount)** | per-tier advertised rps (table §2) | single mount sustains **400 rps** at p95 < 2 ms before the pool cliff — `artifacts/bench/capacity-essential.json` (`max_sustained_rps: 400`, `slo_p95_ms: 50`) |

**Honest carve-out — the write tail.** The committed latency targets above are for the
**read** path. The **write** path has a measured tail we will not hide: essential CRUD
`insert` p99 reaches **~56 ms** and `delete` p99 **~69 ms** in
`artifacts/bench/load-essential-crud.json` (outbox/relay tail, tracked as D-write-tail).
Until a write-path SLO is separately measured under sustained write load, **writes are
explicitly excluded from the latency commitment** and served best-effort. We name the
enemy rather than averaging it away.

Reproduce: `make -C apps/baas/mini-baas-infra bench-load` and `bench-capacity`.

---

## 4. Multi-tenant isolation & density — **PROVEN**

Relevant to an SLA because it bounds the *noisy-neighbour* failure mode: one tenant's load
cannot exhaust another's resources, by construction.

| Clause | Committed property | Proof |
|---|---|---|
| **Per-request owner-scoping / RLS** | Tenant data isolation is enforced per request, not by pool state | gate **m46** — `scripts/verify/m46-share-pools-isolation.sh` (SHARE_POOLS=1 → isolation holds + pools collapse; =0 → byte-identical) |
| **Pool count independent of tenant count** | 10K tenants collapse to **1 shared pool**, **0× 5xx** under load | gate **m46**; `artifacts/bench/multitenant-10000-sharepools.json` (`server_errors: 0`, 9,775 tenants, zipf) |
| **At-rest density** | A ~25K-tenant fleet imposes no standing memory cost beyond the binary | **24,887 live tenants** held by a **2.6 MiB** data plane with **0 standing pools** — `artifacts/scale/footprint-live-24887.json` |

> **Honest note on the 100K headline:** any figure above the measured ~25K at-rest /
> 10K-under-load fleet is **PROJECTED, not run**. We do not state a 100K SLA. See §6.

---

## 5. Footprint moat — **PROVEN** (informational, not a runtime SLA clause)

Not an availability promise, but a measured, contractually-honest efficiency statement.

| Clause | Measured value (artifact) |
|---|---|
| **Footprint vs Supabase (same box)** | Grobase `essential` **821.7 MiB** vs Supabase **2884 MiB** = **3.5× lighter** (lean `basic` **309.8 MiB** = 9.3× lighter) — gate **m32-footprint.sh** / `make bench-footprint`; per-service RSS summed in `artifacts/footprint-essential.json` / `artifacts/footprint-basic.json`; Supabase 2884 MiB RSS independently captured in `artifacts/bench/grobase-vs-supabase.json` + `artifacts/bench/supabase-footprint-breakdown.txt` (per-container RSS). |
| **Per-edition RAM (running)** | essential **821.7 MiB**, pro **1188.4 MiB**, max **3634.0 MiB** — `artifacts/footprint-essential.json` / `footprint-pro.json` / `footprint-max.json` |
| **Nano single-binary idle** | ~2.0 MiB idle / ~5.1 MB image — `artifacts/nano-vs-pocketbase.json` |

---

## 6. Availability SLO — **PENDING measurement (no number committed)**

> **We have NOT measured an availability percentage. None is printed here.** The
> structure below is a template; every numeric field is a blank to be filled *only after*
> the named run exists. Publishing 99.9% today would violate "measured, not claimed."

### 6.1 Definition template (structure only)

- **Monthly Uptime Percentage** = (Total minutes in month − Downtime minutes) ÷ Total
  minutes in month × 100, where *Downtime* = a contiguous period in which the managed
  control-plane health endpoint and the data-plane read path both fail external probes.
- **Excluded** from Downtime: scheduled maintenance (announced ≥ 72 h ahead), customer
  misconfiguration, force majeure, and abuse-suspension (gate m120 spend/suspend).

### 6.2 The numbers (all PENDING)

| Tier | Target Monthly Uptime % | Status |
|---|---|---|
| essential / pro (*standard*) | **PENDING measurement** — requires a **real-infra failover run (`m-failover`, UNBUILT)** + a sustained-availability soak | no number committed |
| max (*premium*) | **PENDING measurement** — same blocker, premium target | no number committed |

### 6.3 Why it is PENDING (the missing atoms, named)

1. **No failover gate exists.** There is no `m-failover` script today
   (`ls scripts/verify/` confirms: no failover/HA/SLO/uptime gate). Read-replica work
   (gate **m122**) proves the **routing decision only** and *explicitly* excludes "real
   streaming replication, replication-lag SLOs, or failover" (see the m122 header). So we
   cannot yet measure recovery from a node loss.
2. **The 100K-tenant figure is projected, not run.** A real availability number under
   target scale needs a **100K load run on a quiet node** (the current 10K-under-load /
   ~25K-at-rest fleet, §4, is the proven envelope).
3. **Service-credit table is therefore blank.** A credit schedule (e.g. < X% → Y% credit)
   is meaningless without a committed target; it is intentionally omitted until §6.2 is
   filled.

### 6.4 Unblocking atom (exact)

```
# Build an HA failover gate (m-failover, UNBUILT) that:
#   1. brings up >=2 data-plane replicas behind the shared global bucket (m51 proves
#      the bucket is already shared across replicas — scripts/verify/m51-multinode.sh),
#   2. kills the primary mid-load, measures recovery time + dropped requests,
#   3. runs a sustained soak to compute a real Monthly Uptime %.
# THEN run a 100K-tenant load on a quiet node and record artifacts/scale/.
# ONLY THEN fill §6.2.  (This script PREPARES nothing it would run automatically —
#  the failover/load run is a human-triggered, irreversible-class operation.)
```

---

## 7. Disaster Recovery — RTO / RPO — **PENDING measurement (no number committed)**

> The backup/restore **mechanism is proven**; the **time/loss objectives are not measured**.
> We commit the mechanism, not a number, until a real-infra DR drill is run.

### 7.1 What is PROVEN (mechanism, not objective)

| Property | Proof |
|---|---|
| Logical backup/restore round-trips with a verified checksum | gate **m47** — `scripts/verify/m47-backup-restore.sh` (`pg_dump -Fc` → recreate → `pg_restore`; row count + md5 checksum must match the seed). The scheduled `pg-backup → MinIO` path reuses the exact same mechanics. |
| Per-tenant logical backup/restore exists | Track-B B6, gate **m87** (`TENANT_BACKUP_ENABLED`, migration `042_tenant_backups.sql`) — flag-gated OFF in the committed baseline |
| Per-tenant data export | gate **m109** — `scripts/verify/m109-tenant-export.sh` |
| Read-replica routing decision (NOT replication) | gate **m122** — routing mechanism only; real streaming replication is out of scope per the gate's own header |

### 7.2 RTO (Recovery Time Objective) — PENDING

| Tier | Target RTO | Status |
|---|---|---|
| essential / pro | **PENDING measurement — requires a real-infra DR drill** (timed restore of a production-sized dataset from the `pg-backup → MinIO` path onto a fresh node) | no number committed |
| max (premium) | **PENDING measurement** — same blocker, premium target | no number committed |

> We have a *checksum-correct restore mechanism* (m47) but **no measured wall-clock
> restore time** at production data size on managed infra. Until that drill is timed, RTO
> is blank. Quoting "RTO 1 h" off an un-timed mechanism would be invented.

### 7.3 RPO (Recovery Point Objective) — PENDING

| Tier | Target RPO | Status |
|---|---|---|
| essential / pro | **PENDING measurement — requires a measured backup cadence** (scheduled `pg-backup` interval observed in production + the max data-loss window proven by a point-in-time restore drill) | no number committed |
| max (premium) | **PENDING measurement** — needs WAL/PITR, which depends on real streaming replication (out of scope as of m122) | no number committed |

### 7.4 Unblocking atoms (exact)

```
# RTO: time a full restore on managed infra at production data size:
#   pg_restore from the pg-backup MinIO artifact onto a fresh node, wall-clock the
#   recovery, run on >=1 representative tenant fleet (cross-ref §4 density numbers).
# RPO: (a) record the scheduled pg-backup cadence in production; (b) for premium RPO,
#   build real streaming replication / PITR (m122 today is routing-only) and prove the
#   max data-loss window with a point-in-time restore drill.
# ONLY THEN fill §7.2 / §7.3.
```

---

## 8. How each commitment is proven (clause → gate / artifact)

The auditable spine of this draft. **Every PROVEN row cites a real, reproducible source;
every PENDING row names the run that does not yet exist.**

| § | Clause | Status | Gate / Artifact | Reproduce |
|---|---|---|---|---|
| 3 | Read p50 ≤ 5 ms (1.63 ms measured) | PROVEN | `artifacts/bench/grobase-vs-supabase.json` | `make -C apps/baas/mini-baas-infra bench-load` |
| 3 | Read p95 ≤ 10 ms (2.20 / 2.19 ms measured) | PROVEN | `grobase-vs-supabase.json` · `load-essential-crud.json` | `bench-load` |
| 3 | CRUD error rate ≤ 0.5 % (0.00 % measured) | PROVEN | `artifacts/bench/load-essential-crud.json` | `bench-load` |
| 3 | Single-mount read capacity 400 rps | PROVEN | `artifacts/bench/capacity-essential.json` | `make ... bench-capacity` |
| 3 | Write-path latency | EXCLUDED (honest carve-out) | insert/delete p99 in `load-essential-crud.json` | `bench-load` |
| 4 | Per-request isolation / RLS | PROVEN | gate **m46** `m46-share-pools-isolation.sh` | `bash scripts/verify/m46-share-pools-isolation.sh` |
| 4 | 10K tenants → 1 pool, 0× 5xx | PROVEN | gate **m46** · `multitenant-10000-sharepools.json` | m46 |
| 4 | 24,887 tenants @ 2.6 MiB at rest | PROVEN | `artifacts/scale/footprint-live-24887.json` | live probe (see artifact `_comment`) |
| 5 | Footprint 821.7 MiB (essential) / 309.8 MiB (basic) vs Supabase 2884 MiB | PROVEN | gate **m32-footprint.sh** · `artifacts/footprint-essential.json` · `artifacts/footprint-basic.json` · `grobase-vs-supabase.json` · `supabase-footprint-breakdown.txt` | `make bench-footprint` |
| 6 | Availability / Monthly Uptime % | **PENDING** | — (no failover/SLO gate exists) | requires `m-failover` (UNBUILT) + 100K quiet-node run |
| 7.1 | Backup/restore round-trip mechanism | PROVEN | gate **m47** `m47-backup-restore.sh`; B6 gate **m87**; export gate **m109** | `bash scripts/verify/m47-backup-restore.sh` |
| 7.2 | RTO | **PENDING** | mechanism only (m47) — no timed drill | requires real-infra timed restore |
| 7.3 | RPO | **PENDING** | routing only (m122), no streaming replication | requires measured backup cadence / PITR |

---

## 9. Maintenance, support response, and remedies (TEMPLATE — needs legal review)

- **Scheduled maintenance:** announced ≥ 72 h in advance; excluded from §6 Downtime.
- **Support response targets** (operational, not contractual until reviewed): nano/basic =
  community; essential/pro = next business day; max = priority / named contact.
- **Service credits:** **TEMPLATE — intentionally blank.** A credit schedule cannot be
  written before §6 commits a target (see §6.3). Sample structure to be completed by legal
  once §6 is measured:

  | Monthly Uptime below target | Credit (% of monthly fee) |
  |---|---|
  | PENDING | PENDING |

- **Liability / warranty / governing law:** **TEMPLATE — placeholder, requires a lawyer.**
  Nothing in this draft is a legal commitment.

---

## 10. Honesty ledger (what this draft deliberately does NOT claim)

1. **No availability % is printed anywhere.** Not 99.9, not 99.95 — none, because none is
   measured (§6).
2. **No RTO/RPO number is printed.** The restore *mechanism* is proven (m47); the *time* and
   *loss window* are not (§7).
3. **The 100K-tenant figure is projected, not run** — the committed density envelope is the
   measured ~25K-at-rest / 10K-under-load fleet (§4).
4. **m122 is routing, not replication** — we do not claim real streaming replication or
   replication-lag SLOs.
5. **SOC2 posture** (gate **m108**, SOC2-lite) is *"evidence collected, audit-ready,"*
   **never "SOC2 certified."**
6. **Legal/remedy language is a template** needing a lawyer; nothing here binds.

When §6 and §7 are measured (their unblocking atoms run), promote the PENDING rows to
PROVEN with their artifacts and re-date the document.
