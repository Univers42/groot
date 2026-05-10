# Prismatica frontend redesign plan

> Living roadmap. Each phase is independently shippable, fully reversible, and
> guarded by `npm run check`, `npm run build`, `npm run verify:sdk-boundaries`
> and `npm run test:security`.
>
> See also: [`contrast-audit.md`](./contrast-audit.md) (the source of truth for
> what colors must change), and the two-layer token system in
> [`src/styles/abstracts/_brand-tokens.scss`](../src/styles/abstracts/_brand-tokens.scss)
> + [`src/styles/abstracts/_system-tokens.scss`](../src/styles/abstracts/_system-tokens.scss).

---

## North star

A **two-layer design system**:

| Layer       | Prefix       | Purpose                                                              | Where it lives                                                |
| ----------- | ------------ | -------------------------------------------------------------------- | ------------------------------------------------------------- |
| **Brand**   | `--brand-*`  | The hand-drawn marketing personality — paper, ink, mascot, sketch.   | Hero, mascot, story sections, illustrations, marketing pages. |
| **System**  | `--system-*` | The clean professional product UI.                                   | Forms, dialogs, inputs, status, dashboards, legal, portal.    |

**Rule of thumb**: if a user is *making a decision that has consequences*
(submitting a form, agreeing to terms, deleting data), we render in the system
layer. Marketing copy stays in the brand layer.

The legacy alias barrel ([`_tokens.scss`](../src/styles/abstracts/_tokens.scss))
remaps every pre-existing token to its new layer equivalent so consumers compile
unchanged. Migration to direct `--system-*` references is incremental.

---

## Phase 0 — done

- ✅ **C** — Contrast audit ([`contrast-audit.md`](./contrast-audit.md))
- ✅ **B** — Two-layer token system, all P0/F1–F5 fixed at the alias level
  - `_brand-tokens.scss`, `_system-tokens.scss`, `_tokens.scss` (barrel),
    `_color-modes.scss` (per-theme overrides for both layers)
- ✅ **A** — Portal converted to native `<dialog>`; `frame-ancestors` removed
  from meta-CSP (must be set as an HTTP response header)

---

## Phase 1 — Portal as a static component (Step E)

**Goal**: pre-render the dialog markup at build time so we no longer inject
~2 KB of HTML through `trustedHTML()` on every open. Lazy-load Turnstile only
when the dialog is opened.

| Step | Change                                                                                                  | File                                                          |
| ---- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| 1    | New `Portal.astro` component owning the markup that `createPortalMarkup()` currently generates.         | `src/components/ui/Portal.astro`                              |
| 2    | Mount `<Portal />` once per layout, hidden by default (the native `<dialog>` does that automatically).  | `src/layouts/Layout.astro`                                    |
| 3    | `main.ts.openPortal()` switches from `insertTrustedHTML()` to `document.querySelector('dialog#portal')`. | `src/scripts/main.ts`                                         |
| 4    | Remove the `<script is:inline … turnstile/v0/api.js>` from `Layout.astro`. Inject it on first open from `openPortal()`. | `src/layouts/Layout.astro`, `src/scripts/main.ts` |
| 5    | Update CSP `script-src` accordingly (still allows `https://challenges.cloudflare.com`).                 | `src/layouts/Layout.astro`                                    |

**Acceptance**:

- Lighthouse Best Practices ≥ 95 on `/` and `/auth/reset-password`
- Time-to-interactive on `/` drops by ~120 ms (Turnstile no longer eager)
- `dialog.showModal()` still works without a redraw
- ESC, focus restoration, backdrop-click close all still pass keyboard tests

---

## Phase 2 — `main.ts` decomposition

Today `src/scripts/main.ts` is a single ~2 400-line module that mixes mascot
animation, theme switching, BaaS connection state, portal lifecycle, consent,
and notifications. We split it (no functional change) into single-responsibility
modules co-located under `src/scripts/`.

