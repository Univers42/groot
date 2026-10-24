# Phase 0 audit — Prismatica website, grobase data, auth and email

Read-only discovery for [BRIEF.md](BRIEF.md), 2026-10-15. Decisions taken on the way are in
[DECISIONS.md](DECISIONS.md).

**Sources.** groot `redesign/brief` (from `develop` 5188e8e9). Submodules at their develop pins:
- opposite-osiris 8559d6dd;
- osionos fabe846b;
- grobase 8b9321a6;
- grobase-cli 112a848.

The stack measured is the one running on this machine: frontends at `https://localhost:4322`, linked
in `direct` mode to baas over Funnel.

**How each claim is known**, marked in the tables below:
- **✔** verified for this audit, with a command against the running stack, a test run or a
  measurement;
- **src** read from source at the cited `file:line` (paths are relative to the named submodule)
  but not exercised;
- **?** unknown.

Three parallel read-only subagents did the reading; the ✔ items were re-checked by hand.

---

## 1. Tools (brief §tools)

| Tool | Status | How it runs |
|---|---|---|
| Playwright MCP | ✔ answers `initialize` | `.mcp.json` → `scripts/tools.sh playwright-mcp` (`@playwright/mcp` 0.0.83 on the image's Chromium). The session must restart to load it (§9). |
| Chrome DevTools MCP | ✔ answers `initialize` | `.mcp.json` → `chrome-devtools-mcp` 1.10.1 in `groot-tools`. Restart needed, as above. |
| osionos MCP | ✔ answers `initialize` | It was broken (hardcoded `/home/…/Documents` path and nvm node); repaired in 384f0e1d. |
| Playwright test runner + `@axe-core/playwright` | ✔ | `tests/e2e/run.sh` (image `groot-e2e`, Playwright 1.63.0), with axe 4.13.0 added to the lockfile. |
| Lighthouse CI | ✔ | `scripts/tools.sh lhci` (0.15.1). |
| `frontend-design` skill | **absent** | `frontend` + `design-review` are used instead (D-007). |
| ffmpeg, sharp/vips, ImageMagick, SVGO | ✔ | `groot-tools`. ffmpeg encodes H.264, VP9, AV1 and WebVTT; vips/magick write AVIF and WebP. `tests/tools-image/smoke.bats` 13/13. |
| grobase-cli | ✔ packaged | `scripts/tools.sh grobase` (112a848). Its limits are in §4.4. |

Nothing is installed on the host (D-004). `scripts/tools.sh` builds `infrastructure/docker/tools`
on first use, tagged by a hash of its definition.

---

## 2. Stack (opposite-osiris)

| Area | Finding | |
|---|---|---|
| Framework | Astro 7.3.8, Node ≥ 22.12 (`package.json`) | src |
| Rendering | **Static (SSG)**: no `output` setting and no adapter (`astro.config.mjs:59-160`). Stylesheets are inlined (`:76`). A meta CSP with hashes plus Trusted Types is in force (`:89-117`). | src |
| Serving | groot `local-https-proxy` :4322 → `opposite-osiris-web` nginx, which serves `dist` and proxies `/api/auth`, `/api/newsletter` and `/api` to the Node auth-gateway (`docker/services/web/default.conf.template:50-109`). | ✔ (curl, §5) |
| Hosting beyond local | `vercel.json` rewrites to fly. `deploy/fly` is the gateway only, and its `PUBLIC_SITE_URL` is a `PLACEHOLDER:` value. **The production domain is unknown.** | src / ? |
| Styling | Sass and hand-written CSS custom properties in two layers (`--brand-*`, `--system-*`); no Tailwind. Five themes: swiss (default), aurora, solar, ember, forest (`src/lib/theme-config.ts:3`). | src |
| Tokens (swiss) | bg `#ffffff`/`#f4f4f2`, ink `#111111`/`#3a3a3a`/`#6b6b6b`, accent `#e4002b`. 12-column grid, 8 px baseline, max width 1200 px (`src/styles/abstracts/_swiss.scss:18-80`). Motion durations 120/180/240 ms (`_system-tokens.scss:121-147`). | src |
| Type | Self-hosted woff2: Space Grotesk, Instrument Serif, JetBrains Mono, Caveat, Special Elite. Swiss uses Space Grotesk, yet both Space Grotesk and Instrument Serif are preloaded (`Layout.astro:85-86`), and JetBrains Mono loads too: those three are the 84 KB of fonts in §6. | ✔ (file sizes) |
| Components | All home-made (`src/components/ui`). No UI library and no `client:` islands. **17 components are unused**, e.g. Portal, ProductShowcase, MediaAssets, SketchBackground. | src |
| Motion | No library. Scroll reveals use CSS `animation-timeline: view()` (`_scroll-effects.scss`); tilt and magnetic effects live in `src/scripts/premium.ts`. The reduced-motion guards work: the `-reduced` captures show every section. | ✔ (§6) |
| JS on every page | `src/scripts/main.ts` eagerly loads `@grobase/js`, `portal.ts` (929 lines), `mascot.ts` (506) and `premium.ts`, including on the legal pages (`Layout.astro:105`). | src; weights in §6 |
| Package manager | pnpm 11.5.1 is authoritative; `package-lock.json` is a stale leftover. | src |
| CI | `ci.yml` runs astro check, vitest and eslint. `publish.yml` pushes images. No build, a11y, e2e or Lighthouse in CI. | src |
| Tests | Vitest + happy-dom, 24 unit files. No Playwright in the submodule. | src |

---

## 3. Website — routes, jobs, what is wrong

The route list is the single file `tests/e2e/site-audit/routes.txt`. There is no i18n: `lang="en"`
is hard-coded.

| Route | Job | Current headline | Problems |
|---|---|---|---|
| `/` | Landing page | "Everything. One Space." — eyebrow "01 — Open-source BaaS for product teams" | See the list below. |
| `/404` | Not-found page | — | **Never served.** nginx has no `error_page`, so even `/404` returns nginx's stock "404 Not Found" page (✔ curl). The Astro page also relies on inline `style=` (`404.astro:10-13`), which the CSP blocks. |
| `/legal/{privacy-policy,terms,cookies,data-rights}` | Legal | "Privacy Policy" … | No site chrome, only "← Back". The data controller in `data/legal.ts:16-19` differs from the footer's DPO address (`FooterNew.astro:79`). `/legal/privacy-policy` answered **502** on one of three loads in the first capture, but not in the second (✔, R15). |
| `/auth/confirm`, `/auth/reset-password` | Email-link landings (noindex) | "Confirming your Prismatica account…" | **They cannot work** (✔, §5.2). |
| `/newsletter/{confirm,unsubscribe}` | Double opt-in (noindex) | "Confirming your subscription…" | `POST /api/newsletter/subscribe` in source is a mock ("Mock success response", `subscribe.ts:24`). nginx sends that path to the gateway, so the mock is dead code. |
| `/docs/` | Docs | — | Not Astro: a committed 2 MB generated bundle (`public/docs/index.html`, built by `scripts/build-vault.mjs`) with its own design system, which loads a 3.8 MB `fragment.html`. |

Problems on `/`:
- **Fake proof.** The logo strip "Trusted by product teams everywhere" lists invented names
  (`LogoStrip.astro:2-4`, ✔). The testimonials are invented, e.g. "Amelia Hart" and "…The mascot
  is a bonus." (`SocialProof.astro:8,13`, ✔).
- **Unbacked claims.** Pricing promises SSO + audit logs, a 24 h SLA and Helm
  (`Pricing.astro:32-46`, ✔). The FAQ promises EU hosting in Paris and Frankfurt, and migration
  recipes for Supabase, Firebase and Hasura (`FaqSection.astro:11,19`, ✔).
- **Product described, never shown.** The hero art is a hand-built HTML mock (`HeroNew.astro:24-45`).
  No live page renders a single real screenshot.
- **Positioning conflict.** The hero sells a BaaS to product teams, while the layout's
  description sells a workspace (`Layout.astro:16`). Neither matches the audience in BRIEF.md
  (companies unifying departments, plus local second-brain use).
- **Duplicate IDs.** `product`, `pricing` and `faq` each appear twice, because each section
  component nests inside a wrapper `<section>` with the same id.
- **Blank page without scrolling.** Below the fold every section starts at opacity 0 until it is
  scrolled into view (compare `baseline/screenshots/home-1440.jpg` with
  `home-1440-reduced.jpg`). Print, social previews and anything that does not scroll see an empty
  page.
- The cookie banner covers the hero's stat row at every width (captures).

Problems on every page:
- **Horizontal overflow** at 390 px on 6 of 11 routes, measured from the capture widths
  (`home-390.jpg` is 429 px wide): `/` +39, `/auth/confirm` +76, `/auth/reset-password` +31,
  `/legal/cookies` +295, `/newsletter/confirm` +200 (and +226 at 1440), `/newsletter/unsubscribe`
  +268 (+110 at 768, +455 at 1440). Phones get a sideways scroll. `overflowPx` is a measured
  field (§6).
- **`color-scheme: dark` on the white default theme**, so native form controls and scrollbars
  render dark on white (`src/scripts/theme.ts:36`, ✔).
- **SEO.** `og:image` falls back to the favicon SVG (`Layout.astro:25`). Only 404, legal and
  auth set their own titles. `robots.txt` points its sitemap at `https://localhost:4322/`. The
  sitemap lists the noindex routes.
- **Leftovers.** `public/assets/` holds about 4 MB of images no live page references, e.g. a
  2.2 MB `image 6.svg` and a 1.5 MB "ChatGPT Image …png". `scratch_links.txt` (2.2 MB) and
  `test-results/` are committed.

---

## 4. Grobase and data

### 4.1 Engines

- The data plane has 8 adapters: postgres, mysql, mongo, mssql, sqlite, redis, http and dynamodb
  (opt-in) (`src/data-plane-router/crates/data-plane-pool/src/`, `data-plane-server/Cargo.toml:24-33`). src
- groot's default edition `devlean` runs postgres, mysql, mongo, redis and minio
  (`infrastructure/makes/grobase.mk:59`; grobase `orchestrators/makes/00-config.mk:90-96`). src
- **Which edition baas runs is unknown.** ADR 0002:63 found its sqlite and dynamodb mounts empty. ?
- A mount is one `tenant_databases` row (tenant, engine, name, AES-GCM DSN, isolation,
  `read_scoped`, `shared_resources`), with `UNIQUE(tenant_id, name)`
  (`scripts/migrations/postgresql/004_add_adapter_registry.sql:17-28`). src

### 4.2 Namespacing and isolation

- Isolation strategies are `shared_rls` (default), `schema_per_tenant`, `db_per_tenant` and
  `tenant_owned` (`data-plane-core/src/isolation.rs:47-94`). src
- `owner_id` is stripped from client writes and injected server-side
  (`postgres/crud_build.rs:36-55`). src
- RLS variables are set per transaction (`postgres/tx.rs:112-114`). src
- **osionos does not live in a tenant mount.** Every `osionos_*` table sits in the platform
  database `postgres`, schema `public` (`scripts/apply-models-migrations.sh:94-95`). Their RLS
  admits only service_role (`models/osionos-bridge-migration.sql:183-208`; groot CI
  `models-grants`). Per-user isolation is enforced **only** in the Node bridge
  (`apps/osionos/app/scripts/bridge-api.mjs:807-825`). src

### 4.3 Ownership and sharing (what a demo can show)

- **Workspace membership:** `osionos_workspace_members.role` ∈ owner/admin/editor/viewer, plus
  `permissions[]` (`osionos-bridge-migration.sql:39-47`). src
- **One page shared with one user** works through `osionos_pages.collaborators` and `visibility`
  private/shared/public. Reads are decided in `bridge-page-read.mjs:52-59`, writes in
  `bridge-api.mjs:822-824`, and only the owner can change them. src
- **Share rules** (`osionos_share_rules`) are stored for the Share dialog but **never enforced** on
  reads or writes. src
- **Object databases are owner-only and cannot be shared** (`bridge-api.mjs:3254,3279`). src
- `osionos_people_directory` lists every user, so a demo user appears to everyone unless
  `directory_opt_out` is set. src

### 4.4 What the app can display (the seed's ceiling)

- **Pages** hold a JSONB block tree. Block types (`src/entities/block/model/types.ts:19-50`):
  paragraph, headings, lists, to_do (synced to `osionos_tasks`), toggle, media, code, quote,
  callout, equation, layout and columns, table, inline and full-page database, `graph_view`,
  `draw`, `home_views`.
- **Page properties:** text, date, select, multi_select, status, url, email, phone, number,
  checkbox, person, relation.
- **User object databases** (owner-only) add formula, rollup, files, place, button, id,
  created/edited fields, assigned_to and due_date. Their views: table, board, calendar,
  timeline, gallery, list, chart, feed, map, dashboard.
- **The built-in "CRM", "Learn", "Grades" and "Wiki files" databases are client-bundled seed JSON.**
  Edits to them never reach the server (`knownDatabaseStorage.ts:16`), so a server seed cannot
  fill them.
- **No dedicated "reports" or "library" module exists.** Reports would be dashboard and chart
  views; the library would be a user object database.

### 4.5 Migrations — the brief's premise does not hold

| Brief assumes | Reality | |
|---|---|---|
| A grobase-cli "user migrator" | **None exists.** No match for "user migrat" in grobase-cli (0 hits); its commands are `apicmd apps db doctor functions host keys orgs query realtime status storage tenants users`. | ✔ |
| Versioned, checksummed, reversible migrations | `grobase db migrate` posts files to `/admin/v1/migrate`. The server keys `_baas_migrations` **by name only**: no checksum, no down migration, no dry-run (`postgres/schema.rs:56-100`). Only engines with DDL (pg, mysql) are accepted. Kong caps the body at 256 KB. | src |
| It runs against staging | **`/admin/v1` is refused over Funnel**, by WAF rule 10130 (`waf/conf/exclusions.conf:143-153`, ✔ read). Only the tailnet IP or LAN path reaches it (grobase-cli `docs/CONNECTING.md:41-47`). | ✔/src |
| The CLI reaches the app's data | osionos tables are not in any mount, so `db migrate` cannot touch them. Over Funnel, what does work is `/rest/v1/osionos_*` with the service-role key, and `/auth/v1/admin/users`. | src |

groot's own runners for `models/*.sql`:
- `scripts/apply-models-migrations.sh`, run by `make all`, has **no ledger**. It replays files
  in a fixed order and relies on `IF NOT EXISTS`.
- `scripts/apply-models.sh` has a sha256 ledger but adopts files without running them, and has
  no skip list.
- Neither has a down migration. src

### 4.6 Existing seeds and data (do not touch)

- **The demo account** (`scripts/lib/demo-login.sh:13`) and its workspace are seeded by
  `scripts/seed-osionos-daily-driver.sql`. grobase's `scripts/seed/osionos-collaborators.sh` adds
  the shared workspace "Acme Operations"; `agency-tenant.sh` adds tenant `agency`.
- `tools/seeds/seed_*.py` assign workspace `0ea96910…` to a **different** owner than the
  daily-driver seed does (`seed_academy.py:7-8`). src
- The OD1 e2e spec creates an `e2e-crm-<ms>@example.com` account per run and never deletes it. src
- **Existing users, tenants and mounts on baas are not listed here.** VM database listings are
  run by the human. The read-only commands are in Appendix A.

---

## 5. Auth and email

### 5.1 How it works today (src)

- **Sign-up and sign-in** live in a `<dialog>` that `src/scripts/portal.ts` builds from strings.
  It posts to `/api/auth/*` on the **Node** auth-gateway (`scripts/auth-gateway.mjs`, 1191
  lines). It is not Go, as groot's docs say.
- **Register:**
  - checks Turnstile, the input patterns and an MX lookup;
  - if verification is off, calls GoTrue admin `createUser` with `email_confirm:true`;
  - if it is on, calls `generate_link type=signup` and sends the mail itself (`:802-864`).
- **Sessions:**
  - the refresh cookie is `prismatica_refresh` (HttpOnly, SameSite=Lax, Secure,
    Path=/api/auth, 30 days);
  - the access token is kept in memory only;
  - GoTrue's JWT lives 1 h, with refresh-token rotation on.
- **Hand-off to osionos:**
  - the gateway signs an HMAC assertion;
  - the bridge checks its time skew and jti, then mints an `osionos_v1` token (1 h) behind a
    one-time 90 s hand-off;
  - the app keeps it in **localStorage**;
  - the jti and hand-off stores are in-memory Maps, so they are lost on restart.
- **Logout only clears the cookie.** Nothing revokes the GoTrue refresh token or the osionos token.
- **Verification is off locally** (`AUTH_REQUIRE_EMAIL_VERIFICATION` defaults to false,
  `docker-compose.yml:515-516`) and on in fly (`deploy/fly/fly.toml:28`).
- **Reset:**
  - `/recover` always answers 200 with a generic body;
  - it calls `generate_link type=recovery` and sends the mail itself;
  - `/auth/reset-password` calls `updateUser`.
- **No resend-verification endpoint.** If the email fails after the user was created, a retry
  gets 409 and the account stays stuck unconfirmed.

### 5.2 Broken today

1. **The confirm and reset pages can never reach GoTrue.** ✔
   - Both pages bake `data-baas-url="/api"` (curl of the live pages).
   - The bundled SDK appends `auth/v1/verify` / `auth/v1/user`.
   - `https://localhost:4322/api/auth/v1/verify` and `/api/auth/v1/user` return the gateway's
     `404 {"message":"Not found."}` (curl), because nginx's longest prefix `/api/auth/` wins.
   - The result: every confirmation or reset link ends on "link expired".
2. **The reset link carries the wrong token.** The mail prefers GoTrue's `action_link`, which
   Kong's key-auth blocks and which puts the token in the `#fragment`, while the page reads
   `?token=`. The fallback passes a `hashed_token` as if it were a bearer JWT. It needs
   `verify({type:'recovery', token_hash})` first (`auth-gateway.mjs:414-432`). src
3. **Turnstile dev token mismatch.** The portal sends `local-dev-turnstile-token`
   (`portal.ts:70,82`), but the bypass accepts `localhost-turnstile-token`
   (`auth-gateway.mjs:237`). src, not exercised
4. **The recover UI shows success on any response,** 403 and 429 included (`portal.ts:590-593`). src
5. **Recover timing differs for real accounts** (a synchronous `generate_link` plus the SMTP send),
   which allows enumeration. `/availability` states registration outright; that is by design but
   rate-limited to 30/min. src
6. **No per-target cap on `/recover`,** so one victim's inbox can be flooded. Newsletter has a cap
   (`:1007`). src

### 5.3 Titan

- **Titan is wired into grobase, not into the site.** ✔ key names only
  - `apps/grobase/.env` (git-ignored) has `SMTP_HOST` containing "titan", port 465, secure. That
    feeds GoTrue (`auth-api.yml:28-32`) and the control-plane email/OTP services.
  - The **site's gateway reads different keys** (`SMTP_USERNAME`, `SMTP_PASSWORD`,
    `SMTP_FROM_ADDRESS`, …). In groot compose these default to Mailpit
    (`docker-compose.yml:523-529`), and `.env.local` sets none of them (0 matches).
  - Because the compose `environment:` defaults shadow `env_file:`, setting the keys in
    `.env.local` would not reach the gateway either.
