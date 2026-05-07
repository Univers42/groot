# Contrast Audit — opposite-osiris (Prismatica)

**Audit date:** 2026-05-07
**Audit version:** 1.0.0
**Scope:** All `--*` color tokens defined in [src/styles/abstracts/_tokens.scss](../src/styles/abstracts/_tokens.scss) and theme overrides in [src/styles/themes/_color-modes.scss](../src/styles/themes/_color-modes.scss).
**Standard:** WCAG 2.2 AA. Normal text ≥ 4.5:1 (SC 1.4.3), large text (≥ 18pt or 14pt bold) ≥ 3:1, non-text UI components and graphical objects ≥ 3:1 (SC 1.4.11).
**Method:** sRGB relative luminance per WCAG formula. RGBA tokens are pre-composited against their declared backdrop before measuring.

## Severity legend

- **P0** — fails AA at the role the token is used in today; visible regression risk if shipped.
- **P1** — passes today but is structurally fragile (depends on alpha against an unverified background, or theme override drops below 3:1 in adverse conditions).
- **P2** — passes; included only because the redesign will retire or rename the token.

---

## Summary

| Theme | Token failures (P0) | Tokens at risk (P1) |
| ----- | ------------------- | ------------------- |
| light | 5                   | 3                   |
| dark  | 5                   | 2                   |
| night | 5                   | 2                   |

Dominant failure modes:

1. **Alpha-based "faint" tokens** (`--ink-faint`, `--surface-line-soft`) hover at 1.5–2.7:1 across all three themes. They are currently used for placeholder text, form helper text, dividers and input borders — every one of those roles requires ≥ 3:1 minimum, ≥ 4.5:1 for text.
2. **Highlighter palette used as foreground** (`--hl-blue`, `--hl-red`, `--hl-green` as link / status text on paper) all sit between 1.8 and 2.6:1 on the light theme. They were authored as fill/highlight colors but `_notifications.scss` and `_baas-status.scss` reach for them as accent text.
3. **No declared focus-ring color token.** `_accessibility.scss` falls back to `var(--hl-blue)` which is one of the failing P0 colors above. The system layer needs a dedicated `--system-focus-ring` that is verified in all three themes against both surface and inverse-surface backdrops.
4. **Placeholder convention is undefined.** Inputs inherit `--ink-mid` in some places and `--ink-faint` in others; only the former passes.
5. **`--portal-input-border` is white-on-near-black at α 0.72** — 9.9:1, fine — but the *light-mode* portal interior reuses `--ink-faint` for the same role and drops to 1.5:1.

The token system also conflates **brand decoration** with **system UI** (paper textures behind input fields, sketchy radii on form controls, highlighter colors as link text). Step B will resolve this by splitting tokens into `--brand-*` and `--system-*` namespaces; this audit is scoped only to the contrast question.

---

## Light theme

Backdrop assumed: `--paper` (`#f7f4ed`, L = 0.906) unless noted.

