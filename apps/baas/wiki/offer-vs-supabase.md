# Offer comparison — Grobase vs Supabase (2026)

> An **honest** plan-by-plan comparison for a developer or CTO choosing a backend. Grobase numbers
> are *measured* and cite [`config/packages/packages.json`](../mini-baas-infra/config/packages/packages.json)
> (the single source of truth for tiers), [`cost-analysis.md`](./cost-analysis.md) (retail), or a
> gate/artifact. **Every Supabase figure is *published* (as of June 2026) and sourced** — none is a
> measurement we ran. See also: [`competitive-matrix.md`](./competitive-matrix.md) (91-row feature
> map), [`competitive-benchmark-report.md`](./competitive-benchmark-report.md) (head-to-head perf),
> and [`offer-vs-mongodb-atlas.md`](./offer-vs-mongodb-atlas.md) (the third contender).

## TL;DR — who wins where

**Supabase** is the safer pick if you want a *managed* Postgres-native cloud with a polished Studio
dashboard, `pg_graphql` + `pgvector` first-class, a huge community, and SOC 2 / HIPAA available
**today**. **Grobase** is the pick if you want to **self-host one backend for any frontend** across
**up to 9 engines** (not just Postgres), bring your *own* database (`tenant_owned`), pack **24,888
tenants into ~2.9 MiB of data-plane RAM** (measured — gate `m46`), ship a **5 MB single binary** at
the low end, and pay **< $1/tenant amortized** at the high end — with an **in-stack OWASP WAF** as the
sole public listener that neither rival ships. Supabase is one Postgres project per app; Grobase is a
no-rewrite ladder from a 5 MB binary to a 10K-tenant platform on one codebase.

---

## How the offers line up

Supabase prices **per organization** (a Free org gets 2 projects; paid orgs add projects). Grobase
prices **per tier** (self-host infra cost → suggested retail). The mapping below pairs each Grobase
tier with its nearest Supabase plan by capability, not by exact feature identity.

| Grobase tier | Grobase price (retail¹) | Nearest Supabase plan | Supabase price (published²) | Why they pair |
|---|---|---|---|---|
| **nano** / **one** | Free / $5 (one: $5–9) | (no real equivalent) | — | Single 5 MB binary, embedded SQLite + auth. Supabase has no single-binary / self-host-floor shape. |
| **basic** | Free / $9 | **Supabase Free** | $0 / org | Lean CRUD backend; SQLite-first + Postgres. Maps to the entry experience. |
| **essential** | $25–39 | **Supabase Pro** | $25/mo / org (+$10 compute credit) | One full-feature product; both land at the ~$25 mark. |
| **pro** | $59–99 | **Supabase Pro → Team** | $25 → $599/mo | Multi-engine SaaS + realtime + analytics; spans Supabase's mid-to-team band. |
| **max** | $149–299 | **Supabase Team / Enterprise** | $599/mo → custom | Multi-tenant platform, every engine + capability, max-security, observability. |

