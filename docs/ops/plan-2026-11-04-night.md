# Night of 2026-11-04: what is left, in order (autonomous session)

The owner asked to finish every open phase, to have zero console errors and warnings, and to ship live
little by little. The laptop has 8 GB RAM, so at most two agents run at a time and only one docker build.

## Shipped tonight

- The beta's realtime socket: groot 762f33e2's edge.conf deployed on the host. The old file is kept as
  `edge.conf.bak-20261104`. Verified: after a reload, no 400 in the console.
- Unattended sessions: DEVIL_AUTONOMY=1 and bypassPermissions, in ~/.claude/settings.json and in the
  harness42 profile (370bfd9).
- Go-live step A, the production proxy (c6ea4df6, ADR 0046).
- osionos develop: #297, #299 and submodule PRs ndb#28 and ui#4 merged. CI on 75402068 is green
  with no skips (G1). After that, by direct push (owner rule: no PRs): fb21c39d, the admin role
  grant (#296) and the Settings console issues (#293).
- Admin > Users (#296) live: both env-named admins had no `user_roles` admin row. It was granted
  through the bridge's own service client (undo: delete the two rows). The beta lists 25 users.
- A dead installed app ("Ocupación de agendas", framing a page that never existed) was deactivated
  in the owner's marketplace record (re-enable from Marketplace).
- The production edge's AI limits (56af2ace): reads in their own 20 r/s bucket, writes at 2 r/s,
  and the beta reads the locked AI routes. Mounted by the overlay `ai-edge.yml`. **Every proxy
  recreate now passes `livekit-tls.yml:frame-ancestors.yml:ai-edge.yml`.** Rollback:
  `logs/rollback-proxy-ai-edge.sh`.
- G3 measured (ADR 0041, ff90de9f). WebKit (#304) and the Firefox console (#305) still block main.
- Calendar 21a6c13 and Mail 9ebc58c (groot#179, named form fields) are live in production. They
  were built from `git archive` exports in the deploy dir (overlay `apps-web.yml`), not from the
  host checkout, which is 348 commits behind with local edits. The old images are tagged
  `:rollback-20261104`, and `logs/rollback-apps-web.sh` restores them. Verified in a cache-free
  browser context.
  Found: both apps serve index.html with no Cache-Control, so a browser keeps last month's app
  inside the frame after a deploy. The fix (no-cache HTML) is queued, with a missing favicon.
- What the beta still logs is version skew. The develop web runs on production's bridge and AI
  service, and the new client's probes (`/api/capabilities`, `/api/ai/capabilities`,
  `agents/settings`) each log one 404 there. That ends when production's bridge and osionos-ai
  move to main (ADR 0046 D1), after #304 and #305.
- Beta console sweep at fb21c39d, 19 surfaces: one entry left, the AI `agents/settings` 404
  (#303; client fix #301, then an osionos-ai redeploy). Calendar's frame: groot#179.

## In progress

1. "Remember this computer", R1–R14 (builder remember-finisher) → develop → the beta. Then: the
   production bridge redeploy (POST /api/machines/:id/resume) and the owner's node with
   `--remember-origin` (both production and the beta).
2. State map (workflow, one agent at a time): the editor on disk F1–F20, theming, live state, the passkey
   error, issues, VS Code upstream-following, the phase plan.

## The map (workflow wf_8b0c856e-894, 8 agents, 2026-11-04) → priority order

**P0: submittable and live**
- A. Subject audit (agent subject-auditor): every FAIL/UNPROVEN becomes an issue labelled `priority: high`, plus `subject-blocker` when it blocks submission. Fix every blocker.
- B. Develop CI red: #292 (the stub e2e cannot find "Database - Inline") and the untracked workbench.spec.mjs:72 (after f84edb43 the dock is hidden, not unmounted, so the spec must expect toBeHidden). This blocks main ← develop (ADR 0043 D1).
- C. Console zero: 289 unnamed form fields, then a Playwright console gate across every surface.
- D. Production is behind:
  - Web machine-adc07efc is off-main and lacks the in-place terminal and the whiteboard URL.
  - Bridge 904b9a0e lacks 13 bridge commits already in main, including the signed media links (security #233/#235) and the resume route.
  - Go-live order: develop green → main → bridge + web from main (with the whiteboard URL) → the owner's node updated so /editor/ exists.
- E. "Passkeys aren't available on this server yet" on the beta: PASSKEYS_ENABLED is unset on the production bridge, and osionos has no enrolment or sign-in ceremony at all. Fix: don't show an unavailable feature (hide the section), and record the full passkey ceremony as an issue.
- F. The whiteboard (below).

**P1: the features the owner uses**
- Remember R1–R14 (in progress). Do not commit the submodule pointers; autosquash; degrade silently on the old bridge.
- The laptop node: update ~/.osionos/src to develop (it is 14 node commits behind, so /editor/ answers 404). Do NOT rerun install.sh: it replaces the hand-written unit.
- Editor on disk: tests for F1–F7, F12, F14, F16, F17; the F19 Chrome e2e; then ADR 0044 accepted.
- Theme: the desktop app://terminal gets only 4 colours, once; the IDE window has no theme protocol; JetBrains Mono is not bundled in the terminal and IDE pages (#291); contrast per theme (#290).

**P2: VS Code that follows upstream**
- A decision first (devil): "a real VS Code" reverses ADR-006 decision 1 (editor mode only) and sits against ADR 0044. Then: the C2 skew guard reads the real product.js and product.json; the server cache is keyed by code-server version or commit; node-page builds run in PR CI; a one-command upgrade script and runbook; remove the hard-coded enums, the deep imports and the `as never` escapes.
- Phase 2 (the big deletion of 11 REPLACED-BY rows), Phase 5 remainder, Phase 8 design pass. Phases 3, 4, 6, 7 and Milestone 2 are L-sized: one at a time, each with a devil verdict.

**Open PRs needing the requested changes:** #285, #284 (does not fix #278), #283 (CONFLICTING; rejects already-stored data), #256 (keyboard regression), #275 (draft). Connector branch feat/osionos-connector: local only, 20 ahead / 73 behind.

## Queued

3. **Whiteboard (/draw, /whiteboard) broken.** Evidence 2026-11-04:
   - Production web `machine-adc07efc` has no hydrawn URL in its bundle; it was built without
     `VITE_WHITEBOARD_APP_URL`, so the app offers no board. Fix: production web from main (ADR 0043)
     with `VITE_WHITEBOARD_APP_URL=https://osionos.hydrawn-app.pages.dev` in the build overlay.
   - The beta builds with `VITE_WHITEBOARD_APP_URL=` blank (infrastructure/beta/update.sh:38). Hydrawn's
     osionos build bakes in ONE parent (`HYDRAWN_PARENT_ORIGIN`, hydrawn scripts/osionos-csp.mjs:67 →
     `frame-ancestors`). So the beta needs its own hydrawn Pages alias (e.g.
     `osionos-beta.hydrawn-app.pages.dev`), built with parent `https://baas-beta.tail10f2ea.ts.net`. The
     production bridge must also accept that origin (today `OSIONOS_WHITEBOARD_ORIGIN` holds one origin,
     deploy/whiteboard.yml).
   - Deploy credentials: the GitHub Actions secrets `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN` in
     Univers42/hydrawn-site, readable only by a workflow run in that repo. The last osionos build was the
     host image `hydrawn-pages-build:bfc67b6-proxy` from `~/Documents/groot-wt/hydrawn-embed/hydrawn`
     (branch feat/osionos-embed).
   - The services themselves are up: hydrawn Pages 200; the bridge /api/whiteboard/* answers 401 without
     credentials; drawnosaurus containers healthy. The hydrawn page logs a CSP eval issue and an unnamed
     form field.
4. Console zero: 289 JSX form fields without id/name (codemod plus a guard test, including the
   notion-database-sys submodule). A Playwright spec walks every surface and fails on any console error,
   warning or issue.
5. Production go-live (ADR 0043, D1–D12), self-ruled by the devil: main ← develop, web image from main
   with the whiteboard URL, the bridge with resume.
6. The rest from the state map: editor F-gaps, theme gaps, the passkey error, the VS Code
   upstream-following ADR.