- **Mailpit:** SMTP on `mailpit:1025`. The API is on `127.0.0.1:${MAILPIT_UI_PORT:-8026}` →
  container port 8025, `GET /api/v1/messages`. In link mode it is `grobase-link-mailpit`. src
- **Deliverability:**
  - no SPF, DKIM or DMARC documentation exists in the repo;
  - the gateway hard-codes `EHLO prismatica.local` and `Message-ID …@prismatica.local`
    (`auth-gateway.mjs:548,664`);
  - the sending domain is the one in `EMAIL_FROM`, whose value is not printed here. ?

### 5.4 Existing auth tests

- `tests/e2e/specs/ac1-new-account.spec.ts`: sign-up → sign-in → osionos, with verification off.
  Its last recorded run failed, because Trusted Types blocked `innerHTML`.
- `t43`: the form opens (✔ passed today through the refactored `run.sh`).
- opposite-osiris `scripts/security/*`: rate limit and gateway hardening.
  `11-gateway-failclosed` always skips, because it resolves `@mini-baas/js` while the gateway
  imports `@grobase/js`.
- **Nothing covers the confirm page, the reset page or the recover flow end to end.**

---

## 6. Baseline measurements

Produced by `scripts/site-audit.sh baseline`; raw evidence lives in [`baseline/`](baseline/):
- `lighthouse/{mobile,desktop}/` holds Lighthouse CI's representative (median) run of 3 per
  route;
