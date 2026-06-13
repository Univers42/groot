# Build prompt — "Grobase" award-winning interactive BaaS experience

> Paste everything below the line into Fable 5. It is a complete, self-contained
> build spec: a product brief so the model can *teach* the product accurately,
> then a precise section-by-section construction order with exact stack, tokens,
> copy, GSAP timelines and three.js scene specs. Written in the prescriptive
> style of `neuralyn.md` / `curious.md` — every number, class and string is
> intentional. Honor it literally; improvise only on micro-polish.

---

Build an **award-winning, interactive, animated single-page marketing experience** for **Grobase** — a backend-as-a-service (BaaS). This is not a brochure: it is a *true experience*, built to win Awwwards / FWA "Site of the Day". The whole page rides a persistent 3D particle galaxy (three.js) that reorganises itself as the visitor scrolls, while GSAP + Lenis drive cinematic, scroll-pinned storytelling. The site must simultaneously be a piece of art **and teach exactly what makes Grobase different** from Supabase, Firebase and PocketBase. Crucially, the site is also a *product*: an interactive configurator where the visitor composes their own backend — engine by engine, service by service — and watches the price and architecture respond in real time.

The site itself must embody the product's own promise: **security by design, strict performance, lightweight modern tooling.** A performance product cannot ship a heavy site. Lazy-load the 3D, respect `prefers-reduced-motion`, hit a Lighthouse performance ≥ 90 on desktop.

## 0. The big idea (read this first, build to it)

Grobase exists for builders who **don't want to build a back-end at all**. They want to model their business and ship a front-end — and have the entire server side (auth, databases, realtime, storage, email, permissions, functions) simply *be there*, over plain HTTP, with **no per-project server code**.

The old way: pick one rigid hosted backend, accept its single database, pay a bill that balloons with success, and migrate off when you outgrow it. **Grobase kills the static build.** You compose the exact backend you need — choose your database engine(s), choose each service and how many, pick a prebuilt package *or* just the one piece you want — and the price scales precisely with what you take. As your site grows and serves more, the backend grows with you: **Start on Nano. Graduate to Max. Never rewrite.**

The metaphor for the whole site: **a living galaxy of tenants.** Every particle is one customer running its own composition of engines, tier and isolation. As the story scrolls, the galaxy reorganises — scattered nebula → clustered by engine → ringed by tier → split by isolation model → fused into three language planes → converged for the call to action. The visitor is told: *"Yours would be one of these stars."*

## 1. Product brief — the facts you must teach (do not invent claims)

Use these as the source of truth for all copy and data viz. Every number is measured and real; keep them honest.

**One sentence:** Grobase is a self-hosted, Docker-first **backend factory** — any frontend treats it as a complete backend (auth, relational + document data, realtime, object storage, email, multi-tenant query plane, ABAC/RBAC, edge functions, webhooks) over plain HTTP, with **no per-project server code**. Design goal: *the platform never needs to know the shape of your data.*

**8 database engines, one API** (`/query/v1`): PostgreSQL · MySQL/MariaDB · MongoDB · SQLite · Redis · CockroachDB · MSSQL · HTTP-federation. Pick per mount, mix per tenant, swap without rewriting. Adding an engine is *one registration line* (Rust `EngineAdapter` trait, strategy pattern).

**Capability-typed SDK:** every mount advertises exactly what it supports. A Redis mount that can't `.subscribe()` is a **compile-time type error**, not a 3 a.m. incident. Unsupported ops are refused with a clean `403`.

**3 language planes, each where it pays off:**
- **TypeScript** — business/orchestration logic that changes daily.
- **Go** — always-up control daemons (tenancy, secrets vault AES-256-GCM, webhooks). 6.8–58 MiB each.
- **Rust** — the hot path / data plane. **3.3 MiB** of Rust where it used to take **127 MiB of Node** → **~38× lighter, 5× faster (8 ms/req vs 40 ms).**

**4 isolation models, selectable per mount** (a dial, not a rebuild):
1. **Shared RLS** — one DB, rows filtered by tenant (cheapest, densest; many small tenants).
2. **Schema per tenant** — private schema each (noisy-neighbour isolation).
3. **Database per tenant** — dedicated DB/cluster, encrypted DSN (regulated / enterprise SLA).
4. **Tenant-owned** — the customer brings their own database; the mount is theirs alone (BYO-database).

**5 tiers (measured shapes, not invented plans)** — `make up PACKAGE=<tier>`:

