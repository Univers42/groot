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
| D-011 | 2026-10-15 | The Playwright MCP runs from `groot-tools` (`@playwright/mcp@0.0.83` driving the image's Chromium), not from `mcr.microsoft.com/playwright/mcp`. This changes the approved plan. | One image keeps one CA-trust path (the shared entrypoint imports the local CA into NSS). The `mcr` image has no `certutil`, so it would have needed `--ignore-https-errors`. It also follows the user's "centralise in our own image" rule. |
| D-013 | 2026-10-15 | The osionos MCP server runs from `groot-tools`, with its two imports (`@modelcontextprotocol/sdk` 1.29.0, `zod` 4.4.3) installed at `/node_modules`. It does not use osionos's own `docker-run.sh mcp-claude`. | That path needs osionos's `playground` image (a full pnpm install, absent here), and it defaults to `http://host.docker.internal:4000`, but the bridge serves https on :4000 (http gets a 308; measured with curl). The versions follow osionos's `pnpm-lock.yaml`, and the smoke test fails on drift. The http default is osionos's own code, so it is reported to that repo, not changed here. |
| D-014 | 2026-10-15 | `local_ca_file` falls back to the main checkout's CA when called from a linked worktree, found through `git rev-parse --git-common-dir`. | The CA is generated and git-ignored, so no worktree ever has one, and naming the path in config would tie it to one seat. |
| D-012 | 2026-10-15 | `scripts/tools.sh` mounts only the repo, at its host path. Inputs and outputs of a tool live under the repo. | It keeps file arguments identical inside and outside the container. `tests/tools-image/smoke.bats` failed 4/9 while it wrote to `/tmp`, and passes 9/9 since. |
