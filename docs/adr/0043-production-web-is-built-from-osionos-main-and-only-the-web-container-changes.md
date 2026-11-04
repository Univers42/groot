# 0043. Production web is built from osionos main, and only the web container changes

- Status: accepted with conditions (devil: PROCEED-WITH-CONDITIONS, 2026-11-01). D1–D12 are open; D1 fails as of 21:40
- Date: 2026-11-01
- Deciders: owner (production is `main`; the in-place terminal live tonight), devil (ruling)

## Context

- Production's web `machine-adc07efc` comes from `release/machine-hotfix-2`, which is in neither
  `main` nor develop. Its 4 patch-unique commits exist in develop in later forms (`git cherry`).
- The running app container was created with `DC_EXTRA=machine-web.yml`. Its config hash
  `59cfc758…` still renders today, so nothing has drifted.
- Production's bridge `machine-904b9a0e` is an ancestor of `main`. The machine, sudo and guard
  modules the terminal uses are identical to develop's (`bridge-machines.mjs:37,200-209`).
- The beta (ADR 0040) ran develop's web on this bridge and AI service, in portal sign-in mode.
  Production uses the Prismatica handoff.
- Production's index says `osionos-build` = `image`: it is built without `VITE_APP_VERSION`.
- ADR 0041 gates `main` on Firefox, Safari, U6 and W7. None is recorded as measured.

## Decision

Build `track-binocle/osionos-web:main-<S8>` from a clean detached worktree at the green `main`
sha S, with `VITE_APP_VERSION=main-<S8>`. `web-main.yml` replaces `machine-web.yml` in DC_EXTRA
and differs from it in three lines. Recreate only `osionos-app`. The bridge, the AI service, the
proxy and the data stay as they are.

## Alternatives considered

- **Keep shipping hotfix branches:** production stays off `main`. Each release needs a new
  hand-kept overlay and a branch nobody reviews.
- **Rebuild web, bridge and AI from main together:** three containers change in one step, and a
  failure has three suspects. The bridge's new content validation would come along without being
  ruled on.
- **Wait for Firefox, Safari and U6:** no terminal tonight. Each fails closed into W14's panel, so
  waiting buys UX, not safety.

## Consequences

- Conditions D1–D12, the verify list V1–V9 and the rollback triggers R1–R6 are in
  `docs/ops/production-web-from-main-verdict-2026-11-01.md`. The most important are D1 (CI run on S
  green with browser tests run), D2 (a shell opened on the beta at S), D6 (the rollback rehearsed
  by hash and dry-run) and V2 (production's handoff sign-in, which the beta never exercised).
- Rollback: `DC_EXTRA=…/machine-web.yml dc.sh up -d --no-deps --no-build osionos-app`, under a
  minute. It does not undo rows the new web wrote.
- A terminal failure alone does not trigger a rollback; it is fixed forward through the beta.
- Revisit this decision when the bridge or AI service is rebuilt from main, or if develop starts
  a schema or storage-format migration.