| New module             | Owns                                                                | Surface                                          |
| ---------------------- | ------------------------------------------------------------------- | ------------------------------------------------ |
| `mascot.ts`            | SVG mascot, mood transitions, gaze tracking, idle behaviour         | `initMascot()`, `setMood()`                      |
| `portal.ts`            | Dialog open/close, form wiring, validation, submission orchestration | `openPortal(mode)`, `closePortal()`             |
| `theme.ts`             | `data-theme` switching, `prefers-color-scheme` listener             | `initTheme()`, `setTheme()`                      |
| `baas-status.ts`       | BaaS health probes, retry/backoff, status indicator                 | `initBaasStatus()`                               |
| `consent.ts`           | Cookie/consent banner, persisted choices                            | `initConsent()`                                  |
| `notifications.ts`     | Already separate today; keep, ensure no two-way coupling.           | unchanged                                        |
| `dom.ts` (helpers)     | `queryElement`, `queryElements`, `isHtmlElement`, `insertTrustedHTML`, `announce` | shared utilities                  |
| `main.ts` (entry)      | Wiring only — calls the `init*` functions in order.                 | side-effect entry from `Layout.astro`            |

**Migration sequence** (one PR each, behind no flag — pure refactor):

1. Extract `dom.ts` shared helpers; ensure no circular imports.
2. Extract `theme.ts` (smallest, lowest risk).
3. Extract `mascot.ts`.
4. Extract `consent.ts`.
5. Extract `baas-status.ts`.
6. Extract `portal.ts`.
7. `main.ts` becomes ~30 lines of `init*()` calls.

**Acceptance after each step**: `npm run check`, `npm run build`,
`npm run verify:sdk-boundaries`, `npm run test:security` all green; manual
smoke on `/` (mascot, theme toggle, portal open/close, consent banner).

---

## Phase 3 — Self-host fonts

Today `Layout.astro` loads from `https://fonts.googleapis.com`. That:

- Adds two TLS handshakes to first paint.
- Leaks visitor IPs to a third party — friction with our GDPR posture
  (see [`docs/gdpr/data-map.md`](./gdpr/data-map.md)).
- Means we cannot guarantee the asset bytes (CSP allowlist, not pin).

**Plan**:

1. Pick the exact subsets we need:
   - **Brand layer**: Caveat (400, 600, 700), Caveat Brush (400),
     Kalam (400, 700), Architects Daughter (400), Special Elite (400).
   - **System layer**: Inter (400, 500, 600, 700) — only sub-Latin needed for
     the current locales.
2. Download `woff2` files into `opposite-osiris/public/fonts/`.
3. Add `@font-face` declarations in
   `src/styles/abstracts/_typography.scss` with `font-display: swap` and
   `unicode-range` matching the chosen subset.
4. Add `<link rel="preload" as="font" type="font/woff2" crossorigin>` for the
   two fonts that appear above the fold (Inter 400, Caveat 600).
5. Remove `https://fonts.googleapis.com` and `https://fonts.gstatic.com` from
   `font-src` and `style-src` in both `productionCsp` and `developmentCsp`.
6. Drop the `<link rel="preconnect">` lines.

**Acceptance**: Lighthouse Performance ≥ 95 on `/`. CSP gets stricter
(`font-src 'self'`, `style-src 'self'`).

---

## Phase 4 — Lint guards

To stop regressions of the contrast-audit fixes, add stylelint rules:

```jsonc
// opposite-osiris/.stylelintrc.json (create or extend)
{
  "rules": {
    "declaration-property-value-disallowed-list": {
      // --system-divider is decoration only. Never as text or border color.
      "color": ["/var\\(--system-divider\\)/"],
      "border-color": ["/var\\(--system-divider\\)/"],
      "outline-color": ["/var\\(--system-divider\\)/"],
      "/^.*-color$/": ["/var\\(--system-divider\\)/"]
    },
    "declaration-property-value-allowed-list": {
      // Inputs must use the form-specific border token, never --system-divider.
      "border-color": ["/var\\(--system-input-border/", "/var\\(--system-border/", "currentColor", "transparent", "/^#/", "/^rgb/"]
    }
  }
}
```