- `screenshots/` holds `<route>-<width>.jpg` plus `-reduced.jpg`;
- `pages/` holds the axe, console, overflow and status data per route.

The three linked home screenshots were recreated on 2026-10-23 from the audited
opposite-osiris revision `8559d6dd1b3a095fe14bd4575b6eb4152e75990c` (light theme,
1440/390 × 900 viewports, JPEG quality 70, reduced motion where named). The original
image files were not committed; the measurements below are from the original audit run.

The tables are generated into [`baseline/summary.md`](baseline/summary.md) and copied below.

**Caveats:**
- These are lab numbers from this machine; Lighthouse simulates throttling, but the result
  still scales with this CPU.
- Lighthouse's navigation mode measures **no INP**; **TBT** stands in for it.
- `/404` is capture-only, because Lighthouse aborts a whole run on a non-2xx page.
- Screenshots taller than 12 000 px would be cut; none was.

#### Lighthouse — mobile (default throttling)

| Route | Perf | A11y | BP | SEO | LCP s | CLS | TBT ms | JS KB | CSS KB | Img KB | Font KB | Total KB | Console errors |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| / | 96 | 100 | 100 | 100 | 2.53 | 0.000 | 0 | 33 | 0 | 0 | 84 | 174 | 0 |
| /legal/privacy-policy | 97 | 93 | 100 | 100 | 2.36 | 0.000 | 0 | 33 | 0 | 0 | 84 | 152 | 0 |
| /legal/terms | 97 | 100 | 100 | 100 | 2.36 | 0.000 | 0 | 33 | 0 | 0 | 84 | 150 | 0 |
| /legal/cookies | 97 | 100 | 100 | 100 | 2.37 | 0.000 | 0 | 33 | 0 | 0 | 84 | 151 | 0 |
| /legal/data-rights | 97 | 95 | 100 | 100 | 2.36 | 0.000 | 0 | 33 | 0 | 0 | 84 | 150 | 0 |
| /auth/confirm | 98 | 100 | 100 | 66 | 2.06 | 0.044 | 0 | 35 | 0 | 0 | 84 | 152 | 0 |
| /auth/reset-password | 97 | 100 | 100 | 66 | 2.16 | 0.041 | 0 | 36 | 0 | 0 | 84 | 153 | 0 |
| /newsletter/confirm | 97 | 100 | 100 | 66 | 2.36 | 0.000 | 0 | 33 | 0 | 0 | 84 | 150 | 0 |
| /newsletter/unsubscribe | 97 | 100 | 100 | 66 | 2.36 | 0.000 | 0 | 33 | 0 | 0 | 84 | 150 | 0 |
| /docs/ | 72 | 94 | 100 | 92 | 20.70 | 0.020 | 43 | 0 | 0 | 5164 | 0 | 5458 | 0 |