| Tier | Running RAM | Services | Engines | Retail | Best for |
|---|---|---|---|---|---|
| **Nano** | 2.0 MiB (1 static binary, 5.1 MB) | 1 | SQLite | Free / $5 | landing pages, prototypes, machine-to-machine |
| **Basic** | ~460 MiB | 11 (0 Node) | SQLite, PostgreSQL | Free / $9 | a private app, on a Pi or $5 VPS |
| **Essential** | ~950 MiB | 19 | +aggregate | $25–39 | one full-feature product |
| **Pro** | ~1.4 GiB | 28 | +MySQL/Mongo/Redis/Cockroach +batch +transactions | $59–99 | a multi-engine SaaS w/ realtime + storage |
| **Max** | ~3.1 GiB | 41 | +MSSQL/HTTP +DDL +analytics +functions | $149–299 | a multi-tenant cloud platform |

**À-la-carte add-ons** (start lean, bolt on only what you need): `realtime` · `analytics` (Trino+Iceberg) · `storage` (MinIO/S3) · `observability` (Loki/Grafana/Prometheus) · `functions` (Deno edge) · `engines` (MariaDB/Cockroach/MSSQL). This is the "no static build" promise — composable, à-la-carte, priced per piece.

**The lighter/faster package vs PocketBase** (the wedge — all measured, gate-proven, official PB binary, same box):
- **binocle-nano** = 5.2 MB headless data plane (CRUD + filters + aggregates + graph + scoped keys + SSE), 2.0 MiB idle.
- **binocle-one** = 6.4 MB *"our PocketBase"*: accounts (password, OAuth2 matrix, OTP, **TOTP MFA**), typed collections, files w/ thumbnails, filtered realtime, **embedded admin dashboard at `/_/`** — 2.2 MiB idle.
- PocketBase v0.39 = 30.1 MB binary, ~12 MiB idle.
- **One is 4.7× smaller than PocketBase with the dashboard embedded.**
- insert @ c=64: **9,283 RPS vs 2,463 (3.8×)** · RSS under load: **15.4 MiB vs 406 MiB (26×)** · boot→first 200: **5 ms vs 120 ms (24×)** · 100k-row insert in ~11 s.
- **Honest loss (keep it on the board):** PocketBase serves ~1.3× more list-RPS at high concurrency, and has embedded JS hooks we don't. *Our* list p99 is 3.6× better. We say so — honesty is part of the brand.
- The kicker PocketBase structurally cannot match: **graduate One → Basic → … → Max on the same SDK, zero rewrites.** PocketBase is SQLite-forever; outgrow it and you migrate platforms.

**Complete backend surface (9 capabilities):** Auth (GoTrue: JWT, MFA, OAuth, scoped API keys) · Realtime CDC (Postgres logical replication + Mongo change streams → WebSocket; O(1) bitmap subscription matching, 3–6 µs/event regardless of subscriber count) · Object storage (S3-compatible MinIO, presigned URLs — files never transit the API) · Graph queries (Obsidian-style relationship subgraph across databases) · Atomic transactions (`/query/v1/txn`, integrity violations → honest 409s) · ABAC + field masks (per-column hide/redact, in the 3.3 MiB Rust plane) · Webhooks (HMAC-signed, 6.8 MiB Go daemon) · Edge functions (Deno, worker-per-invocation) · Email & GDPR (transactional mail, double-opt-in newsletter, consent/export/deletion).

**Multi-tenant density (measured):** 10,000 live tenants in **30 MiB** of data plane; warm serving ~2 ms/req; with shared pools, **1 connection pool for all 10,000 tenants, 0 evicted**.

**Honest competitor verdicts** (every rival gets a real "choose them if"):
- **Supabase** — "Excellent, if Postgres is your only engine." They win on Studio polish + ecosystem maturity. We win on 8 engines, 4 isolation models, self-host floor (2 MiB vs multi-GB), cost transparency, no-rewrite grow path.
- **PocketBase** — "Everything it does, in 1/5th the binary — measured, faster under load." They win on JS hooks + raw list-RPS. We win on size, throughput, aggregation, graph, field masking, and the graduation path.
- **Firebase** — "Their cloud, their data model, their bill. Or yours." They win on managed convenience + offline mobile sync. We win on open engines, self-host, predictable flat pricing.

**The optional dashboard product (a real differentiator):** Grobase ships a **Notion-like database management ecosystem** (the osionos `notion-database-sys`) — collaborative block-editor pages where databases live as full-page blocks, with table / kanban / timeline / gallery views, draggable-resizable **dashboard widgets** (widgets *are* views, ≤4 per row, ≤12 total), global filters, formula analytics (KPI cards + pie/bar/line charts), and live data grids. The pitch: **"Manage your backend graphically, or dive into the server. Your choice."** It is an *opt-in, ultra-customizable add-on* — take it if you want to run your data like a product team runs Notion; skip it and use the raw API. Style it cinematic-dark à la `neuralyn.md`.

## 2. Tech stack (exact — do not substitute)