Add to CI:

```bash
npm run lint:styles      # new script: stylelint "src/**/*.scss"
```

Plus a one-off codemod check (CI grep) that fails the build if any new file
under `src/styles/components/` references `--brand-*` (components must stay in
the system layer):

```bash
! grep -RInE 'var\(--brand-' opposite-osiris/src/styles/components || \
  { echo 'components/ must use --system-* tokens only'; exit 1; }
```

---

## Phase 5 — Component sweep

In priority order, migrate each component file from legacy aliases to direct
`--system-*` references and verify against the audit:

| Order | Component                                  | Audit rows it touches    |
| ----- | ------------------------------------------ | ------------------------ |
| 1     | `_buttons.scss`                            | F2, F3, F5               |
| 2     | `_forms.scss`, `_field.scss`               | F1, F4, F5               |
| 3     | `_accessibility.scss` (focus ring)         | F5                       |
| 4     | `_notifications.scss`                      | F2 (status text)         |
| 5     | `_consent-banner.scss`                     | F1, F4                   |
| 6     | `_legal.scss`, `_auth.scss` pages          | F1, F2                   |
| 7     | `_tables.scss`                             | F1, F4                   |

Each migration PR:

- Removes any local hex / rgba in favor of a `--system-*` token.
- Adds `:focus-visible { outline: 3px solid var(--system-focus-ring); offset 2px }`
  if missing (SC 2.4.7, 2.4.11, 2.4.13).
- Verifies target size ≥ 44 × 44 (SC 2.5.8).
- Confirms with axe + Lighthouse a11y = 100.

---

## Phase 6 — Marketing polish (brand layer only)

After the system layer is solid, revisit the brand layer for delight:

- Mascot eye tracking — restore parallax, tighten easing.
- Hero mascot animations: rebuild on `--brand-ease-out-sketch` /
  `--brand-ease-bounce`.
- Worksheet sections: keep the irregular border-radius
  (`16px 13px 15px 12px`) and the `_paper-textures.scss` overlay.
- All gated by `prefers-reduced-motion: reduce` (SC 2.3.3 Animation from
  Interactions).

---

## Quality gate (every PR)

```bash
docker compose run --rm opposite-osiris node scripts/container-only.mjs astro check
docker compose run --rm opposite-osiris node scripts/container-only.mjs astro build
docker compose run --rm opposite-osiris node scripts/container-only.mjs node scripts/verify-sdk-boundaries.mjs
docker compose run --rm opposite-osiris node scripts/container-only.mjs node scripts/security/run-all.mjs
```

Manual:

- All three themes (light / dark / night) checked at `/`,
  `/auth/reset-password`, `/legal/privacy-policy/`.
- Lighthouse on `/` and `/auth/reset-password`:
  - Performance ≥ 95
  - Accessibility = 100
  - Best Practices ≥ 95
  - SEO = 100
- axe-core: 0 serious, 0 critical.

---

## Out of scope (tracked, not in this plan)

- Server-side CSP header at Kong (operational; tracked in
  `apps/baas/mini-baas-infra/`).
- Email template redesign (separate audit per
  `src/email-templates/`).
- Dashboard visual rebuild — depends on Phase 5 finishing first.

---

## ADR addendum — landing-page rebuild (this iteration)

### Decision A — Two-layer tokens are now load-bearing
Brand tokens (`--brand-*`) are personality-only (paper, ink, highlighters,
mascot palette). System tokens (`--system-*`) drive every functional surface
(text, borders, focus, action, dialog, input, card, chip, status). Legacy
aliases in `_tokens.scss` keep older components compiling while we sweep them.

### Decision B — Native `<dialog>` everywhere
`Dialog.astro` (system primitive) and `Portal.astro` (auth) both use
`HTMLDialogElement.showModal()`. The platform handles ESC, focus trap,
inert background, and top-layer rendering. Custom focus-trap code was deleted.