#### Lighthouse — desktop preset

| Route | Perf | A11y | BP | SEO | LCP s | CLS | TBT ms | JS KB | CSS KB | Img KB | Font KB | Total KB | Console errors |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| / | 100 | 100 | 100 | 100 | 0.66 | 0.000 | 0 | 33 | 0 | 0 | 84 | 174 | 0 |
| /legal/privacy-policy | 100 | 93 | 100 | 100 | 0.61 | 0.000 | 0 | 33 | 0 | 0 | 84 | 152 | 0 |
| /legal/terms | 100 | 100 | 100 | 100 | 0.61 | 0.000 | 0 | 33 | 0 | 0 | 84 | 150 | 0 |
| /legal/cookies | 100 | 100 | 100 | 100 | 0.61 | 0.000 | 0 | 33 | 0 | 0 | 84 | 151 | 0 |
| /legal/data-rights | 100 | 95 | 100 | 100 | 0.62 | 0.000 | 0 | 33 | 0 | 0 | 84 | 150 | 0 |
| /auth/confirm | 100 | 100 | 100 | 66 | 0.57 | 0.001 | 0 | 35 | 0 | 0 | 84 | 152 | 0 |
| /auth/reset-password | 100 | 100 | 100 | 66 | 0.62 | 0.002 | 0 | 36 | 0 | 0 | 84 | 153 | 0 |
| /newsletter/confirm | 100 | 100 | 100 | 66 | 0.61 | 0.000 | 0 | 33 | 0 | 0 | 84 | 150 | 0 |
| /newsletter/unsubscribe | 100 | 100 | 100 | 66 | 0.61 | 0.000 | 0 | 33 | 0 | 0 | 84 | 150 | 0 |
| /docs/ | 80 | 95 | 100 | 92 | 3.56 | 0.046 | 0 | 0 | 0 | 5164 | 0 | 5458 | 0 |

