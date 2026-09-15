# 1. Charte graphique (graphic chart) — prove it

**Answer.** The charte graphique is implemented as **design tokens** — colours,
typography, spacing, radius, theming — declared in code (CSS custom properties /
Tailwind `@theme` / SCSS maps), so the chart is *enforced by the build*, not a loose
PDF. Each surface ships its own token set; two brand languages dominate.

## osionos — "Warm Editorial"  ✅
`apps/osionos/app/src/app/styles/global.css` (Tailwind v4 `@theme`, `--osio-*` tokens)
- **Colours** (`:207` light): page `#FAF9F5`, surface `#FFFFFF`, ink `#1A1A18`,
  accent terracotta `#CC785C`; dark (`:299`) page `#1B1A17`, ink `#EDEAE3`.
- **Type** (`:146`): Inter Variable (sans) · Newsreader (serif) · JetBrains Mono;
  scale 12→30px (`:149`). **Spacing** 4px step (`:129`); radius/shadow/z scales (`:96`).
- **Theming** = 2 axes (`data-theme` light/dark/system × `data-palette`) in
  `apps/osionos/app/src/shared/config/theme.ts`, persisted to `localStorage`.

## opposite-osiris — "Prismatica / Binocle"  ✅
`apps/opposite-osiris/src/styles/abstracts/_brand-tokens.scss` (+ `themes/_color-modes.scss`)
- **4 themes** via `:root[data-theme]`: aurora (dark, default), solar (light),
  ember, forest. aurora (`:23`) canvas `#0a0a12`, accents violet `#a78bfa`,
  cyan `#22d3ee`, amber `#fbbf24`; solar (`:18`) bg `#fdfaf2`, primary `#6b46c1`.
- **Type** (`:90`): Space Grotesk · Instrument Serif · JetBrains Mono (+ handwriting).
- Signature **hand-drawn irregular radii** (`:77`); logo
  `apps/opposite-osiris/src/components/brand/PrismaticaLogo.astro`.

## mail + calendar — dark companion pair  ✅
`apps/mail/src/styles.css:24` & `apps/calendar/src/styles.css:15`: dark UI, shared
red accent `#de5550`; calendar event palette green/blue/yellow/purple (`:24`).

⚠️ **Known gap:** there is **no shared cross-app token package** — `--osio-*` naming
is reused (with different values) in mail, but each app owns its palette.
Consolidation into one design-system package is a documented follow-up.