- **Vite + React 18 + TypeScript**, strict mode.
- **Tailwind CSS 3** with a custom theme that maps the design tokens in §3 to utility classes (extend `colors`, `fontFamily`, `borderRadius`, `transitionTimingFunction`). No other CSS framework.
- **GSAP 3** + **ScrollTrigger** (scroll-driven timelines, pinning) — the only animation engine for DOM/scroll. (GSAP plugins are free as of 2025.)
- **Lenis** (`lenis`) for smooth inertial scroll, synced to GSAP's ticker (drive `lenis.raf` from `gsap.ticker.add`, and `ScrollTrigger.update` on Lenis `scroll`). lerp `0.1`.
- **three.js** + **@react-three/fiber** + **@react-three/drei** + **@react-three/postprocessing** (for `<Bloom>`) — for the persistent galaxy and all 3D. Particles are a single `THREE.Points` with a custom GLSL `ShaderMaterial` (additive blending). Use **maath** (`maath/random`, `maath/easing`) for point distributions and damping.
- **lucide-react** for all icons.
- **Fonts** via `@fontsource`: **Sora** (600/700, display + headings), **Inter** (400/500/600, body + UI), **IBM Plex Mono** (400/500, kickers, code, prices, stats). Headings use Sora; mono is used for every all-caps kicker label and every measured number.
- No jQuery, no Bootstrap, no other 3D or scroll lib. Keep `node_modules` lean — this is a performance product.

## 3. Design system (exact tokens — reuse the real Grobase brand)

Define these as CSS custom properties on `:root` (dark by default) and wire them into the Tailwind theme.

**Canvas & surfaces**
```
--gb-bg:          #05070d   /* deep-space background */
--gb-bg-raised:   #0a0f1a
--gb-surface:     #0d1424   /* cards */
--gb-surface-2:   #121b30
--gb-line:        rgb(148 163 198 / 18%)
--gb-line-strong: rgb(148 163 198 / 32%)
```
**Ink (text)**
```
--gb-text:       #e9eef7
--gb-text-muted: #a3b0c6
--gb-text-faint: #7a8aa6
```
**Brand**
```
--gb-primary:        #34d399   /* signal emerald — primary action color */
--gb-primary-strong: #10b981
--gb-primary-ink:    #04281b   /* text ON emerald fills */
--gb-accent:         #fbbf24   /* amber */
--gb-accent-ink:     #2b1f02
--gb-danger:         #f87171
```
**Engine node colors** (used in the galaxy + engine strip + configurator)
```
postgres #7dd3fc · mysql #fb923c · mongodb #4ade80 · sqlite #a5b4fc
redis #f87171 · cockroach #c084fc · mssql #f472b6 · http #fde047
```
**Tier colors** (galaxy clustering + pricing cards)
```
nano #34d399 · basic #7dd3fc · essential #a78bfa · pro #fbbf24 · max #f472b6
```
**Plane colors** (architecture section)
```
ts #7dd3fc · go #67e8f9 · rust #fb923c
```
**Glows & motion**
```
--gb-glow-primary: 0 0 42px rgb(52 211 153 / 22%);
--gb-glow-card:    0 18px 60px rgb(2 6 18 / 60%);
--gb-radius-sm: 8px;  --gb-radius: 14px;  --gb-radius-lg: 22px;
--gb-dur-fast: 160ms; --gb-dur-slow: 420ms;
--gb-ease-out: cubic-bezier(0.22, 1, 0.36, 1);
```
**Fluid type scale**
```
--gb-text-xs: 0.78rem · --gb-text-sm: 0.9rem · --gb-text-base: 1rem
--gb-text-lg:   clamp(1.1rem, 1rem + 0.4vw, 1.3rem)
--gb-text-xl:   clamp(1.35rem, 1.15rem + 0.9vw, 1.9rem)
--gb-text-2xl:  clamp(1.8rem, 1.4rem + 1.8vw, 2.9rem)
--gb-text-hero: clamp(2.5rem, 1.8rem + 3.6vw, 4.6rem)
```

**Liquid-glass utility** (floating UI throughout — nav pill, chips, configurator panel). Add this exact class:
```css
.liquid-glass {
  background: rgba(255,255,255,0.02);
  backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px);
  border: none; position: relative; overflow: hidden;
  box-shadow: inset 0 1px 1px rgba(255,255,255,0.10), var(--gb-glow-card);
}
.liquid-glass::before {
  content:''; position:absolute; inset:0; border-radius:inherit; padding:1.4px;
  background: linear-gradient(180deg,
    rgba(255,255,255,0.45) 0%, rgba(255,255,255,0.15) 20%,
    rgba(255,255,255,0) 40%, rgba(255,255,255,0) 60%,
    rgba(255,255,255,0.15) 80%, rgba(255,255,255,0.45) 100%);
  -webkit-mask: linear-gradient(#fff 0 0) content-box, linear-gradient(#fff 0 0);
  -webkit-mask-composite: xor; mask-composite: exclude; pointer-events:none;
}
```
**Voice:** confident, technical, honest. Mono kickers in `--gb-text-faint` uppercase tracking-widest. Headings tight tracking (`-0.02em`). Emerald is reserved for the single most important action on screen. Never overuse it.

