# Project FAQ — defense answers (evidence-backed)

Short, **provable** answers to the recurring review questions. Every claim points
at a real file or command in this repo so a reviewer can open it and verify on the
spot — nothing is asserted without a citation.

| # | Question (FR / EN) | Answer |
|---|---|---|
| 1 | Charte graphique — what is the project's graphic chart? | [01-charte-graphique.md](01-charte-graphique.md) |
| 2 | Accessibilité (handicap / WCAG) — what did we put in place? | [02-accessibilite-wcag.md](02-accessibilite-wcag.md) |
| 3 | Responsive — phone → laptop → desktop adaptation | [03-responsive.md](03-responsive.md) |
| 4 | Tests — jeu d'essai fonctionnel, unitaires, sécurité | [04-tests.md](04-tests.md) |
| 5 | RGPD + ANSSI + scores WCAG 2.1 | [05-securite-rgpd-anssi.md](05-securite-rgpd-anssi.md) |
| 6 | Veille technologique — env install/config + security | [06-veille-technologique.md](06-veille-technologique.md) |

**Honesty legend** (used throughout):
✅ implemented & citable · ⚠️ partial / known gap · 📊 audit harness exists, the
score must be *generated* (no number is invented in these docs).

**Frontends referenced:** `apps/osionos/app` (React/Vite block editor),
`apps/opposite-osiris` (Astro marketing+auth), `apps/mail`, `apps/calendar` (React),
`apps/grobase` (the BaaS backend + its marketing site). Backend planes: TypeScript
(app), Go (control), Rust (data) — see `apps/grobase/CLAUDE.md`.