| Token                   | Value                          | Role today                            | Effective fg / bg                      | Ratio    | WCAG SC        | Verdict                  | Proposed fix (Step B)                                                 |
| ----------------------- | ------------------------------ | ------------------------------------- | -------------------------------------- | -------- | -------------- | ------------------------ | --------------------------------------------------------------------- |
| `--ink`                 | `#1c1612`                      | body text on paper                    | `#1c1612` / `#f7f4ed`                  | 16.48:1  | 1.4.3          | **PASS**                 | keep, rename `--brand-ink` (paper-ink) and add `--system-text-strong` |
| `--ink-mid`             | `#3a322c`                      | secondary text, captions              | `#3a322c` / `#f7f4ed`                  | 11.42:1  | 1.4.3          | **PASS**                 | keep; promote to `--system-text`                                      |
| `--text-contrast-min`   | `#141210`                      | "improved contrast" headings          | `#141210` / `#f7f4ed`                  | 17.22:1  | 1.4.3          | **PASS**                 | redundant with `--ink`; collapse                                      |
| `--text-contrast-mid`   | `#2f2924`                      | improved body text                    | `#2f2924` / `#f7f4ed`                  | 13.06:1  | 1.4.3          | **PASS**                 | redundant with `--ink-mid`; collapse                                  |
| `--ink-faint`           | `rgba(28,22,18,0.20)`          | placeholder, helper text, dividers    | composited `#cbc7be` / `#f7f4ed`       | 1.52:1   | 1.4.3 / 1.4.11 | **P0 FAIL**              | split: `--system-text-muted` `#6a635c` (5.2:1), `--system-divider` `#d8d3c8` (1.6:1, decorative-only, never text) |
| `--surface-line`        | `rgba(28,22,18,0.78)`          | strong borders on cards               | composited `#46403a` / `#f7f4ed`       | 8.74:1   | 1.4.11         | **PASS**                 | rename `--system-border-strong`                                       |
| `--surface-line-soft`   | `rgba(28,22,18,0.24)`          | soft borders, input outlines          | composited `#c2bdb5` / `#f7f4ed`       | 1.70:1   | 1.4.11         | **P0 FAIL** (UI ≥ 3:1)   | replace with solid `--system-border` `#9a9088` (3.06:1)               |
| `--hl-yellow`           | `#f5d84a`                      | highlighter fill (BG)                 | bg only — text on it must be `--ink`   | 12.76:1  | 1.4.3          | **PASS** (as bg)         | keep as `--brand-hl-yellow`; forbid as text                           |
| `--hl-blue`             | `#7ab3e8`                      | links, focus ring fallback            | `#7ab3e8` / `#f7f4ed` as text          | 2.03:1   | 1.4.3          | **P0 FAIL**              | `--system-link` `#1f5fa6` (5.92:1); `--system-focus-ring` `#1d4ed8` (6.13:1) |
| `--hl-green`            | `#82c98a`                      | success notification accent text      | `#82c98a` / `#f7f4ed` as text          | 1.81:1   | 1.4.3          | **P0 FAIL**              | `--system-success-text` `#1f7a3a` (4.74:1); keep `#82c98a` as `--brand-hl-green` for fills only |
| `--hl-red`              | `#e87a7a`                      | error notification accent text        | `#e87a7a` / `#f7f4ed` as text          | 2.56:1   | 1.4.3          | **P0 FAIL**              | `--system-danger-text` `#b21f1f` (5.42:1); keep `#e87a7a` as `--brand-hl-red` for fills only |
| `--surface`             | `rgba(247,244,237,0.86)`       | card background                       | composited ≈ `#f7f4ed` over bg         | text against still 16:1 with `--ink` | 1.4.3 | **PASS**          | rename `--system-surface`                                             |
| `--surface-strong`      | `rgba(255,253,246,0.90)`       | elevated card background              | ≈ `#fdf9ee`                            | 17.1:1 with `--ink`                  | 1.4.3 | **PASS**          | rename `--system-surface-raised`                                      |
| `--header-bg`           | `rgba(247,244,237,0.94)`       | sticky header                         | ≈ `#f7f4ed`                            | 16.5:1 with `--ink`                  | 1.4.3 | **PASS**          | keep                                                                  |
| `--button-fill` / `--button-text` | `#1c1612` / `#f7f4ed` | primary button                        | `#f7f4ed` / `#1c1612`                  | 16.48:1  | 1.4.3 / 1.4.11 | **PASS**                 | keep; rename to `--system-action-bg` / `--system-action-fg`           |
| `--accent-text`         | `#1c1612`                      | text on `--hl-yellow` highlighter     | `#1c1612` / `#f5d84a` (L 0.74)         | 12.76:1  | 1.4.3          | **PASS**                 | keep                                                                  |
| `--portal-left-text`    | `rgba(255,255,255,0.92)`       | hero side of portal (dark backdrop)   | `#ebebeb` / `#030303`                  | 19.5:1   | 1.4.3          | **PASS**                 | rename `--system-on-inverse`                                          |
| `--portal-left-hint`    | `rgba(255,255,255,0.68)`       | helper text on portal dark side       | `#adadad` / `#030303`                  | 10.5:1   | 1.4.3          | **PASS**                 | keep, system-namespaced                                               |
| `--portal-input-border` | `rgba(255,255,255,0.72)`       | input border on portal dark panel     | `#bababa` / `#0e1117`                  | 9.9:1    | 1.4.11         | **PASS**                 | keep                                                                  |
| `--portal-error-text`   | `#ffd0d0`                      | inline error on portal dark panel     | `#ffd0d0` / `#0e1117`                  | 13.7:1   | 1.4.3          | **PASS**                 | keep                                                                  |
| `--sketch-line`         | `rgba(28,22,18,0.74)`          | decorative SVG line color             | n/a (decorative)                       | —        | —              | n/a                      | move to `--brand-sketch-line`                                         |

