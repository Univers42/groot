# 3. Responsive — phone → laptop → desktop — demonstrate

**Answer.** Every surface ships a `<meta name="viewport">` and adapts via
breakpoints. osionos uses **Tailwind utility breakpoints**; opposite-osiris, mail,
calendar and the grobase site use **hand-written CSS/SCSS media + container queries**.

## Proof
- **Viewport** (all apps): `apps/osionos/app/index.html:5`,
  `apps/opposite-osiris/src/layouts/Layout.astro:63`, `apps/mail/index.html:5`,
  `apps/calendar/index.html:5` → `width=device-width, initial-scale=1`.
- **osionos — Tailwind breakpoints** (defaults sm640/md768/lg1024/xl1280): usage
  counts sm 23 · md 9 · lg 17 · xl 1. e.g.
  `…/WorkspaceThemePanel.tsx:122` `grid sm:grid-cols-2`; `…/App.tsx:32` `flex-col lg:flex-row`.
- **opposite-osiris — 36 `@media`**: 480/520/560/640/720/768/800/900/1080px +
  ultrawide `min-width:1400` (`src/styles/utilities/_responsive.scss:125`); nav
  collapses at 900px (`:31`).
- **mail — 2 `@media`** 980/640px (`apps/mail/src/styles.css:974`): sidebar →
  column, sender hidden on phone (`:989`). **calendar — 3** 1100/860/620px
  (`apps/calendar/src/styles.css:1242`).
- **grobase site — 74 `@media`, mobile-first** (`min-width` / `width >=`, rem units):
  768/1024/960px; hamburger drawer
  `apps/grobase/vendor/grobase-website/src/scripts/nav/megamenu.ts:33`.
- **Container queries** (a component adapts to its *pane*, not the screen):
  `apps/osionos/app/src/widgets/page-toc/PageOutlineRail.module.css:54`
  `@container (max-width:1100px)` hides the TOC rail; opposite hero `_responsive.scss:117`.

## Strategy note
osionos / opposite-osiris / mail / calendar are **desktop-first** (`max-width`
collapse-on-shrink); the grobase marketing site is **mobile-first**.
⚠️ No `srcset`/`<picture>` responsive *images* yet — adaptation is layout reflow
only; art-directed images are a known enhancement.
