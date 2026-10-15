# Redesign decisions log

Each entry records an assumption or choice, the option taken, and why. "User" means the person
who owns this brief. Dates are absolute.

| ID | Date | Decision | Why / evidence |
|---|---|---|---|
| D-001 | 2026-10-15 | The product name is **Prismatica**. Visuals are free; there are no brand constraints. | User answer. `og:site_name` is already `Prismatica` in `apps/opposite-osiris`. |
| D-002 | 2026-10-15 | Audience: B2B on grobase (one interface across departments), plus individuals running it locally the way people use Obsidian, on a simple MongoDB engine. | User answer, recorded in BRIEF.md. |
| D-003 | 2026-10-15 | The site is measured at `https://localhost:4322`, with the frontends linked in `direct` mode to baas at `https://baas.tail10f2ea.ts.net`. | The Funnel URL the user pointed to is grobase's API behind the WAF (`.env.grobase-link`, `GROBASE_TARGET`), not the website. No tailnet URL serves the site. |
| D-004 | 2026-10-15 | Nothing is installed on the host. Every tool runs from a repo-owned Docker image, through `scripts/tools.sh`. | User rule. The host lacks ffmpeg, svgo, lhci and ImageMagick (checked with `command -v`). |
| D-005 | 2026-10-15 | grobase-cli is **packaged** as a binary in the tools image, built from a pinned commit. Its code is not changed. | User answer. Its source lives in another repo (Univers42/grobase-cli). |
| D-006 | 2026-10-15 | The Playwright and Chrome DevTools MCP servers run in Docker, declared in the project `.mcp.json`. | User answer. `npx` would put Chromium into a 4.7 GB-quota `$HOME`. |
| D-007 | 2026-10-15 | There is no `frontend-design` skill. Use `frontend` plus `design-review`, which together give the brief's plan → review → build → critique passes. | The installed skills were listed; none is named `frontend-design`. |
| D-008 | 2026-10-15 | All work happens in the worktree `/goinfre/dlesieur/groot-redesign` on branch `redesign/brief`, based on `origin/develop` (5188e8e9). | Other sessions share the main checkout. The branch model is feature → develop → main (README, Project Management). |
| D-009 | 2026-10-15 | Broken things get a reproducible, permanent fix with a test, as their own commit. Fixes inside another session's in-flight work or another repo are logged and handed over instead. | User rule, added to BRIEF ground rules. |
| D-010 | 2026-10-15 | `TEST_INBOX` is still open. It is not needed until Phase 7. | The user has not given it yet. |