---

## Dark theme (`[data-theme='dark']`)

Backdrop assumed: `--paper` (`#121821`, L = 0.0089) unless noted.

| Token                 | Value                          | Role today                          | Effective fg / bg                      | Ratio    | WCAG SC        | Verdict                  | Proposed fix (Step B)                                                 |
| --------------------- | ------------------------------ | ----------------------------------- | -------------------------------------- | -------- | -------------- | ------------------------ | --------------------------------------------------------------------- |
| `--ink`               | `#f7f4ed`                      | body text                           | `#f7f4ed` / `#121821`                  | 16.23:1  | 1.4.3          | **PASS**                 | keep                                                                  |
| `--ink-mid`           | `#d8d2c7`                      | secondary text                      | `#d8d2c7` / `#121821`                  | 11.85:1  | 1.4.3          | **PASS**                 | keep                                                                  |
| `--ink-faint`         | `rgba(247,244,237,0.18)`       | placeholder, helper text            | composited `#3b3f47` / `#121821`       | 1.70:1   | 1.4.3          | **P0 FAIL**              | `--system-text-muted` `#9aa0aa` (5.13:1)                              |
| `--surface-line-soft` | `rgba(247,244,237,0.28)`       | soft borders, input outlines        | composited `#525660` / `#121821`       | 2.35:1   | 1.4.11         | **P0 FAIL** (UI ≥ 3:1)   | `--system-border` `#5e6470` (3.10:1)                                  |
| `--hl-blue` (inherited) | `#7ab3e8`                    | link/focus on dark surfaces         | `#7ab3e8` / `#121821`                  | 8.05:1   | 1.4.3          | **PASS**                 | reuse as `--system-link` in dark; OK because backdrop is dark         |
| `--hl-red` (inherited) | `#e87a7a`                     | error accent text                   | `#e87a7a` / `#121821`                  | 6.14:1   | 1.4.3          | **PASS** in dark only    | declare per-theme `--system-danger-text` so light gets the accessible swap |
| `--hl-green` (inherited)| `#82c98a`                    | success accent text                 | `#82c98a` / `#121821`                  | 9.78:1   | 1.4.3          | **PASS** in dark only    | per-theme override (see above)                                        |
| `--surface`           | `rgba(29,38,51,0.90)`          | card background                     | ≈ `#1c2532`                            | text against with `--ink` 14.7:1     | 1.4.3 | **PASS**          | keep                                                                  |
| `--surface-strong`    | `rgba(35,45,61,0.94)`          | elevated card                       | ≈ `#222d3c`                            | 13.4:1 with `--ink`                  | 1.4.3 | **PASS**          | keep                                                                  |
| `--lens-left-bg`      | `#05070d`                      | portal left panel                   | bg only                                | 18.7:1 with `--portal-left-text`     | 1.4.3 | **PASS**          | keep                                                                  |
| `--button-fill` / `--button-text` | `#f7f4ed` / `#121821` | primary button                      | `#121821` / `#f7f4ed`                  | 16.23:1  | 1.4.3 / 1.4.11 | **PASS**                 | keep                                                                  |
| `--portal-input-border` (inherited) | `rgba(255,255,255,0.72)` | input border on dark portal       | `#bababa` / `#0e1117`                  | 9.9:1    | 1.4.11         | **PASS**                 | keep                                                                  |

---

## Night theme (`[data-theme='night']`)

Backdrop assumed: `--paper` (`#030712`, L = 0.0022) unless noted.