## 4. Global behaviors

- **Layout shell:** a fixed full-viewport `<Canvas>` (the galaxy) at `z-0`, `pointer-events-none`; all page content scrolls above it in a column at `z-10`. The galaxy is *one* persistent scene for the whole page — never remounted per section.
- **Smooth scroll:** Lenis on `<html>`, synced to GSAP. All ScrollTriggers use the Lenis scroller.
- **Preloader (boot sequence):** full-screen `--gb-bg`. Centered: a single emerald point, and an IBM Plex Mono counter `00 → 100` plus rotating status lines: `provisioning data plane…`, `mounting engines…`, `compiling 3.3 MiB of Rust…`, `your backend is ready.` On 100, GSAP timeline: the single point *bursts* into the full galaxy (drive a shader uniform `uReveal 0→1`), counter and lines fade up-and-out, hero content staggers in. Then call `ScrollTrigger.refresh()`. Total ≤ 2.2 s; if assets load faster, don't stall artificially.
- **`prefers-reduced-motion: reduce`:** disable Lenis (native scroll), freeze the galaxy to a static seeded starfield (no rotation/morph; render once), replace all entrance animations with instant opacity, no pinning. The page must be fully legible and navigable.
- **Performance budget:** lazy-mount the `<Canvas>` and postprocessing after first paint; cap `devicePixelRatio` at 2; scale particle count by device (`min(window.innerWidth*8, 14000)`, halve on mobile / when `navigator.hardwareConcurrency ≤ 4`); pause `requestAnimationFrame` when the tab is hidden and when the canvas is fully scrolled out of view. Target Lighthouse perf ≥ 90 desktop, ≥ 70 mobile; no layout shift (CLS < 0.05).
- **Responsive:** mobile-first. On < 768px the galaxy stays but morphs are simplified (no pinning of heavy sections — convert pinned scenes to stacked reveals), the configurator becomes a single-column stepper, the nav collapses to a glass sheet.
- **Accessibility:** the galaxy is `aria-hidden`. All content has semantic landmarks, foc-visible rings (`outline` emerald), keyboard-operable configurator and tabs, WCAG-AA contrast on all text (the muted inks pass on `--gb-bg`). Every interactive 3D affordance has a non-3D fallback control.

## 5. The galaxy — the spine of the experience (three.js, persistent)

One `THREE.Points` cloud of N tenant-particles in a fixed full-page Canvas behind all content. This is the single most important build artifact; get it right.