#### Capture — axe (WCAG 2.2 AA tags) and console, across 390/768/1440 px

| Route | HTTP | Axe rules violated | Serious/critical | Which | Distinct console errors | Horizontal overflow | Max height px |
|---|---|---|---|---|---|---|---|
| /404 | 404 | 1 | 1 | html-has-lang | 1 | – | 900 |
| /auth/confirm | 200 | 0 | 0 | – | 0 | +76 @390 | 1273 |
| /auth/reset-password | 200 | 0 | 0 | – | 0 | +31 @390 | 1431 |
| /docs/ | 200 | 1 | 1 | color-contrast | 0 | – | 2384 |
| / | 200 | 1 | 1 | nested-interactive | 0 | +39 @390 | 9162 |
| /legal/cookies | 200 | 0 | 0 | – | 0 | +295 @390 | 2004 |
| /legal/data-rights | 200 | 1 | 1 | link-in-text-block | 0 | – | 1281 |
| /legal/privacy-policy | 200 | 1 | 1 | link-in-text-block | 0 | – | 4100 |
| /legal/terms | 200 | 0 | 0 | – | 0 | – | 2048 |
| /newsletter/confirm | 200 | 0 | 0 | – | 0 | +200 @390, +226 @1440 | 900 |
| /newsletter/unsubscribe | 200 | 0 | 0 | – | 0 | +268 @390, +110 @768, +455 @1440 | 900 |