| Token                 | Value                          | Role today                          | Effective fg / bg                      | Ratio    | WCAG SC        | Verdict                  | Proposed fix (Step B)                                                 |
| --------------------- | ------------------------------ | ----------------------------------- | -------------------------------------- | -------- | -------------- | ------------------------ | --------------------------------------------------------------------- |
| `--ink`               | `#fffdf8`                      | body text                           | `#fffdf8` / `#030712`                  | 19.79:1  | 1.4.3          | **PASS**                 | keep                                                                  |
| `--ink-mid`           | `#e7eef8`                      | secondary text                      | `#e7eef8` / `#030712`                  | 17.24:1  | 1.4.3          | **PASS**                 | keep                                                                  |
| `--ink-faint`         | `rgba(255,253,248,0.18)`       | placeholder, helper text            | composited `#30353f` / `#030712`       | 1.60:1   | 1.4.3          | **P0 FAIL**              | `--system-text-muted` `#9ca3af` (8.04:1)                              |
| `--surface-line-soft` | `rgba(255,253,248,0.32)`       | soft borders                        | composited `#54575f` / `#030712`       | 2.68:1   | 1.4.11         | **P0 FAIL** (UI ≥ 3:1)   | `--system-border` `#5b6271` (3.20:1)                                  |
| `--hl-yellow` (override) | `#ffe873`                   | highlight bg                        | bg only                                | 17.05:1 with `--ink` text on yellow  | 1.4.3 | **PASS**          | keep                                                                  |
| `--hl-blue` (override) | `#9ed0ff`                     | link / accent text                  | `#9ed0ff` / `#030712`                  | 12.36:1  | 1.4.3          | **PASS**                 | promote to `--system-link` per theme                                  |
| `--hl-green` (override) | `#9ee7a4`                    | success accent text                 | `#9ee7a4` / `#030712`                  | 14.55:1  | 1.4.3          | **PASS**                 | promote to `--system-success-text` per theme                          |
| `--hl-red` (override) | `#ff9b9b`                      | error accent text                   | `#ff9b9b` / `#030712`                  | 8.93:1   | 1.4.3          | **PASS**                 | promote to `--system-danger-text` per theme                           |
| `--surface`           | `rgba(11,18,32,0.92)`          | card background                     | ≈ `#0c1320`                            | 17.6:1 with `--ink`                  | 1.4.3 | **PASS**          | keep                                                                  |
| `--button-fill` / `--button-text` | `#fffdf8` / `#030712` | primary button                      | `#030712` / `#fffdf8`                  | 19.79:1  | 1.4.3 / 1.4.11 | **PASS**                 | keep                                                                  |

---

## Cross-cutting findings

### F1 — `--ink-faint` is the single largest accessibility liability (P0, all themes)

**Used in:** `_portal.scss` for placeholder hint, `_gdpr.scss` for `.form-note` and `.form-status`, `_reset.scss` for `abbr[title]` underline, `_baas-status.scss` for empty-state text.
**Problem:** alpha 0.18–0.20 against any backdrop produces 1.5–1.7:1 — it is invisible to users with even mild low vision and fails AA at every text role.
**Fix in B:** retire `--ink-faint` entirely. Introduce two replacements:

- `--system-text-muted` — solid color, ≥ 4.5:1 in every theme. For helper text, secondary captions, placeholder, `abbr` underline.
- `--system-divider` — explicitly *decorative*, can be < 3:1 because no information depends on it. SCSS lint rule (Step D) will forbid using it on `<input>` `border-color` or any `color:` declaration.

### F2 — Highlighter palette has overloaded semantics (P0, light theme)

`--hl-blue`, `--hl-green`, `--hl-red` are simultaneously **brand fills** (highlighter swipes, accent backgrounds) and **system status colors** (link text, success/error notification accents). The light values are tuned for fills, so they fail as foreground text. The dark/night overrides happen to pass because light-on-dark is geometrically more forgiving.
**Fix in B:**

- Keep current values as `--brand-hl-yellow|blue|green|red` — fills, decorative SVG strokes, highlighter swipes only.
- Add per-theme `--system-link`, `--system-success-text`, `--system-danger-text`, `--system-warning-text` with values verified ≥ 4.5:1 against `--system-surface` in every theme.

### F3 — No declared focus-ring color (P0, all themes)