### Decision C — Self-hosted fonts
Google Fonts is being removed. `_typography.scss` declares every face with
`font-display: swap` and `local()` first, `url('/fonts/*.woff2')` second.
`public/fonts/README.md` lists the binaries to drop in. Until then the
`local()` probe + system fallback keep the site readable. Once shipped we
remove the `<link>` tags and the `fonts.googleapis.com` / `fonts.gstatic.com`
entries from CSP in `Layout.astro`.

### Decision D — Scroll-driven motion with safe fallback
`utilities/_scroll-effects.scss` provides `[data-scroll-grow]` and
`[data-scroll-rise]`. They use `animation-timeline: view()` inside
`@supports`, so unsupported browsers see a static layout (no JS jank). All
animations are killed under `prefers-reduced-motion: reduce`. Applied to
hero art, feature cards, product showcase, pricing cards, FAQ items, and
the final CTA panel.

### Decision E — Landing-page IA replaced
`src/pages/index.astro` now composes:
`HeaderNew → HeroNew → LogoStrip → FeatureTrio → ProductShowcase →
SocialProof → Pricing → DocsTeaser → FaqSection → FinalCta → FooterNew`.
Old marketing sections (`HeroSection`, `PowersSection`,
`MediaAssetsSection`, `WorkspaceGridSection`, `BaasStatusSection`,
`IntelligenceSection`, `CharactersSection`) are kept on disk for reuse on
sub-pages but no longer reachable from `/`. They will be removed in a
follow-up cleanup once links/redirects are confirmed.

### Decision F — Feature module skeleton
`src/features/{mascot,portal,consent,theme,baas-status}/index.ts` exist as
stubs (theme + portal are functional today). The 2200-line `main.ts` keeps
running until each subsystem is moved behind its `init*()` export. The
portal module already lazily injects Turnstile on first
`[data-action="open-portal-*"]` click — eager `<script>` injection in
`Layout.astro` can be removed when the rest of main.ts moves.

### Decision G — Stylelint guard for `--system-divider`
Pending: add a stylelint rule
`declaration-property-value-disallowed-list: { "/^(color|border-color|outline-color|.*-color)$/": ["/var\\(--system-divider\\)/"] }`
so the decoration-only divider token can never become text/border color.

### What shipped in this commit
- `src/styles/base/_typography.scss` (NEW) — self-hosted @font-face stack.
- `src/styles/utilities/_scroll-effects.scss` (NEW) — `[data-scroll-grow]`
  + `[data-scroll-rise]` with `animation-timeline: view()`.
- `src/styles/sections/_section-base.scss` (NEW) — section container,
  eyebrow, title, lede, accent helpers.
- `src/styles/main.scss` — imports the three new SCSS modules above.
- `src/components/ui/{Button,Field,Dialog,Card,Badge}.astro` (NEW) —
  system primitives.
- `src/components/brand/{SketchUnderline,PaperBackdrop,Eyebrow}.astro`
  (NEW) — brand primitives.
- `src/components/sections/{HeaderNew,HeroNew,LogoStrip,FeatureTrio,
  ProductShowcase,SocialProof,Pricing,DocsTeaser,FaqSection,FinalCta,
  FooterNew}.astro` (NEW) — 11 marketing sections.
- `src/pages/index.astro` — rewritten to compose the new sections.
- `src/features/{mascot,portal,consent,theme,baas-status}/index.ts` (NEW)
  — module skeleton, theme + portal functional.
- `public/fonts/README.md` (NEW) — binary checklist.

### Quality gate (this commit)
- `npx astro check` → 0 errors / 0 warnings / 0 hints.
- `npx astro build` → 9 pages built, ~900 ms. Vite warns about missing
  `/fonts/*.woff2` (expected: binaries ship in a follow-up; CSS falls back
  via `local()` + system stack).