**What the numbers say:**
- **The current site is light and fast.** Every Astro route ships 33–36 KB of JS and 84 KB of
  fonts, inlines its CSS, and scores Perf 96–98 on mobile and 100 on desktop, with TBT 0.
  - Mobile LCP on `/` is **2.53 s, already over the 2.5 s budget**, with no media at all.
  - The redesign adds real captures and a video, so it starts with **no performance headroom on
    LCP**. The media plan has to be lazy by default.
- **`/docs/` is the one slow page:** 5.2 MB of images, mobile LCP 20.7 s, Perf 72.
- **The SEO score of 66 on the four noindex routes is correct behaviour.** Lighthouse docks pages
  that block indexing, so "SEO 100 on every public page" cannot apply to them (PLAN §9).
- **Accessibility below 100:**
  - legal pages: `link-in-text-block` (links distinguished by colour only);
  - `/`: `nested-interactive`;
  - `/docs/`: `color-contrast`;
  - the nginx 404 page: `html-has-lang`.
- **Horizontal overflow is the largest visible defect.** It appears on 6 routes at 390 px and on
  the newsletter pages even at 1440 px (+455 px).
- **Console errors:** none on the Astro routes. The 404 logs its own status. The single
  `/legal/privacy-policy` 502 seen in the first capture did not recur in the second (R15).