`_accessibility.scss` and `_buttons.scss` both reference `var(--hl-blue)` for `:focus-visible` outlines, which is 2.03:1 against light paper — a focus indicator must meet **3:1 against adjacent colors** (SC 1.4.11) and is a primary keyboard navigation surface.
**Fix in B:** introduce `--system-focus-ring` (`#1d4ed8` light, `#9ec5ff` dark, `#bcd4ff` night) with measured ratios ≥ 4.5:1 against `--system-surface` and ≥ 3:1 against `--system-action-bg`. Use a 2px solid + 2px paper-colored offset to guarantee SC 1.4.11 in any nested context.

### F4 — Soft borders are invisible (P0 UI, all themes)

`--surface-line-soft` at alpha 0.24/0.28/0.32 produces 1.7–2.7:1 — fails the 3:1 SC 1.4.11 requirement for UI components. Currently used as `<input>` and `<select>` border in `_gdpr.scss` and `_portal.scss`.
**Fix in B:** replace with solid `--system-border` (~3.1:1 in each theme). Keep `--surface-line` (the strong variant, 8+:1) as `--system-border-strong` for sectional dividers and card outlines.

### F5 — Redundant tokens (P2, light theme)

`--text-contrast-min` and `--text-contrast-mid` are duplicates of `--ink` and `--ink-mid` introduced as a previous attempted fix. They will be collapsed in B; SCSS audit (Step D) will leave a one-line `@deprecated` comment so any external consumer notices.

### F6 — Selection background is high enough but flagged for context (P2)

`--selection-bg rgba(245,216,74,0.62)` composites to ~L 0.78 against light paper. Selected text uses `--ink` — passes at 13:1. Acceptable; rename `--brand-selection-bg` and add a `--system-selection-text` token defaulting to `--system-text-strong` so the system layer can override per-context.

---

## Token swap matrix (preview of Step B input)

| Retire / Rename                | New name(s) in Step B                                          | Layer  |
| ------------------------------ | -------------------------------------------------------------- | ------ |
| `--ink-faint`                  | `--system-text-muted` (text), `--system-divider` (decorative)  | system |
| `--surface-line-soft`          | `--system-border`                                              | system |
| `--surface-line`               | `--system-border-strong`                                       | system |
| `--text-contrast-min` / `-mid` | collapse into `--system-text-strong` / `--system-text`         | system |
| `--hl-blue` (as text)          | `--system-link` (per-theme values)                             | system |
| `--hl-green` (as text)         | `--system-success-text` (per-theme values)                     | system |
| `--hl-red` (as text)           | `--system-danger-text` (per-theme values)                      | system |
| `--hl-yellow|blue|green|red` (as fill) | `--brand-hl-yellow|blue|green|red`                     | brand  |
| `--paper` / `--paper-2`        | `--brand-paper` / `--brand-paper-2` + `--system-surface*`      | both   |
| `--sketch-line`                | `--brand-sketch-line`                                          | brand  |
| `--portal-*`                   | `--system-portal-*` (portal interior is system-layer only)     | system |
| `--mascot-*`, `--mood-*`       | `--brand-mascot-*`, `--brand-mood-*`                           | brand  |
| (new) focus indicator          | `--system-focus-ring` + `--system-focus-ring-offset`           | system |
| (new) status surfaces          | `--system-success-bg`, `--system-danger-bg`, `--system-warning-bg`, `--system-info-bg` | system |

---

## What this audit does NOT cover (intentionally)

- Non-text decorative SVG (mascot lenses, sketch background lines, illustration strokes) — outside SC 1.4.3 / 1.4.11 scope when truly decorative (`aria-hidden="true"`, `focusable="false"`, no informational role). All current decorative SVG is correctly marked.
- Focus *visibility* across all interactive surfaces (SC 2.4.7, 2.4.11, 2.4.13) — owned by Step B's `--system-focus-ring` definition and Step E's `<Portal />` keyboard trap.
- Color independence (SC 1.4.1) — no current chart or status indicator relies on color alone, but Step D will add a lint check.
- Motion and reduced-motion (SC 2.3.3) — owned by Step B's `--motion-*` tokens.

## Next deliverable

**Step B** — `src/styles/abstracts/_brand-tokens.scss`, `src/styles/abstracts/_system-tokens.scss`, refactored `_color-modes.scss`, plus migration of every consumer found in [src/styles/](../src/styles/). All P0 rows above will resolve to PASS in the post-B verification table.