¹ Grobase retail from [`cost-analysis.md`](./cost-analysis.md) §"Suggested retail"; infra cost is the
floor (nano ~$2/mo or <$1 idle; essential ~$13; pro ~$21 dedicated / <$1 amortized; max ~$41 /
<$1 amortized). ² Supabase prices **published June 2026** — see [Sources](#sources).

---

## What you get per dollar

Grobase column cites `packages.json` / a gate / an artifact. Supabase column is **published June 2026**.

| Dimension | Grobase (measured / packages.json) | Supabase (published June 2026²) |
|---|---|---|
| **Entry price** | nano **Free / $5**; basic **Free / $9** | Free **$0/org** (2 projects, pauses ~1wk idle) |
| **Mid price** | essential **$25–39**; pro **$59–99** | Pro **$25/mo/org** (incl. $10 compute credit) |
| **Top price** | max **$149–299** | Team **$599/mo**; Enterprise **custom** |
| **Database engines** | **1 → 9**: sqlite, postgresql, mysql, mariadb, mongodb, redis, cockroachdb, mssql, http (`packages.json` `engines`) | **Postgres only** (1 engine per project) |
| **Storage included** | self-host: your disk; Fly volume $0.15/GB (`cost-analysis.md`) | Free 1 GB; Pro 100 GB |
| **Auth / MAU** | unlimited self-host (gotrue + `binocle-one` accounts/OAuth/MFA); no MAU meter | Free 50,000 MAU; Pro 100,000 MAU |
| **Multi-tenancy** | **per-request RLS → SHARE_POOLS** packs 24,888 tenants @ 2.9 MiB / **0 standing pools** (gate `m46`, artifact below) | RLS *inside one Postgres project*; multi-tenant = your own design |
| **rps (per tenant)** | nano 50 · basic 100 · essential 200 · pro 400 · max 800 (`packages.json` `limits.rps`, derived from `bench-capacity`) | not a published per-plan rps; gated by compute size |
| **Isolation models** | **4 per mount** (shared_rls · schema-per-tenant · db-per-tenant · pool-per-tenant — gate `m46`) | 1 (one project = one DB) |
| **Realtime** | addon on pro/max (`packages.json` addons) — Rust event bus + IRC bridge | Free 200 concurrent / 2M msgs/mo; Pro scales up |
| **Functions** | addon on max (serverless runtime); functions DX gated `m56` | Free 500k edge-fn invocations/mo |
| **Object storage** | addon on max (MinIO/S3); storage DX gated `m95` | Free 1 GB / Pro 100 GB built-in |
| **Backups / PITR** | per-tenant backup/restore, flag `TENANT_BACKUP_ENABLED` (gate `m87`); PITR restore-to-timestamp gated `m99` | Pro daily backups + 7-day PITR option; Team 14-day retention |
| **Quota / metering** | per-tenant cumulative quota (`packages.json` `limits.quota`) + B1 metering (m74–m79) | per-plan included allowances + usage overage |
| **Compliance** | OWASP ASVS L1/L2 control map + SOC2-lite evidence ([`security-audit-asvs.md`](./security-audit-asvs.md)); **no third-party SOC2/HIPAA attestation yet** | **SOC 2 + ISO 27001 on Team**; HIPAA on Enterprise |
| **WAF** | **in-stack ModSecurity v3 + OWASP CRS** as sole public listener (`docker/services/waf`) | none in-stack |

---

## Where Grobase wins

- **Multi-engine + BYO-DB (`tenant_owned`).** Grobase serves **up to 9 engines** through one
  engine-agnostic data plane (`packages.json` `engines`: sqlite, postgresql, mysql, mariadb,
  mongodb, redis, cockroachdb, mssql, http) and lets a tenant **bring their own database**
  (`tenant_owned` mounts — [`migrate-from-supabase.md`](./migrate-from-supabase.md),
  [`competitive-matrix.md`](./competitive-matrix.md)). Supabase is Postgres-only, one DB per project.
- **Dense multi-tenancy (the moat).** Per-request RLS means `SHARE_POOLS` collapses every tenant
  onto **one** connection pool. **Measured: 24,888 tenants at 2.918 MiB data-plane RSS with 0
  standing pools** (gate [`m46-share-pools-isolation.sh`](../mini-baas-infra/scripts/verify/m46-share-pools-isolation.sh),
  artifact [`footprint-live-24888-today.json`](../mini-baas-infra/artifacts/scale/footprint-live-24888-today.json)).
  Pool count is **independent of tenant count** — Supabase has no equivalent density story.
- **4 isolation models per mount.** shared_rls, schema-per-tenant, db-per-tenant, pool-per-tenant —
  pick per mount (gate `m46`). Supabase gives you one (project = DB).
- **In-stack OWASP WAF.** ModSecurity v3 + OWASP CRS (`owasp/modsecurity-crs:4-nginx`) is the
  **sole public listener**; the data plane is server-to-server behind Kong
  ([`security-audit-asvs.md`](./security-audit-asvs.md), `docker/services/waf/Dockerfile`).
  **Neither Supabase nor Firebase ships an in-stack WAF** ([`competitive-matrix.md`](./competitive-matrix.md) row D5).
- **Single-binary nano / one.** A **5.16 MB** image / **~2.1 MiB** idle headless backend (nano), or
  **~2.2 MiB** with accounts + OAuth + MFA + files + admin UI (`binocle-one`, *our PocketBase*) —
  measured ([`cost-analysis.md`](./cost-analysis.md), [`nano-vs-pocketbase.md`](./nano-vs-pocketbase.md)).
  Supabase has no single-binary form.
- **No-rewrite grow path.** nano → basic → essential → pro → max is **one codebase, one SDK**, no
  rewrite (`packages.json` `_tenancy_guidance`). Supabase scaling means resizing a project's compute.
- **< $1/tenant amortized.** A single `pro` host (~$21/mo infra) across ~50 tenants ≈
  **$0.40–1.00/tenant/month**; marginal cost of tenant N+1 ≈ storage only ([`cost-analysis.md`](./cost-analysis.md) §3).

## Where Supabase wins (honest)

- **Mature Postgres-native ecosystem.** Decade of Postgres tooling, extensions, and migration
  patterns out of the box; you get real Postgres, not an abstraction.
- **Studio dashboard polish.** Supabase Studio (table editor, SQL editor, logs, auth UI) is far more
  mature than Grobase's tenant console.
- **`pg_graphql` + `pgvector` first-class.** GraphQL and vector search are native, supported, and
  documented. Grobase has GraphQL passthrough (gate `m59`) but it is younger.
- **Large community + managed-cloud maturity.** Huge community, broad docs, third-party tutorials,
  and a battle-tested hosted platform with years of operational history.
- **SOC 2 + ISO 27001 (Team) and HIPAA (Enterprise) available today.** Grobase ships an OWASP ASVS /
  SOC2-lite *control map* ([`security-audit-asvs.md`](./security-audit-asvs.md)) but **no third-party
  attestation yet** — if you need a signed SOC 2 report or a HIPAA BAA now, Supabase has it.

---

## Choose Supabase if … / Choose Grobase if …

> **Choose Supabase if** you want a managed, Postgres-native cloud you don't operate; you need a
> polished dashboard; `pg_graphql`/`pgvector` matter; you need a **signed SOC 2 / ISO 27001 / HIPAA**
> attestation today; or your team is happiest in the Postgres ecosystem and one DB per app is fine.

> **Choose Grobase if** you want to **self-host one backend for any frontend** across **many engines**
> (not just Postgres); you need to **bring your own database**; you're packing **many tenants into a
> tiny footprint** (24,888 @ 2.9 MiB measured); you want a **5 MB single binary** at the floor and a
> **no-rewrite path** to a platform; you want an **in-stack OWASP WAF** by default; or you need
> **< $1/tenant** economics and 4 isolation models per mount.

---

## Pricing reality (published June 2026)

All figures below are **published by Supabase** as of **June 2026** — not measured by us.

- **Free** — **$0 / org**: 2 projects, 500 MB DB, 5 GB egress, 50,000 MAU, 1 GB storage, 500k
  edge-function invocations/mo, 200 concurrent realtime, 2M realtime messages/mo. Projects **pause
  after ~1 week of inactivity**.
- **Pro** — **$25/mo per org**, *including a $10/mo compute credit*: 8 GB DB included, 100 GB storage,
  100,000 MAU, daily backups / optional 7-day PITR, email support. **Compute add-ons billed above the
  $10 credit**: Micro (covered by credit), **Small ~$15/mo**, **Medium ~$60/mo**, larger sizes scale
  up. So a busy Pro project is **$25 + compute** in practice, not a flat $25.
- **Team** — **$599/mo**: SOC 2 + ISO 27001, 14-day backup retention, priority support, dashboard SSO.
- **Enterprise** — **custom**: HIPAA, BYO-cloud, dedicated support, SLA.

For Grobase, retail is the *positioning* price; the *infra* floor is lower (nano <$1 idle, essential
~$13 dedicated, pro/max <$1/tenant amortized — [`cost-analysis.md`](./cost-analysis.md)).

---

## Sources

Supabase figures are published as of **June 2026**:

- <https://supabase.com/pricing>
- <https://uibakery.io/blog/supabase-pricing>
- <https://www.metacto.com/blogs/the-true-cost-of-supabase-a-comprehensive-guide-to-pricing-integration-and-maintenance>

Grobase figures: [`config/packages/packages.json`](../mini-baas-infra/config/packages/packages.json)
(tiers), [`cost-analysis.md`](./cost-analysis.md) (retail + infra), gate
[`m46-share-pools-isolation.sh`](../mini-baas-infra/scripts/verify/m46-share-pools-isolation.sh) +
artifact [`footprint-live-24888-today.json`](../mini-baas-infra/artifacts/scale/footprint-live-24888-today.json)
(density), [`security-audit-asvs.md`](./security-audit-asvs.md) (WAF + compliance posture).

Related: [`competitive-matrix.md`](./competitive-matrix.md) · [`competitive-benchmark-report.md`](./competitive-benchmark-report.md) · [`offer-vs-mongodb-atlas.md`](./offer-vs-mongodb-atlas.md)