- **Geometry:** N points (see budget). Per-point attributes: `aPosition` (current home for the active state), `aTarget` (next state's home — for morphing), `aColor` (vec3), `aSeed` (float, for per-point stagger/jitter), `aSize` (float).
- **Material:** custom `ShaderMaterial`, `transparent`, `depthWrite:false`, `blending: AdditiveBlending`. Vertex shader lerps `mix(aPosition, aTarget, uMorph)` with an eased, **per-point staggered** `uMorph` (offset by `aSeed`) so the cloud reorganises organically, not in lockstep; soft size attenuation by distance; gentle sine drift by `uTime + aSeed`. Fragment shader draws a soft radial-falloff disc (circular, glowing core), colored by `vColor`, faded by `uReveal` (preloader) and a global `uOpacity`.
- **Post:** `<EffectComposer><Bloom intensity≈0.9 luminanceThreshold≈0.1 mipmapBlur/></EffectComposer>` — the emerald/violet glow is the signature. Add the faintest vignette.
- **Camera:** slow continuous Y-rotation of the whole cloud (~0.02 rad/s); subtle mouse-parallax on camera position (damped via `maath/easing.damp3`, max ±0.4 units). Never let interaction fight the scroll narrative.
- **States (morph targets) — driven by ScrollTrigger, one per story beat.** Each state precomputes an `aTarget` layout and a color mapping; scrolling between sections tweens `uMorph 0→1` then swaps target→position and loads the next target. States, in scroll order:
  1. `nebula` (Hero) — a loose rotating spiral/sphere; colors cycle the 5 tier colors. "A galaxy of tenants."
  2. `engines` — particles fly into **8 clusters**, recolored by engine palette. Each cluster sits behind/near its engine card.
  3. `tiers` — regroup into **5 concentric rings/clumps**, recolored by tier palette; ring radius grows nano→max.
  4. `isolation` — split into **4 rings**, recolored: dense core (shared RLS) → wider rings (schema, db, tenant-owned).
  5. `planes` — collapse into **3 columns/bands** colored ts/go/rust.
  6. `converge` (Final CTA) — all particles spiral inward to a single bright emerald core, then gently breathe. "Yours would be one of these."
- **Interactivity (desktop only):** in the `nebula` and `engines` states, the nearest particle to the cursor brightens and shows a tiny glass tooltip — a fictional-but-plausible tenant line, e.g. `tenant_4821 · postgres+redis · Pro · schema-per-tenant`. Cheap nearest-neighbour against a thinned subset; never per-frame over all N.

## 6. Section-by-section build (scroll order, exact copy)

Wrap each section in `<section data-galaxy-state="…">`; an IntersectionObserver/ScrollTrigger reads the attribute to set the galaxy state. Kicker = IBM Plex Mono, uppercase, `--gb-text-faint`, `text-xs tracking-[0.2em]`. Headings = Sora. Use `[data-rise]` for staggered entrance (GSAP: from `opacity:0, y:26` → `0`, `ease: --gb-ease-out`, stagger `0.08`, triggered at `top 80%`).

### 6.1 Navbar (fixed, `z-30`)
Glass pill, `liquid-glass rounded-full px-6 py-3 max-w-6xl mx-auto mt-5 flex items-center justify-between`.
- Left: emerald orbit/binocular logo glyph + wordmark **"Grobase"** (Sora 700, `text-lg`), gap-2. Beside it (md+, gap-8): nav links **Engines · Compose · Pricing · Compare · Docs** (`text-sm text-[--gb-text-muted] hover:text-[--gb-text] transition-colors`), each scroll-anchored to its section with a Lenis smooth-scroll-to.
- Right (gap-3): **"Sign in"** (plain text button) + **"Start free"** (solid emerald `bg-[--gb-primary] text-[--gb-primary-ink] rounded-full px-5 py-2 text-sm font-semibold`, hover `scale 1.03`).
- On scroll past hero, the pill shrinks slightly and its blur deepens (GSAP scrub).

### 6.2 Hero — `data-galaxy-state="nebula"` (full viewport)
Centered column over the galaxy.
- Tag pill (glass): `New` badge (emerald) + **"Compose your backend — don't build one."**
- **H1** (`--gb-text-hero`, Sora 700, leading-[1.05], tracking-tight): **"One backend.** *Every engine.* **Any size."** — "Every engine." in an italic accent (use Sora italic or layer an Instrument-Serif-style accent; keep it emerald-tinted gradient text).
- **Lede** (`--gb-text-lg`, max-w-2xl, `--gb-text-muted`): *"Auth, data, realtime, storage, graph and functions over 8 database engines — from a 5 MB single binary to a multi-tenant cloud. Each star in this galaxy is a tenant running its own backend. Yours would be one of them."*
- CTAs (row, gap-3): primary **"Compose your backend"** (emerald, scrolls to §6.7); ghost **"See the honest comparison"** (glass, scrolls to §6.10).
- Stat chips row (glass pills, mono): `3.3 MiB Rust hot path` · `8 ms p50 / req` · `8 engines · 1 API` · `$2/mo floor`.
- Bottom-center hint (mono, faint, gently bobbing): **"scroll — the galaxy reorganises with the story ↓"**.
- Hero content group has a ScrollTrigger scrub: `y:0→-180, opacity:1→0` over the first viewport of scroll, so it dissolves into the galaxy.

### 6.3 The Why — `data-galaxy-state="nebula"` (scroll-pinned word reveal)
Pin this section ~150vh. Big statement, left-aligned, max-w-4xl, built as individual `<span>` words.
- Kicker: **WHY GROBASE EXISTS**.
- Statement (`--gb-text-2xl`+, Sora 600), each word a `motion span` revealed by scroll progress (map word index → range `[i/total,(i+1)/total]`, `color: --gb-text-faint → --gb-text`): *"You shouldn't be building a back-end. You should be modelling your business and shipping a front-end. Grobase is the entire server side — already built, already secure, already fast — waiting over plain HTTP. Forget the back-end exists."*
- As the words light up, the galaxy slowly densifies (raise `uOpacity`). End the pin on the line **"Forget the back-end exists."** held bright for a beat.

### 6.4 Engines — `data-galaxy-state="engines"`
- Kicker: **ENGINE-AGNOSTIC** · H2 (Sora): **"One API. Eight engines."**
- Lede: *"The platform never needs to know the shape of your data. Every engine answers the same `/query/v1` call — pick per mount, mix per tenant, swap without rewriting."*
- A responsive grid (4×2 desktop / 2×4 tablet / 1col mobile) of 8 **engine cards**, each: a glowing orb in the engine's color, the name, and a one-line role. On hover/focus: card lifts (`y:-6`, glow ring in engine color), and the galaxy's matching cluster pulses brighter (set a uniform highlighting that engine's color group). Roles:
  - **PostgreSQL** — "flagship OLTP · RLS · logical-replication CDC"
  - **MySQL / MariaDB** — "pure-Rust driver · full CRUD"
  - **MongoDB** — "documents · change-stream CDC"
  - **SQLite** — "embedded in-process · zero extra RAM"
  - **Redis** — "cache · session · KV"
  - **CockroachDB** — "distributed SQL · Postgres dialect"
  - **MSSQL** — "TDS protocol · pure-Rust tiberius"
  - **HTTP** — "federate any JSON API as a mount"
- Below the grid, a glass code card (IBM Plex Mono, syntax-tinted) showing the capability-typed SDK, with one line visibly *erroring*:
  ```ts
  const db = grobase.mount({ engine: 'postgres', isolation: 'shared-rls' })
  await db.from('orders').select().filter({ status: 'paid' })   // ✓

  const cache = grobase.mount({ engine: 'redis' })
  cache.subscribe('events')   // ✗ Type error: 'redis' advertises stream:false
  ```
  Caption: *"Impossible operations fail at compile time — not at 3 a.m."*

### 6.5 Architecture — `data-galaxy-state="planes"`
- Kicker: **THREE LANGUAGES, THREE PLANES** · H2: **"Each plane gets the language its job deserves."**
- Lede: *"TypeScript where business rules change daily. Go for always-up control daemons. Rust where every millisecond and mebibyte counts."*
- Three vertical plane columns (colored ts/go/rust), connected by animated data-flow dots (GSAP) running top→bottom on scroll: **TypeScript** (orchestration, SDKs — "changes daily") → **Go** (tenancy, secrets vault, webhooks — "always up") → **Rust** (the hot path — "3.3 MiB · 8 ms/req").
- Hero stat, animated counters that count up on enter: **"127 MiB → 3.3 MiB"** with subline *"~38× lighter · 5× faster than the TypeScript it replaced."* Make the "127" shrink visually into "3.3" with a GSAP morph.

### 6.6 The lighter package — vs PocketBase — `data-galaxy-state="tiers"`
The "lighter & faster" wedge the brief asks for.
- Kicker: **THE FEATHERWEIGHT EDITION** · H2: **"Everything PocketBase does — in a fifth of the binary."**
- Lede: *"Two single-file answers: **Nano** (5.2 MB, headless data plane) and **One** (6.4 MB) — accounts, the full OAuth2 matrix, TOTP MFA, files with thumbnails, filtered realtime, and an embedded admin dashboard. Feature parity is gate-proven. When you outgrow SQLite, you graduate tiers — you don't migrate platforms."*
- Three **animated comparison bars** (GSAP scrub, fill on enter), each labelled, Grobase emerald vs PocketBase grey:
  - **Binary size** — Grobase One `6.4 MB` vs PocketBase `30.1 MB` (4.7×)
  - **RSS under c=64 load** — `15.4 MiB` vs `406 MiB` (26×)
  - **Insert throughput @ c=64** — `9,283 RPS` vs `2,463 RPS` (3.8×)
  - **Boot → first 200** — `5 ms` vs `120 ms` (24×)
- An **honesty card** (glass, amber left-border): *"Honest loss: PocketBase serves ~1.3× more list-RPS at high concurrency and has embedded JS hooks we don't — yet. Our list p99 is 3.6× better. We measure everything and we tell you when we lose."* — this honesty box is a brand signature; make it prominent, not buried.

### 6.7 Compose your backend — the configurator — `data-galaxy-state="engines"` ⭐
**The centerpiece interactive experience.** This is the product's thesis made tangible: *no static build.* Pin or sticky-left this section so the live galaxy/architecture reacts as the visitor configures.

- Kicker: **NO STATIC BUILDS** · H2: **"Compose the exact backend you need."** · Lede: *"Choose your engines. Choose your services. Take a prebuilt package — or just the one piece that interests you. The price moves with you. The galaxy rebuilds in real time."*

Layout: two panes (stack on mobile into a stepper). **Left = controls** (glass panel). **Right = a live readout**: an animated architecture diagram (or a focused sub-galaxy) that adds/removes nodes as toggles change, plus a big live price.

**Controls (left):**
1. **Start from a package** (segmented control): `Nano · Basic · Essential · Pro · Max · Custom`. Selecting one preselects the engines/services/limits below and snaps the price; touching any toggle flips to `Custom`.
2. **Engines** (multi-select chips, engine-colored): Postgres, MySQL, MongoDB, SQLite, Redis, CockroachDB, MSSQL, HTTP. Each adds to price; respect tier rules (e.g. Nano = SQLite only — show a soft "upgrade to add Postgres" hint, mirroring the real `403 engine_not_in_package`).
3. **Services** (toggles, with optional quantity steppers where it makes sense): Auth · Realtime · Object storage · Graph · Transactions · ABAC + field masks · Webhooks · Edge functions · Email & GDPR · **Notion dashboard add-on**.
4. **Isolation model** (radio): Shared RLS · Schema per tenant · DB per tenant · Tenant-owned — with the one-line tradeoff for each.
5. **Scale** (slider): expected tenants / rps — nudges the recommended tier and price.

**Right (live readout):**
- A big animated **price** in IBM Plex Mono (`--gb-text-2xl`, emerald) that *rolls* (GSAP `snap`/counter) whenever the config changes, with a `/mo` suffix and a faint "≈ infra cost, ×3 retail" breakdown line. Use the real anchors: Nano ~$2 floor → Max ~$41 infra. Compute a transparent additive estimate from the selected pieces; show the arithmetic on a "how is this calculated?" expander (honesty again).
- The **architecture readout** animates: every selected engine spawns a colored node wired to a central Grobase core; every service lights its icon; isolation choice changes how tenant dots cluster. Use GSAP for node enter/exit (`scale 0→1`, `--gb-ease-out`) and animated connector lines.
- A **"matched tier" badge** that updates live ("This composition = **Pro**, ~$21/mo infra, serves <$1/tenant amortized").
- CTA under it: **"Provision this backend"** (emerald) + **"Copy as `make up` command"** (glass) that copies e.g. `make up PACKAGE=pro ADDONS="realtime storage"` to clipboard with a toast.

Make this section feel *alive and rewarding* — every toggle should produce immediate, satisfying motion in both the price and the diagram. This is the moment a visitor "gets it."

### 6.8 Isolation — `data-galaxy-state="isolation"`
- Kicker: **MULTI-TENANT DNA** · H2: **"Isolation is a dial, not a rebuild."**
- Lede: *"Four isolation models, selectable per mount — dense and cheap for small tenants, hard walls for regulated ones, or the tenant's own database."*
- An interactive **dial / 4-stop slider**; moving it morphs the galaxy between its 4 isolation rings and swaps the explanatory card:
  1. **Shared RLS** — "One database, rows filtered by tenant. Cheapest, densest. → many small tenants."
  2. **Schema per tenant** — "A private schema each. → noisy-neighbour isolation."
  3. **Database per tenant** — "A dedicated DB/cluster, encrypted DSN. → regulated / enterprise SLA."
  4. **Tenant-owned** — "The customer brings their own database; the mount is theirs alone. → bring-your-own-database."
- Footnote stat: *"10,000 live tenants in 30 MiB of data plane · ~2 ms warm · one shared pool for all of them."* (animated counter to 10,000).

### 6.9 The complete surface — `data-galaxy-state="planes"`
- Kicker: **A COMPLETE BACKEND SURFACE** · H2: **"Everything your server code was doing."**
- Lede: *"No per-project server code. Any frontend treats Grobase as its whole backend, over plain HTTP."*
- A 3×3 grid of glass feature cards (lucide icon + title + one line), `[data-rise]` staggered:
  1. **Auth that just works** — "GoTrue: JWT sessions, MFA, OAuth, scoped API keys + HMAC service identities."
  2. **Realtime CDC** — "Logical replication + change streams → WebSocket. O(1) matching: 3–6 µs/event, any subscriber count."
  3. **Object storage** — "S3-compatible MinIO, presigned URLs — your files never transit the API."
  4. **Graph queries** — "Obsidian-style subgraphs across databases, in one call."
  5. **Atomic transactions** — "`/query/v1/txn` — multi-statement batches; integrity violations → honest 409s."
  6. **ABAC + field masks** — "Per-column hide/redact, in the 3.3 MiB Rust plane — not bolted on."
  7. **Webhooks** — "HMAC-signed delivery from the outbox, by a 6.8 MiB Go daemon."
  8. **Edge functions** — "Deno worker-per-invocation, for the logic that belongs server-side."
  9. **Email & GDPR** — "Transactional mail, double-opt-in newsletters, consent + export + deletion."

### 6.10 The dashboard add-on — Notion-like, cinematic — `data-galaxy-state="tiers"`
Style this section after `neuralyn.md`: cinematic-dark, a large dashboard visual with parallax, glass framing, `mixBlendMode: luminosity` on the screenshot.
- Kicker: **AN OPTIONAL ECOSYSTEM** · H2: **"Run your data like a product — or dive into the server."**
- Lede: *"Add the Grobase dashboard: a Notion-style workspace where your databases live as pages. Table, kanban, timeline and gallery views; draggable, resizable dashboard widgets; global filters; formula analytics with live charts. Manage everything graphically — or skip it and use the raw API. Your choice."*
- A wide **dashboard mock** (`max-w-5xl`, `rounded-2xl`, glass frame): left a Notion-like page tree, center database widgets (a data grid + a kanban + KPI cards + a small line/pie chart), a global filter bar. Parallax on scroll (`y: 0 → -120`). If you can't render a live mock, use a high-fidelity static mock styled to the tokens; animate widgets fading/lifting in.
- A small caption strip: **"Widgets are views · ≤4 per row · drag to rearrange · resize at 60 fps · charts from your real columns."**
- CTA: **"Add the dashboard"** (glass) — framed clearly as an *opt-in add-on*, not bundled.

### 6.11 Grow path / Pricing — `data-galaxy-state="tiers"`
- Kicker: **THE PROMISE** · H2: **"Start on Nano. Graduate to Max. Never rewrite."**
- Lede: *"Every tier runs the same codebase and speaks the same SDK. PocketBase makes you migrate off when you grow; Firebase makes leaving expensive. Grobase makes growth a deployment decision."*
- 5 **tier cards** in a row (horizontal-scroll/snap on mobile), each tier-colored top-border, with subtle 3D tilt on hover (GSAP, max ±6°). Per card: name, RAM, services, retail, "best for", a short feature list, CTA. Use the §1 table verbatim. The galaxy clusters into the 5 tier rings behind them; the card under cursor pulses its tier ring.
- Add a small **"…or just the pieces you want"** rail under the cards: the 6 à-la-carte add-on chips (`realtime · analytics · storage · observability · functions · engines`) with a one-line each — reinforcing composability.
- A transparency note (glass, faint): *"Every RAM number is measured live (`make bench-footprint`). Retail = infra floor × ≥3, or amortized < $1/tenant multi-tenant. We show the arithmetic."*

### 6.12 Honest comparison — `data-galaxy-state="nebula"`
- Kicker: **THE HONEST COMPARISON** · H2: **"We tell you when to choose someone else."**
- Three competitor panels (tabs or stacked), each with verdict, a short matrix, and a real "choose them if" honesty box. Use the §1 verdicts and the SUMMARY_AXES row (Engines 8 vs 1/1/proprietary · Self-host floor 5.2 MB/2 MiB vs multi-GB/30 MB/cloud · Isolation 4 vs RLS/single/rules · Field masking yes vs no · Graph yes vs no · Grow path Nano→Max vs vertical/migrate/locked-in). Win/lose/tie pills (emerald/grey/neutral). Keep the losses honest — that is the differentiator.

### 6.13 Final CTA — `data-galaxy-state="converge"`
The galaxy spirals into a single breathing emerald core behind this.
- H2 (Sora, `--gb-text-2xl`+): **"Ship the front. We are the back."**
- Sub: *"Compose your backend in minutes. Forget it exists forever."*
- Big emerald CTA **"Start free on Nano"** + ghost **"Read the docs"**. Mono line beneath: `docker compose up` · `5 MB` · `$0 to start`.

### 6.14 Footer
Glass top-border. Columns: Product (Engines, Compose, Pricing, Dashboard, Compare) · Developers (Docs, SDK, API, Self-host guide) · Company (About, Honesty, Security, GDPR) · a newsletter glass input (`Enter your email` + emerald arrow button, à la `curious.md`). Bottom row: wordmark, "© Grobase", "Built engine-agnostic.", social icon buttons (glass circles, lucide). A final faint mono line: *"Every number on this page is measured. `make bench-footprint` to reproduce."*

## 7. Animation & interaction acceptance criteria

- The galaxy morphs smoothly between all 6 states with no frame hitching on a mid-range laptop; morphs are per-point staggered, never lockstep.
- Scroll feels weighted and inertial (Lenis), and every pinned section unpins cleanly (no jump). `ScrollTrigger.refresh()` after fonts + preloader.
- The configurator updates price **and** diagram within one frame of any toggle, with satisfying motion on both.
- Hover on engine cards / tier cards visibly drives the galaxy.
- `prefers-reduced-motion` yields a calm, static, fully-usable page.
- Nothing blocks first paint on the 3D; the hero text is readable before the galaxy mounts.

## 8. Assets to generate or stub
- `logo.svg` — emerald binocular/orbit glyph for "Grobase".
- 8 engine glyphs (or use lucide `Database`/`Server`/`HardDrive`/`Network` tinted per engine color).
- `dashboard-mock.png` (or a built React mock) for §6.10, styled to the tokens — Notion-like page tree + grid + kanban + KPI + chart.
- A small particle disc sprite is **not** needed — draw the point in the fragment shader.
- Favicon + OG image (`og.png`, dark, galaxy + "One backend. Every engine. Any size.").

## 9. Deliver
A runnable Vite app: `npm i && npm run dev`. Single-page, all sections in scroll order above, the persistent galaxy behind everything, the configurator fully interactive, copy verbatim from this spec, brand tokens exact. Lighthouse perf ≥ 90 desktop. It should make a senior engineer trust the performance claims **because the site itself is fast**, and make a non-technical founder think *"I never have to build a back-end again."*