- **Screenshots:** `/` at 1440 px, as a visitor first sees it (sections below the fold at
  opacity 0) and with reduced motion (every section visible):
  [`home-1440.jpg`](baseline/screenshots/home-1440.jpg),
  [`home-1440-reduced.jpg`](baseline/screenshots/home-1440-reduced.jpg). Mobile:
  [`home-390-reduced.jpg`](baseline/screenshots/home-390-reduced.jpg).


---

## 7. What needs repairing, and who owns it

Per the repair rule (D-009), each fix is reproducible and tested, and lives in the repo that owns
the code.

| # | Defect | Owner | When |
|---|---|---|---|
| R1 | `.mcp.json` hardcoded paths, plus http to an https bridge | groot | **Done**: 384f0e1d, guarded by `mcp-config.bats` |
| R2 | The e2e runner's uid/CA logic was inline and could not be reused | groot | **Done**: 65a865eb → `scripts/lib/docker-run.sh` |
| R3 | Confirm/reset pages call `/api/auth/v1/*`, which the gateway answers with 404 | opposite-osiris | Phase 5. A permanent fix routes the SDK through the gateway and adds an e2e test through Mailpit. |
| R4 | Reset token handling (`action_link` fragment vs `?token=`, hashed token used as a bearer) | opposite-osiris | Phase 5 |
| R5 | Site SMTP keys differ from grobase's, and compose defaults shadow `.env.local` | groot compose + opposite-osiris | Phase 5. Needs one key vocabulary. |
| R6 | nginx serves no `error_page`, so the Astro 404 is unreachable; the 404 also uses inline styles the CSP blocks | opposite-osiris | Phase 3 |
| R7 | Horizontal overflow on 6/11 routes at 390 px | opposite-osiris | Phase 3; the capture measures `overflowPx`, and Phase 6 gates it at 0 |
| R8 | Fake logos, testimonials and unbacked pricing/FAQ claims | opposite-osiris | Phase 3, by deletion (the brief forbids invented proof) |
| R9 | `color-scheme: dark` on the white default theme | opposite-osiris | Phase 3 |
| R10 | Turnstile dev-token mismatch; recover UI shows success on errors; no per-target recover cap | opposite-osiris | Phase 5 |
| R11 | Logout revokes nothing server-side; reset does not sign out other sessions | opposite-osiris + osionos bridge | Phase 5 (the brief requires it) |
| R12 | Two contradictory `models/*.sql` runners | groot | Phase 2; the data plan depends on it |
| R13 | `_baas_migrations` keyed by name only, with no checksum, down or dry-run | grobase | Logged and handed to grobase; the brief's migration rules cannot be met through it (PLAN §9) |
| R14 | Builder self-serve path returns 500 (ADR 0004) | grobase | Another session's in-flight work; not touched here |
| R15 | `/legal/privacy-policy` answered 502 once in three loads | groot stack | Investigate when the Phase 6 suite runs repeatedly; one flake is not yet a defect |
| R16 | Committed junk in opposite-osiris (`scratch_links.txt`, `test-results/`, orphaned `public/assets`) | opposite-osiris | Phase 3 cleanup commit |

