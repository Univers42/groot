# 2. Accessibilité / handicap (WCAG 2.1) — prove it

**Answer.** Accessibility is built into the markup (ARIA, semantic landmarks,
keyboard/focus, reduced-motion, language) **and** verified by tooling (jsx-a11y
lint, pa11y `WCAG2AA`, axe-core, a Lighthouse a11y gate). Coverage is strongest on
opposite-osiris and the grobase site; thinner on mail/calendar.

## What is implemented  ✅
- **ARIA** (src-only match counts): `aria-label` 321 (osionos) / 82 (opposite) /
  284 (grobase); plus `role`, `aria-live`, `aria-expanded`, `aria-hidden`,
  `aria-current`. Live region:
  `apps/opposite-osiris/src/pages/index.astro:21` → `aria-live="polite" id="global-announcer"`.
- **Landmarks + skip link**: `<main>/<nav>/<header>/<footer>` across apps;
  `apps/opposite-osiris/src/layouts/Layout.astro:93` → `<a class="skip-link" href="#main-content">`.
- **Keyboard / focus**: focus-trapped modal at
  `apps/osionos/app/src/shared/ui/primitives/Modal.tsx:116` (`role="dialog" aria-modal="true"`),
  native `<dialog>`, `:focus-visible` rings (osionos 18 / opposite 44 / grobase 40).
- **Reduced motion**: `prefers-reduced-motion` queries (osionos 10 / opposite 13 /
  grobase 66) — e.g. `apps/osionos/app/src/pages/notion-page/ui/notionPage.css:1011`.
- **Language**: `<html lang="en">` in every entry doc (`apps/*/index.html`, Layout.astro).
- **Forms**: `<label>` + `aria-invalid`/`aria-live` error messaging (opposite-osiris `Field.astro`).

## How it is audited (the proof you can run)  📊
- `eslint-plugin-jsx-a11y` at **error** level — `apps/opposite-osiris/eslint.config.mjs:28`.
- **pa11y `WCAG2AA`** — opposite-osiris `npm run audit:a11y`; grobase site
  `…/scripts/audit/pa11y.config.json` (`"standard":"WCAG2AA"`).
- **axe-core**, 0 serious/critical — `apps/grobase/vendor/saas/web/test/a11y-axe.mjs`.
- **Lighthouse accessibility ≥ 90** gate — osionos `scripts/lighthouse-categories.mjs:25`;
  `make grobase-audit` (a11y ≥ 90 + pa11y + html-validate).

⚠️ **Gap:** `apps/mail` and `apps/calendar` have only basic `aria-label`/`<label>`/
`lang` — no skip link, no `:focus-visible`, no reduced-motion, no a11y audit target.
Qualitative checklist: `wiki/acccessibility/wcag.md`.
