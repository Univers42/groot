# Production web from osionos main (plan, 2026-11-01)

## Why

Production's web app (`track-binocle/osionos-web:machine-adc07efc`) is built from
`release/machine-hotfix-2`, a branch in neither osionos `main` nor `develop`, through hand-kept
overlays in `~/Documents/groot-wt/deploy/` on the host. The owner needs the in-place web terminal
(ADR 0041) live on production tonight, and wants production to be `main`.

## Preconditions

- osionos `develop` CI green; `main` fast-forwarded to it (no merge of its own). The pinned sha is
  `<MAIN_SHA>`, recorded before the build.
- ADR 0041 W1–W16 met (builder report, merge 72535a15). The owner's laptop node already runs
  the matching node code (`~/.osionos/src` at 1e6835e5, restart verified: `/terminal/` 200,
  foreign Host 403).

## Steps (host 100.94.109.44, all in `~/Documents/groot-wt/deploy`)

1. `git -C app-main` (a new detached worktree of the osionos clone used by `app/`) at `<MAIN_SHA>`,
   submodules recursive.
2. Overlay `web-main.yml`: `osionos-app.image: track-binocle/osionos-web:main-<sha8>`,
   `build.context: …/deploy/app-main`. It replaces `machine-web.yml` in DC_EXTRA; the other
   overlays and `account-release-build.yml` (VITE_AI_URL, groot `deploy/root` Dockerfile at
   488a2fc8) are unchanged, as are every other service and their images.
3. `DC_EXTRA=… dc.sh build osionos-app` (only the web image).
4. Candidate check before switching: run the new image with `--network none`; its index must name
   `main-<sha8>`.
5. `dc.sh up -d --no-deps --no-build osionos-app` (only the web container).
6. Verify: `:8443` serves the new bundle; login as the working account; workspaces, assistant
   (AI routes 200), and Terminal → New Terminal shows the in-place frame (no second window) up
   to the step-up. The owner finishes the step-up and types in the shell.

## Rollback

Put `machine-web.yml` back in DC_EXTRA and run `dc.sh up -d --no-deps --no-build osionos-app`.
The image `machine-adc07efc` stays on the host. Time: under a minute.

## What does not change

The bridge (`machine-904b9a0e`), the AI services, the proxy, the database: no migration, no
restart. Only the web container is recreated.

## Risks to weigh

- `main` carries ~180 develop commits production's web never had (the other session's AI
  custom agents, live mounts, profile, editor). The web may call routes the running bridge or AI
  service lack: those features fail where they call, the rest stays up. The bridge and AI service are
  NOT rebuilt tonight.
- The beta has served `develop` with production's bridge and AI service all day: that is the
  evidence that this web on that backend works (assistant answered, login, workspaces, terminal frame).
- Realtime (`/realtime/v1/ws`) answers 400 on production today already; unchanged.