---

## 8. What the brief got wrong (inputs to PLAN.md)

1. **No "user migrator" exists,** and `db migrate` cannot meet "versioned, checksummed,
   reversible, dry-run", nor run over Funnel.
2. **The demo's data does not live in grobase tenant mounts.** osionos keeps everything in the
   platform `postgres` behind the bridge. "Use each engine where it fits" can only apply to
   *mounted* databases shown inside osionos (database blocks over mounts), not to osionos's own
   pages.
3. **"Titan connected in Grobase"** is true for GoTrue and the control plane, but the site's
   mail path does not use it.
4. **Several requested modules have no server-side home:** the built-in CRM/Learn databases are
   client-only seed JSON, and "reports" and "library" have no module of their own.
5. **The auth-gateway is Node, not Go.**

---

## 9. Unknown (marked ? above)

- The production domain and host (Vercel vs the nginx image) → the sending domain for
  SPF/DKIM/DMARC.
- Which grobase edition baas runs, and which mounts exist there.
- Whether GoTrue v2.188.1 revokes other sessions on a password change.
- `TEST_INBOX` (Phase 7 only).
- **Session restart:** the repaired `.mcp.json` is on `redesign/brief`. A session started in
  `/goinfre/dlesieur/groot-redesign` loads it now. The main checkout gets it once the branch
  merges.

---

## Appendix A — read-only inventory of baas, for the human to run

The VM database listings are run by the human; nothing below writes anything.

```sh
ssh b2b 'docker volume ls --format "{{.Name}}" | sort'
ssh b2b "docker exec -e PGOPTIONS='-c default_transaction_read_only=on' mini-baas-postgres \
  psql -U postgres -d postgres -X -c \"
SELECT id,email,created_at,last_sign_in_at FROM auth.users ORDER BY created_at;
SELECT id,slug,name FROM public.tenants;
SELECT id,tenant_id,engine,name,isolation,read_scoped FROM public.tenant_databases ORDER BY tenant_id,name;
SELECT datname FROM pg_database;
SELECT w.id,w.name,(SELECT count(*) FROM osionos_pages p WHERE p.workspace_id=w.id) pages
  FROM osionos_workspaces w ORDER BY pages DESC;
SELECT owner_id,workspace_id,db_key,title FROM osionos_object_databases;\""
```
