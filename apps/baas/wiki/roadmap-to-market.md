# Roadmap to Market

> Source: 6-agent code audit, 2026-06-13. Where older wiki docs (06/07) disagree, the code wins.

The executable, phased plan to take Grobase from **shipped v1 PocketBase-competitor** to
**marketable vs Supabase/Firebase** as both **OSS self-host** and **managed cloud**.

This doc is the *plan*. Its two companions are the *evidence*:

- **[competitive-matrix.md](competitive-matrix.md)** — the 91-row capability matrix vs Supabase/Firebase.
  Every gap number (#1..#91) referenced below resolves to a row there.
- **[marketability-readiness.md](marketability-readiness.md)** — the four acceptance bars (BAR 1–4)
  and the gates that close them.

## Implementation log — 2026-06-13

Work executed this session (verified):

- **P0.3 secret-scan gate — DONE.** Added a blocking **gitleaks** job to
  `.github/workflows/mini-baas-security.yml` (wired into `security-gate`) +
  populated `mini-baas-infra/.gitleaks.toml`; validated locally (`no leaks
  found`, exit 0). Note: a blocking **TruffleHog** secret gate already existed —
  gitleaks is complementary (regex/entropy over the working tree). Confirmed the
  old "committed ANON_KEY" residual was a **false positive** (`.env` gitignored +
  never tracked; key runtime-generated).
- **P0.4 doc-drift — DONE** (essential tier ~660 MiB/13 svc reconciled across
  service-tiers.md / offer-sheet-v2.md; storage-router README rewritten to match
  the real API).
- **A1 Storage DX — DONE & live-verified.** Fixed a real bug (presign 404'd
  through Kong — `strip_path:true` stripped the whole prefix); moved storage-router
  to full-path controllers (`@Controller('storage/v1')`) + Kong `strip_path:false`.
  Added `upload`/`download` (proxied, owner-scoped), `list`, `delete`,
  `createBucket`/`listBuckets`; SDK gained Supabase-shaped `storage.from(bucket)`
  (`upload`/`download`/`list`/`remove`/`createSignedUrl`) + `createBucket`/
  `listBuckets` (19 SDK tests green). **Security hardening:** Kong `pre-function`
  now **clears** client `X-User-*` before setting them from the verified JWT
  (closed an anon-path impersonation vector); storage-router runs `compat`
  identity mode. E2e through Kong verified: upload/list/download (incl. nested)
  + cross-user isolation (404) + forged-header rejection (401). **Open item:**
  fine-grained ABAC (`bucket:read/write`) is still **not** wired — owner-prefix is
  the only isolation today (the README's ABAC claims were aspirational).
- **P0.2 vs-Supabase benchmark — harness fixed, clean run deferred.** Fixed three
  harness bugs: seed `bench_items` (stock Supabase has none → the read probe was
  timing 404s); narrow the footprint grep to supabase-only (the old
  `kong|realtime|gotrue` alternation also matched our containers); remap Supabase
  ports (kong→8100, analytics→4500, db→5532) to dodge the local dev HTTPS proxy on
  8000/4000. Supabase booted partially (db/vector/imgproxy healthy; ~13 containers
  created) but a clean **co-resident** measurement did not complete — Supabase's 13
  containers on top of our full 32-container stack is too heavy for this box, and
  Docker was taken down for a disk migration mid-run. Next step: the **sequential**
  run the harness was designed for (our stack down, Supabase alone). Expectation
  unchanged: Supabase self-host ≈ 13 containers / multiple GB (its docs recommend
  ~4 GB) vs our essential ~660 MiB / 13 svc.

Supporting context (read the code, then these):
[grobase-master-plan.md](grobase-master-plan.md) ·
[product-plan/06-saas-multitenancy-quotas-billing.md](product-plan/06-saas-multitenancy-quotas-billing.md) ·
[product-plan/09-100k-tenant-path.md](product-plan/09-100k-tenant-path.md) ·
[security-audit.md](security-audit.md) ·
[cost-analysis.md](cost-analysis.md) ·
[offer-sheet-v2.md](offer-sheet-v2.md) ·
[nano-vs-pocketbase.md](nano-vs-pocketbase.md)

Status legend (consistent with the matrix): **PARITY+** at/above competitor · **PARITY** · **PARTIAL** ·
**GAP** · **N/A**. Glyphs: `[v]` have it · `[~]` partial · `[x]` missing · `[+]` differentiator nobody else ships.

---

## 1. The decision block (what was approved)

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | **Benchmark both competitors, lead with our edge.** | The vs-Supabase harness exists but has *never been run*; numbers are cheap and unblock the scale-SLO claim (BAR 2). Marketing leads with the four things neither competitor does (below), then reaches credible parity on the rest. |
| D2 | **Ship OSS self-host FIRST, then managed cloud.** | OSS is mostly an exercise in *closing DX gaps on already-built planes* (storage, functions, SDK). Cloud is the largest net-new build (metering→billing→self-service) and can lag without blocking adoption. Self-host is a `[+]` vs Firebase today. |
| D3 | **Cloud billing = full metered + Stripe, staged meter→enforce→bill.** | Quotas are *built but `PACKAGE_ENFORCEMENT` defaults OFF*; there is zero usage metering and zero billing. Staging (measure silently → enforce → charge) de-risks the #1 managed-cloud gap. |
| D4 | **Security = audit-ready posture (OWASP ASVS / SOC2-lite + CI gates); formal SOC2 deferred.** | Baseline is strong (in-stack WAF `[+]`, audit fixes landed, supply-chain locked) but open residuals remain and there is no compliance mapping. Formal SOC2 Type 2 is a paid, calendar-bound process — defer, but reach the posture that makes it a checklist later. |

**Positioning (lead with differentiation, the four `[+]` columns neither competitor matches):**
(a) multi-engine / bring-your-own-database; (b) thousands of tenants on shared infra (dense multi-tenancy);
(c) engine-agnostic uniform API across heterogeneous engines; (d) per-tenant cost efficiency at idle;
(e) in-stack OWASP WAF. Tiny footprint (nano 5.16 MB, essential ~660 MiB) reinforces (d).

---

## 2. Sequencing overview

```
        ┌─────────── PHASE 0 (days) ───────────┐
        │ docs · vs-Supabase benchmark RUN      │
        │ security quick-wins · doc-drift fix   │
        └───────────────────┬───────────────────┘
                            │
        ┌───────────────────▼───────────────────────────────────────┐
        │ TRACK A — OSS self-host launch (ships first)               │
        │ A1 storage DX → A2 functions DX → A3 SDK+OpenAPI →         │
        │ A4 multi-lang SDKs → A5 GraphQL+realtime → A6 security     │
        │ (LAUNCH GATE) → A7 packaging+docs                          │
        └───────────────────┬───────────────────────────────────────┘
                            │
                    ★ OSS LAUNCH ★
                            │
        ┌───────────────────┴───────────────────────────────────────┐
        │                                                            │
┌───────▼─────────────────────────┐   ┌──────────────────▼─────────┐
│ TRACK B — Managed cloud          │   │ TRACK C — Scale & HA       │
│ B1 metering → B2 enforce →       │   │ C1 scale-out+supavisor →   │
│ B3 Stripe billing →              │   │ C2 prod Helm →             │
│ B4 tenant self-service →         │   │ C3 multi-region/blue-green │
│ B5 per-tenant observability →    │   │ C4 100K re-run → SLO       │
│ B6 per-tenant backup/restore     │   │                            │
└──────────────────────────────────┘   └────────────────────────────┘
        │  (B and C run in parallel; both must land for cloud)
        └───────────────────┬───────────────────────────────────────┘
                            │
                    ★ CLOUD LAUNCH + GTM ★
```

**Two launch milestones:**

- **★ OSS LAUNCH** — gated by **A6** (security audit-ready posture). Self-host story is complete:
  full storage/functions/SDK DX, multi-language clients, GraphQL+realtime parity, migrate-from
  guides. This is what a stranger `git clone`s and runs.
- **★ CLOUD LAUNCH + GTM** — gated by **B (full)** *and* **C (full)**. A stranger signs up → gets a
  project + API key → runs CRUD/realtime → sees usage → is billed; backed by a published, load-tested
  SLO and a production deploy topology. GTM bundle: pricing ([offer-sheet-v2.md](offer-sheet-v2.md) +
  [cost-analysis.md](cost-analysis.md)), signup funnel, legal (ToS/privacy/DPA), SLA, status page.

---

## 3. Phase 0 — Foundations (days, not weeks)

Cheap, high-leverage work that unblocks everything else. None of this is net-new product surface.

| Item | What | Why (gap / bar) | Key files / anchors | Exit gate |
|------|------|-----------------|---------------------|-----------|
| P0.1 | Author the 3 wiki docs (this one + matrix + readiness). | Establishes the gap source of truth and acceptance gates that the whole roadmap references. | `wiki/competitive-matrix.md`, `wiki/marketability-readiness.md`, `wiki/roadmap-to-market.md` | All three exist, cross-link each other, glyphs/legend consistent. |
| P0.2 | **Run the vs-Supabase benchmark.** Harness exists but has never executed; produce real p50/p95/p99 + RPS for both competitors and Grobase. | Closes the **scale-evidence gap**; directly unblocks **BAR 2** (proven scale SLO). Cheapest single win in the program — numbers turn "projected" into "measured". | `grobase-vs-supabase.sh` (placeholders in [grobase-master-plan.md](grobase-master-plan.md)); footprint budgets per [product-plan/09](product-plan/09-100k-tenant-path.md) | **m54** vs-Supabase numbers published (p50/p95/p99 + RPS, 3-engine insert + list); footprint reconciled against the already-shipped **m32** footprint gate. |
| P0.3 | Security quick-wins: add a **blocking CI secret-scan gate** (gitleaks); verify `.env` stays gitignored. **Correction:** `.env`/`.env.local` are gitignored and were never git-tracked, and `ANON_KEY` is runtime-generated from `JWT_SECRET` — there is **no committed secret** (the 07-report claim is wrong). The substantive follow-up is per-deployment keys + RS256 (→ A6). | Prevents any future credential commit at near-zero cost; corrects an inaccurate BAR 3 residual. | `scripts/generate-env.sh`, `.gitleaks.toml`, CI workflow | gitleaks CI job is **blocking** and green; `git ls-files` shows no tracked `.env`. |
| P0.4 | Reconcile doc drift: essential tier is **~660 MiB / 13 svc** (post-cutover, commit `4325a24`); the **storage-router README advertises a `.bucket().signPut()` SDK API that does not exist**. Also fixes [service-tiers.md](service-tiers.md), [offer-sheet-v2.md](offer-sheet-v2.md), and the storage-router README `signPut()` overclaim (being done in parallel). | Honesty bar — older docs (06/07), the stale tier docs, and the stale README overclaim. Per house style, the code wins. Every essential-tier mention must read **~660 MiB / 13 svc**. | [service-tiers.md](service-tiers.md), [offer-sheet-v2.md](offer-sheet-v2.md), `docker/services/storage-router/README.md`, [product-plan/06](product-plan/06-saas-multitenancy-quotas-billing.md), [product-plan/07-scale-ha-helm-deployment.md](product-plan/07-scale-ha-helm-deployment.md) | Tier numbers read **~660 MiB / 13 svc** everywhere; stale storage README `signPut()` claim removed/flagged as "planned (A1)". |

---

## 4. Track A — OSS self-host launch (ships first)

Each item closes table-stakes DX gaps on planes that **already exist in code**. The theme: the engines
work; the *developer experience and SDK surface* lag. Order is dependency-driven.

### A1 — Storage DX

- **What:** Promote storage from presign-only to a full SDK. Add `upload` / `download` / `list` /
  `createBucket` / `signedUrl` helpers, bucket policies (ABAC), and on-the-fly image transforms.
  Add a payload-proxy mode to `storage-router` so the SDK can stream bytes, not just hand back URLs.
- **Why:** Closes matrix **#33 (object storage), #34 (access rules on files), #35 (signed URLs already
  PARTIAL), #36 (image transforms), #38 (resumable)** → contributes to **BAR 1**. Today
  `sdk/src/domains/storage.ts` exposes **only `presign()`** — verified; the README's `signPut()` is
  vapor (P0.4).
- **Key files / anchors:** `src/apps/storage-router` (presign + new proxy/transform paths),
  `sdk/src/domains/storage.ts` (presign-only today → full surface), MinIO config.
- **Exit gate:** **m55** storage-DX e2e — SDK round-trips upload→list→download→signedUrl through
  ABAC bucket policy on owner-prefixed keys; transform endpoint returns resized variant; resumable
  (TUS or chunked) proven for a large object.

### A2 — Functions DX

- **What:** Take the Deno worker-per-invocation runtime from HTTP-invoke-only to a real serverless
  product: **DB/event triggers**, **cron/scheduling**, **function secrets**, a **`baas` CLI deploy +
  local-dev** path, a **warm pool**, and **cgroup CPU/RAM caps**. Move from per-USER to per-tenant
  namespacing. Also wire two auth/messaging integrations that ride this plane: **SMS/Phone OTP
  provider** (matrix **#15**, P1 — no provider wired today) and **production Email deliverability /
  SMTP provider** (matrix **email-deliverability** row — gotrue + Mailpit are dev-only today; no prod
  SMTP wired).
- **Why:** Closes matrix **#39 (serverless — currently PARTIAL), #40 (DB/event triggers), #41
  (cron), #42 (secrets), #15 (SMS/Phone OTP), and the email-deliverability / SMTP-provider row**, plus
  the DX half of **#59 (CLI)** → **BAR 1**. Supabase Edge Functions (also Deno) and Firebase ship all
  of this, plus SMS OTP and prod SMTP.
- **Webhooks / event-delivery (SHIPPED `[~]`, document here):** the matrix **webhooks /
  event-delivery** row is already shipped — `sdk/src/domains/webhooks.ts` + the webhook-dispatcher
  deliver events. It is **admin-only / IP-restricted with no browser self-serve**; A2 owns *writing up*
  the retry/backoff + HMAC-signing story and noting the self-serve gap (a B4 self-service follow-on),
  not re-building it.
- **Key files / anchors:** `docker/services/functions-runtime/src/server.ts` (HTTP-invoke only, 5s
  timeout, env disabled, no warm pool, no cgroup), Kong routing, the realtime/CDC plane for trigger
  fan-in, `sdk/src/domains/webhooks.ts` + webhook-dispatcher (shipped), the `baas` CLI (new — see A7),
  gotrue SMS/SMTP provider config (`SMTP_*`, SMS provider env), Mailpit (dev sink).
- **Exit gate:** **m56** functions-DX e2e — a deployed function fires on a DB-event trigger and on a
  cron schedule, reads a function secret, runs inside enforced cgroup limits, and was deployed via
  `baas functions deploy`; warm-pool cold-start measured; **a Phone-OTP login round-trips through a
  configured SMS provider** and **a transactional email delivers through a configured prod SMTP
  provider** (Mailpit fallback for dev). (Operational hardening of the SMTP/SMS posture is re-checked
  under A6's audit gate m60.)

### A3 — SDK parity + codegen

- **What:** Three things: (1) **fluent REST query builder** (`.eq/.in/.or/.single/.range` chaining)
  replacing the options-object API; (2) **COMMIT THE OPENAPI SPEC** — the `openapi/` dir is *empty*
  today (verified: only `.gitkeep`), which blocks all multi-language codegen; (3) **schema→types
  generation** (today only an engine-catalog gen exists); plus surface **OAuth/MFA auth helpers in
  the SDK** (the capabilities exist in binocle-one but aren't in `@mini-baas/js`).
- **Why:** Closes matrix **#27 (fluent query builder — currently PARTIAL), #61 (type generation),
  #20/#22/#17 SDK exposure of MFA/OAuth**, and is the hard **prerequisite for A4** (no spec → no
  multi-lang SDKs) → **BAR 1**.
- **Key files / anchors:** `sdk/src/{index,types}.ts`, `sdk/src/domains/*.ts` (rest builder is
  options-object; `.transaction()` on the engine client is a **no-op wrapper** — fix or document),
  **`mini-baas-infra/openapi/` (EMPTY — must be populated)**, existing engine-catalog gen.
- **Exit gate:** **m57** SDK-parity — fluent builder e2e (chained filters byte-identical to current
  options API); **committed OpenAPI spec validates** and a generated TS client compiles; `baas gen
  types` emits typed table interfaces; SDK OAuth/MFA flow logs a user in.

### A4 — Multi-language SDKs

- **What:** Generate **Python** and **Dart/Flutter** SDKs from the committed spec; **Swift/Kotlin**
  next.
- **Why:** Closes matrix **#46–#51 (JS have it; Dart/Swift/Kotlin/Python are GAP today)** → **BAR 1**.
  Supabase ships JS/Dart/Swift/Kotlin/Python; Firebase ships Web/iOS/Android/Flutter/Unity/C++.
  **Hard-blocked on A3 — the OpenAPI spec must be committed first.**
- **Key files / anchors:** `mini-baas-infra/openapi` (consumed, not empty by now), per-language SDK
  packages (new), codegen pipeline added in A3.
- **Exit gate:** **m58** polyglot-SDK — generated Python + Dart clients each run the auth→CRUD→realtime
  smoke against a live stack; published to their package registries (or release artifacts).

### A5 — GraphQL + realtime parity

- **What:** (1) **GraphQL** via `pg_graphql` passthrough (today the string "graphql" appears only in
  planning docs — *zero implementation*). (2) Realtime **broadcast + presence** primitives. (3)
  **Multi-node event bus** so realtime scales horizontally.
- **Why:** Closes matrix **#26 (auto GraphQL), #30 (broadcast/pubsub), #31 (presence), #32 (realtime
  scale)** → **BAR 1**. Supabase has WAL→WS + broadcast + presence; we have WS fanout + roaring-bitmap
  filter index but **no first-class broadcast/presence** and a **Rust-only client**.
- **STRETCH (under m59):** advanced query surface the readiness doc points at A5 — **Joins / embedded
  resource expansion** (matrix **#4**, P1), **Full-text search** (matrix **#6**, P2), and
  **Vector / pgvector similarity search** (matrix **#7**, P2). These are owned here as A5 stretch work;
  if cut for launch they drop to the **Post-launch backlog** (§8) rather than going unowned. `pg_graphql`
  passthrough naturally covers some embedded-resource cases; FTS/pgvector are Postgres-extension
  passthrough on the data-plane route.
- **Key files / anchors:** `realtime-agnostic/crates/*` (broadcast/presence channels, multi-node bus;
  `realtime-bus-irc`/`realtime-bus-inprocess` are the bus seam), data-plane GraphQL passthrough route,
  data-plane query path (joins/embed, FTS, pgvector extension passthrough), Kong routing.
- **Exit gate:** **m59** GraphQL+realtime — a `pg_graphql` query returns the same rows as the REST
  path; broadcast and presence channels pass an e2e fanout test across two server nodes on the
  multi-node bus. **Stretch (best-effort within m59):** a joined/embedded query, a full-text search
  query, and a pgvector similarity query each return correct rows through the uniform API; any not
  landed by launch move to §8 Post-launch backlog.

### A6 — Security audit-ready posture **(OSS LAUNCH GATE)**

- **What:** Close the open residuals and reach an audit-ready posture: flip **JWT RS256 issuer**
  (gotrue still signs HS256 though RS256/JWKS verify is ready); **enforce Vault** (no plaintext DSNs
  outside `SECURITY_MODE=max`); **HMAC the adapter-registry identity headers** (it currently trusts
  `X-Baas-*` with no HMAC); **plane network isolation / NetworkPolicy** (flat single bridge network
  today); **audit reads** (only writes audited); add an **atomic key-rotation primitive**. Map all
  controls to **OWASP ASVS / SOC2-lite**; add **CI security gates** (`cargo-audit`, `govulncheck`,
  DAST, fuzz) on top of existing Trivy/SEMGREP/gitleaks.
- **Why:** This is **BAR 3** and the **gate for the entire OSS launch.** Baseline is already strong
  (in-stack WAF `[+]`, TLS verify-full at max, RLS+ABAC+field-masks on all engines, the landed audit
  fixes for MSSQL MITM / HTTP SSRF / timing / Mongo injection / cross-owner `$or` leak / bytea).
  Residuals are the difference between "strong" and "audit-ready". Formal SOC2 is *deferred* (D4).
- **Key files / anchors:** [security-audit.md](security-audit.md), `go control-plane
  internal/tenants/{keys,jwt,jwks}.go` (RS256 issuer flip, key rotation), `docker/services/waf`,
  `docker/services/vault`, adapter-registry header-trust path, compose networks (flat bridge),
  audit-log path (reads), CI workflows.
- **Exit gate:** **m60** audit-ready — all listed residuals closed and re-verified; controls mapped to
  an ASVS/SOC2-lite checklist in [security-audit.md](security-audit.md); `cargo-audit` + `govulncheck`
  + DAST + fuzz CI jobs all **blocking and green**.

### A7 — OSS packaging + docs → **★ OSS LAUNCH**

- **What:** One-command install; quickstarts; the **`baas` CLI** (consumed by A2/A3, shipped here);
  **migrate-from-Supabase / migrate-from-Firebase guides** leveraging `tenant_owned` (wrap a
  customer's existing DB behind the uniform API — a `[+]` neither competitor can offer). Ship a
  **product CI/CD integration** (matrix **#63**, P1): a `baas deploy` command plus a **GitHub Action**
  that runs `baas deploy` from a workflow (this is distinct from A6's *internal* CI security gates and
  from packaging — it is the customer-facing "deploy from CI" surface).
- **Why:** Turns the closed gaps into an adoptable product. Self-host is **PARITY+ vs Firebase**
  (matrix **#77** — Firebase is not self-hostable) and reinforces differentiator (a)/(c). Matrix **#63**
  (CI/CD integration) is the deploy-from-pipeline expectation Supabase/Firebase both meet.
- **Key files / anchors:** root `Makefile` + Docker Compose lifecycle, new `baas` CLI (`baas deploy`),
  a published GitHub Action, docs site / [grobase-master-plan.md](grobase-master-plan.md),
  `tenant_owned` path in `isolation.rs` / `mount.rs`.
- **Exit gate:** **m61** OSS-launch readiness — a stranger runs one command and gets a working stack;
  quickstart e2e passes; `baas` CLI scaffolds + deploys; both migrate-from guides verified against a
  real external Postgres via `tenant_owned`; **a `baas deploy` GitHub Action deploys the stack from a
  CI workflow run** (matrix #63). If #63 cannot land for launch it moves to §8 Post-launch backlog.

---

## 5. Track B — Managed cloud (after OSS; full metered + Stripe, staged)

This is the **largest net-new build** and the **#1 managed-cloud gap**. Staged so revenue logic is
de-risked: measure silently → enforce → charge.

### B1 — Metering

- **What:** Per-tenant usage counters — requests, rows, storage bytes, realtime-minutes, function
  invocations — emitted from the **Rust data plane** and **Go control plane** into a metering store.
- **Why:** Closes the metering gap (**zero `tenant_usage` code exists today**); prerequisite for
  **B2/B3** and for BAR 4 ("see usage"). Per [product-plan/06](product-plan/06-saas-multitenancy-quotas-billing.md).
- **Key files / anchors:** Rust data plane request path, `go control-plane internal/packages`, new
  metering store + flush pipeline.
- **Exit gate:** **m62** metering — counters for all five dimensions are accurate to ±1% under a
  load run vs an independent tally; per-tenant rollups queryable.

### B2 — Quota enforcement (on-by-default)

- **What:** Flip **`PACKAGE_ENFORCEMENT=1`** (built but defaults OFF); wire **QuotaGuard** to return
  **402 / 429** when a tenant exceeds plan limits. Tier engine-allowlist + capability mask + mount
  quota + per-tenant rate limit (Rust token bucket, Redis-backed, gate m51) are already built.
- **Rate-limiting / DDoS / abuse (productization, largely DONE):** the matrix **rate-limiting / DDoS**
  row is mostly closed already — in-stack OWASP **WAF (CRS)** `[+]` plus per-tenant **token-bucket**
  rate limiting (Rust, Redis-backed, already-shipped gate **m51**, multi-instance). B-track work here
  is **productization, not new engineering**: expose per-plan rate-limit tiers in the plan catalog and
  surface abuse-protection as a billed/positioned feature. No new gate — it rides B2/B3.
- **Why:** Closes matrix **quota half of multi-tenancy / pricing rows** and makes plans enforceable →
  BAR 4. Without B1 metering, enforcement has no ground truth — hence the order.
- **Key files / anchors:** `go control-plane internal/packages`, `PACKAGE_ENFORCEMENT` flag, Rust
  token-bucket limiter (Redis, m51), QuotaGuard 402/429 path.
- **Exit gate:** **m63** enforcement — a tenant over each quota dimension receives a correct 402/429;
  under-quota traffic unaffected; flag default flipped on for the cloud profile only (OSS stays off).

### B3 — Billing (Stripe)

- **What:** Stripe usage-based billing + a **plan catalog → entitlements** map + **self-serve plan
  change/upgrade**. Meters from B1 feed Stripe; entitlements feed B2.
- **Why:** Closes the billing gap (no Stripe today) and the **revenue half of BAR 4** ("be billed").
  Pricing model from [offer-sheet-v2.md](offer-sheet-v2.md) (~$2/mo nano → ~$41/mo max) and unit
  economics from [cost-analysis.md](cost-analysis.md) (marginal ~$0.40–1.00/tenant on a shared pro host).
- **Key files / anchors:** new billing service (Stripe usage records + webhooks), plan catalog /
  entitlements (alongside `internal/packages`), [offer-sheet-v2.md](offer-sheet-v2.md).
- **Exit gate:** **m64** billing — staged meter→enforce→bill proven end-to-end on Stripe test mode:
  usage records post, an invoice computes against the plan catalog, and a self-serve upgrade changes
  entitlements live.

### B4 — Tenant self-service

- **What:** Public control API **+ dashboard**: signup → create project → manage API keys → see usage
  → change plan. **Build a tenant-scoped self-service layer on top of the existing internal `/admin/v1/*` surface** (Kong-routed today but service-token + internal-network only — verified live by the m46 gate; it did **not** regress). Add an
  **Organizations / teams / members / invites model** (matrix **organizations** row, P1 cloud):
  per-principal ABAC exists today but there is **no org/membership/invite model** — own it here as the
  self-service team layer (org → members → roles → invites on top of the tenant/project/key APIs).
- **Why:** Closes the tenant self-service gap (today: **one JWT self-bootstrap endpoint only**) and is
  the **core of BAR 4** ("a stranger can sign up → get a project + API key"). Studio is a **vendored,
  Postgres-only, single-project, NOT tenant-aware** Supabase Studio — it does not satisfy this. The
  organizations/teams model closes the matrix **organizations** row (Supabase/Firebase both ship it).
- **Key files / anchors:** `/admin/v1/*` (Kong-routed, service-token/internal-only — add a tenant-scoped self-service surface in front), Go
  control-plane tenant/project/key APIs, new org/membership/invite tables + API, per-principal ABAC
  (existing), new tenant-facing dashboard, gotrue signup.
- **Exit gate:** **m65** self-service — a fresh, never-seen email completes signup → creates an org →
  invites a second member who accepts → creates a project → key-issue → CRUD with that key → views
  usage → upgrades plan, all through public surfaces.

### B5 — Per-tenant observability

- **What:** Add **`tenant_id` labels across metrics/logs/traces**; per-project usage views. Observability
  is fully wired (Prometheus/Grafana/Loki/Promtail/Tempo/otel-collector, all 3 planes expose
  `/metrics`, gate m19; alert rules m52) but **global-only — no `tenant_id` anywhere**, Loki
  single-tenant, Grafana single-org.
- **Why:** Closes matrix **#64/#65/#69 from the customer's perspective** ("a tenant cannot see their
  own metrics/logs today"); Supabase/Firebase expose per-project logs/usage. Supports BAR 4 ("see
  usage").
- **Key files / anchors:** all 3 planes' `/metrics` exporters, Loki/Promtail label config, Tempo/
  otel-collector trace attributes, Grafana org/datasource model, [product-plan/06](product-plan/06-saas-multitenancy-quotas-billing.md).
- **Exit gate:** **m66** per-tenant observability — a tenant-scoped dashboard shows only that tenant's
  request/error/latency series, logs, and traces; no cross-tenant leakage in any signal.

### B6 — Per-tenant backup/restore

- **What:** Self-service, **tenant-scoped** backup + restore. Today backups are **whole-cluster only**
  (pg-backup logical `pg_dump -Fc` daily, 14d retention → MinIO, optional WAL/PITR, restore-drill
  tested at gate m47) — there is **no per-tenant backup or self-service restore**.
- **Why:** Closes matrix **#11 (backups/PITR) from the per-tenant angle** and a common managed-cloud
  expectation; soft-delete is the only teardown today.
- **Key files / anchors:** `docker/services/pg-backup`, restore-drill (m47), per-tenant export path,
  tenant-scoped restore API.
- **Exit gate:** **m67** per-tenant DR — a single tenant's data is backed up and restored to a point
  in time without touching other tenants; self-service trigger verified.

---

## 6. Track C — Scale & HA (for the cloud SLO; runs parallel with B)

The cloud SLO (BAR 2) needs a real horizontal topology. Scale is **vertical today** (share-pools: 10K
tenants → 1 pool, gate m46) with **no horizontal scale-out, no HA, no multi-region**.

### C1 — Horizontal data-plane scale-out + supavisor multiplexing

- **What:** Run multiple data-plane replicas behind a load balancer; wire **supavisor** (present but
  opt-in, **not wired to the Rust data plane**) for connection multiplexing. Target the documented
  per-pool ceiling (~800 rps).
- **Why:** Single-node is the standing scale limit; this is the foundation for the published SLO
  (**BAR 2**). Read path is already lean (3.3 MiB Rust vs 127 MiB Node, ~38×; ~400 rps/pool, p95 <2 ms).
- **Key files / anchors:** Rust data plane (stateless replica config), `docker/services/supavisor`
  (wire to data plane), `docker-compose.scale.yml` (today a single-node *tuning* file, not a replica
  topology), [product-plan/07](product-plan/07-scale-ha-helm-deployment.md).
- **Exit gate:** **m68** scale-out — N data-plane replicas behind supavisor sustain a measured RPS
  beyond single-node with stable p95; share-pools isolation still byte-identical across replicas.

### C2 — Production Helm chart

- **What:** Promote the Helm chart from **eval-only stub** (Deployment + ClusterIP only; **no Ingress
  / PVC / StatefulSet / HPA / secrets**) to production-grade (Ingress, PVC, StatefulSet, HPA, secrets).
- **Why:** Compose is the real primary surface today; a production K8s deploy story is required for the
  cloud topology and serious self-hosters. Per [product-plan/07](product-plan/07-scale-ha-helm-deployment.md).
- **Key files / anchors:** Helm chart dir (stub today), HPA/StatefulSet/Ingress/PVC templates, secrets
  via Vault (ties to A6).
- **Exit gate:** **m69** Helm — chart deploys the full stack to a real cluster with Ingress + persistent
  volumes + HPA scaling under load + secrets from Vault; smoke e2e passes against the cluster.

### C3 — Multi-region + blue-green/rolling deploys; managed-Postgres HA path

- **What:** Multi-region deploy; **blue-green / rolling** deploys (none today); document the HA answer
  (swap `DATABASE_URL` to managed Postgres) and validate it. Add **data residency / region selection**
  (matrix **data-residency** row, P1 cloud): let a tenant/project pin its data + compute to a chosen
  region — own it here as part of the multi-region build (Supabase/Firebase both offer region choice;
  Grobase has none today).
- **Why:** Uptime is part of the SLO (**BAR 2**); zero-downtime deploys and a regional/HA story are
  table-stakes for a paid cloud. Region selection closes the matrix **data-residency** row and is a
  common compliance/sales requirement for managed cloud.
- **Key files / anchors:** deploy manifests, ingress/traffic-shift config, per-tenant region routing +
  region-pinned mounts, managed-Postgres HA runbook in
  [product-plan/07](product-plan/07-scale-ha-helm-deployment.md).
- **Exit gate:** **m70** HA-deploy — a blue-green/rolling deploy completes with zero failed requests
  during cutover; managed-Postgres failover validated against the HA runbook; **a project pinned to a
  selected region keeps its data + compute in that region** (residency verified, no cross-region
  leakage).

### C4 — Re-run scale to 100K tenants → publish SLO → **★ CLOUD LAUNCH + GTM**

- **What:** Execute the projected 100K-tenant run (currently **projected, not measured**) on the new
  horizontal topology; publish the SLO (tenants @ p50/p95/p99 + RPS + uptime).
- **Why:** Converts the share-pools lever (proven on all 7 engines at 10K, gate m46) into a *measured*
  100K claim — the headline of **BAR 2** and the GTM scale message.
- **Key files / anchors:** [product-plan/09-100k-tenant-path.md](product-plan/09-100k-tenant-path.md),
  the load harness from P0.2, share-pools (`pools_shared` in `data-plane-pool/src/lib.rs`).
- **Exit gate:** **m71** 100K-SLO — 100K tenants seeded and load-tested on the horizontal topology;
  published p50/p95/p99 + RPS + uptime meet the offer-sheet SLO. **GTM bundle ready:** pricing
  ([offer-sheet-v2.md](offer-sheet-v2.md) + [cost-analysis.md](cost-analysis.md)), signup funnel
  (B4), legal (ToS/privacy/DPA), SLA, status page.

---

## 7. Risks & sequencing notes

| # | Risk / note | Mitigation |
|---|-------------|------------|
| R1 | **The OpenAPI spec must be committed before A4.** The `openapi/` dir is empty today (verified: only `.gitkeep`). No spec → no codegen → no multi-language SDKs. | Treat the committed, validating spec as A3's hard exit criterion; A4 cannot start until it lands. |
| R2 | **Metering (B1) must precede billing (B3) and enforcement (B2).** Charging or 402-ing without ground-truth usage is a correctness and trust hazard. | Enforce the staged order meter→enforce→bill (D3); B2 and B3 both depend on B1's counters. |
| R3 | **The vs-Supabase benchmark is cheap and unblocks the scale-SLO claim.** The harness exists but has never run; without numbers, BAR 2 is unprovable and marketing can't lead with scale. | Run it in Phase 0 (P0.2) before any Track work — it is the highest leverage-per-hour item in the program. |
| R4 | **A6 is the OSS launch gate — don't let DX work slip past it.** Shipping storage/functions/SDK while residuals (RS256 issuer + per-deployment keys, header-trust, flat network) are open would launch a known-insecure posture. | A6 blocks ★ OSS LAUNCH unconditionally; P0.3 front-loads the cheapest item (secret-scan CI gate) immediately. |
| R5 | **`/admin/v1/*` exists and is Kong-routed but is service-token + internal-network only** (verified: tenant-control binds `0.0.0.0`; the m46 gate drives `KONG/admin/v1/databases` live). The real gap is **no tenant-facing self-service** surface (no signup/project/plan/key UI). | B4 adds a *tenant-scoped* self-service control API + dashboard on top of the existing internal admin routes — it productizes them, it doesn't restore a broken route. |
| R6 | **Studio is a vendored, Postgres-only, single-project, NOT tenant-aware Supabase Studio** — it does not satisfy B4's per-tenant dashboard need. | The B4 dashboard is net-new and tenant-scoped; treat Studio as an internal/admin tool only, not the customer console. |
| R7 | **Tracks B and C both gate ★ CLOUD LAUNCH.** Billing without scale (or vice-versa) is not launchable. They run in parallel after OSS but must both reach their exit gates. | Keep B and C parallel but converge on the launch; C4's 100K-SLO and B4's signup flow are the joint go/no-go. |
| R8 | **Functions per-USER (not per-tenant) namespacing** is a quiet multi-tenancy hole that A2 must fix, or B-track tenant isolation leaks into functions. | A2 includes the per-USER→per-tenant namespacing change as part of its exit gate (m56). |
| R9 | **Doc drift erodes the honesty bar** (stale storage README `signPut()`, old essential-tier numbers, "graphql" strings with zero impl). | P0.4 reconciles drift up front; every item here distinguishes shipped+gated vs built-but-off vs planned per house style. |

---

## 8. Canonical gate numbers

The single source of truth for **new** gate numbers in this program. New work starts at **m54** — never
reuse any of **m1–m53**. Three existing gates are cited only as *already-shipped* evidence (not new work).

**CANONICAL NEW GATE NUMBERS (use these exactly; never reuse m1-m53 for new work):**

- Phase 0 vs-Supabase benchmark = **m54**
- A1 Storage DX = **m55**, A2 Functions DX = **m56**, A3 SDK parity/codegen = **m57**, A4 multi-language SDKs = **m58**, A5 GraphQL+realtime(+stretch joins/FTS/vector) = **m59**, A6 security audit-ready = **m60**, A7 OSS packaging = **m61**
- Track B items = **m62..m67** (B1=m62 metering, B2=m63 enforcement, B3=m64 billing, B4=m65 self-service+orgs, B5=m66 per-tenant observability, B6=m67 per-tenant DR)
- Track C items = **m68..m71** (C1=m68 scale-out, C2=m69 Helm, C3=m70 HA-deploy+residency, C4=m71 100K-SLO)
- **Already-shipped gates (cited, never re-used for new work):** **m32** = footprint gate; **m51** = multi-instance per-tenant rate-limit; **m46** = share-pools isolation.

---

## 9. Post-launch backlog (owned, may slip past launch)

Items that are **owned work** but may land after a launch milestone. They are listed here so nothing
referenced from [marketability-readiness.md](marketability-readiness.md) or
[competitive-matrix.md](competitive-matrix.md) is left unowned.

| Item | Matrix # / row | Priority | Primary owner | Fallback |
|------|----------------|----------|---------------|----------|
| Joins / embedded resource expansion | #4 | P1 | A5 stretch (m59) | here, post-launch |
| Full-text search | #6 | P2 | A5 stretch (m59) | here, post-launch |
| Vector / pgvector similarity | #7 | P2 | A5 stretch (m59) | here, post-launch |
| CI/CD integration (`baas deploy` GitHub Action) | #63 | P1 | A7 (m61) | here, post-launch |
| SMS / Phone OTP provider | #15 | P1 | A2 (m56) | here, post-launch |
| Email deliverability / prod SMTP provider | email-deliverability | P1 | A2 (m56), hardened A6 (m60) | here, post-launch |

Org/teams/members (#organizations → B4/m65), data residency/region (#data-residency → C3/m70),
rate-limiting/DDoS (largely DONE: WAF + token-bucket **m51**, productized in B2/B3), and webhooks
(SHIPPED `[~]`, documented in A2) are owned in-track and are **not** backlog.

---

### Cross-references

- Gap numbers (#1..#91) and status glyphs → **[competitive-matrix.md](competitive-matrix.md)**
- Acceptance bars (BAR 1–4) and gate definitions → **[marketability-readiness.md](marketability-readiness.md)**
- Scale levers and 100K path → [product-plan/09](product-plan/09-100k-tenant-path.md),
  [grobase-master-plan.md](grobase-master-plan.md)
- Quotas/billing/multi-tenancy design → [product-plan/06](product-plan/06-saas-multitenancy-quotas-billing.md)
- Security baseline + residuals → [security-audit.md](security-audit.md)
- Pricing + unit economics → [offer-sheet-v2.md](offer-sheet-v2.md), [cost-analysis.md](cost-analysis.md)
- nano/PocketBase wedge honesty → [nano-vs-pocketbase.md](nano-vs-pocketbase.md)
