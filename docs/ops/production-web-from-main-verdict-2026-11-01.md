# Devil verdict: production web from osionos main (2026-11-01)

Plan: `docs/ops/plan-2026-11-01-production-web-from-main.md`. Record: ADR 0043.

**Verdict: PROCEED-WITH-CONDITIONS (D1–D12, V1–V9, R1–R6).** The plan is sound. It changes one
container, its rollback is proven by config hash, and the bridge routes the terminal needs are
byte-identical. **It cannot go tonight as things stand.** D1 fails right now: develop CI is red,
browser tests were skipped, and `main` does not contain the terminal. The plan's own candidate
check (step 4) cannot pass as written (E6).

## Steel-man

The web is the only layer that changes. Production's bridge `machine-904b9a0e` is an ancestor of
`main`. Every bridge module the in-place terminal calls is unchanged from 904b9a0e to develop (E3).
The beta has run develop's web against this same bridge and AI service all day, in a real browser.
The owner's node already trusts `:8443` and serves `/terminal/` (E8). So the shell surface is
already live today; tonight only adds the web code that uses it. The old image stays on the host,
and the rollback renders the running container's exact config hash (E1). Compose config shows no
drift (E1).

## Evidence (measured 2026-11-01, ~21:40 CET)

| # | Fact | Proof |
|---|---|---|
| E1 | Prod app was created with `DC_EXTRA=machine-web.yml` only. The rendered `--hash` today equals the running label `59cfc7580dc73c14…`, so there is no compose drift and the rollback recreates exactly today's container | `docker inspect …config_files` / `config-hash`; `DC_EXTRA=…/machine-web.yml dc.sh config --hash osionos-app` |
| E2 | `origin/main` = `b6e316c389be`, `origin/develop` = `6f1f03be6eae`. Develop is 22 ahead of main. **`72535a15` (the terminal merge) is NOT in main** | `git merge-base --is-ancestor 72535a15 origin/main` → false |
| E3 | `bridge-machines{,-pairing,-presence,-store}.mjs`, `ide-machine-protocol.mjs`, `bridge-account-sudo.mjs` and `bridge-guard.mjs` are identical at 904b9a0e and develop. Route `^/api/machines/(m-…)/(default\|identity\|token)$` with the one-identity-one-mint guard | `git diff --quiet 904b9a0e origin/develop -- …` → identical; `bridge-machines.mjs:37,200-209` @904b9a0e |
| E4 | The web's terminal calls `POST /api/machines/:id/identity`, then `/token`. It frames `http://127.0.0.1:4100/terminal/` (node-served, not app-served) | `src/features/machines/model/terminalFrameStore.ts:9,36`, `machinesApi.ts:157,169`, `machineWindow.ts:27`, `NodeVsCodeTerminal.tsx:79` @develop |
| E5 | Drift. Web: 258 develop commits since prod's base `36eb392c` (not ~180). Bridge: 88 commits (904b9a0e→develop); 28 server-side files. Behaviour the new web might need from the new bridge: `merge:true` page config (sent only by `services/osionos-ai/src/approvals/execute.ts:95`, so not web), object-databases filters (the web sends none, `objectDatabaseBridgeSync.ts:85`), content validation (protective only; prod lacks it today) | `git rev-list --count`, `git diff 904b9a0e origin/develop -- scripts/bridge-api.mjs` |
| E6 | Prod passes no `VITE_APP_VERSION`, so the index says `<meta name="osionos-build" content="image">`. "Index must name main-<sha8>" fails unless the overlay sets it | `curl :8443/` meta = `image`; `index.html:6`; rendered build args (E1) |
| E7 | **The beta never exercised production's sign-in.** The beta builds with `VITE_AUTH_MODE=portal`, and prod builds with the default (Prismatica handoff). Handoff code drift is small: `client.ts` wraps fetch with `connectivityAwareFetch`; `App.tsx` adds a skip link, toasts and the caret | `infrastructure/beta/update.sh` build args; `git diff adc07efc origin/develop -- src/features/auth src/shared/api/client.ts src/app/App.tsx` (42 lines) |
| E8 | The owner's node is at `1e6835e5` (in develop) with `--app-origin https://baas.tail10f2ea.ts.net:8443`. `/terminal/` answers 200 with `frame-ancestors https://baas.tail10f2ea.ts.net:8443 app://osionos https://baas-beta…` | `~/.config/systemd/user/osionos-node.service`; `curl -D - http://127.0.0.1:4100/terminal/` |
| E9 | Prod and beta send the same top-level headers (CSP `frame-ancestors 'none'`, XFO DENY, the same Permissions-Policy). No `frame-src` difference can block the frame on prod alone | `curl -D -` both origins |
| E10 | The beta builds with groot `main`'s Dockerfile; prod builds with `deploy/root` 488a2fc8. The only difference is the desktop `build/terminal` step, which the web does not use (E4) | `diff` of the two Dockerfiles on the host |
| E11 | Develop CI on 6f1f03be failed: `quality (root)` reports raw colour literals in `src/terminal-client/terminal.css`. **Browser tests: shards skipped**. Main's head b6e316c3 is red too | `gh run list/view --log-failed` |
| E12 | The beta browser check stopped at the step-up, so the frame's `ws://127.0.0.1:4100/api/pty` has never opened a shell from either web origin. The ADR 0041 verdict gates **main** on Firefox/Safari (U1), U6 (step-up cadence) and W7 (Node-22 ABI). None is recorded as measured on develop | verdict `…web-terminal-in-place.md`, the U table; `git grep` in docs/ide |
| E13 | The service worker changes: push-only becomes push plus an offline shell. Navigations are network-first, so a rollback takes effect on the next reload. `vite:preloadError` reloads once for stale chunks | `public/sw.js:48-117`, `src/app/main.tsx:47` @develop |
| E14 | Host: image `machine-adc07efc` = `2c5aebe9a9ee` is present. Docker root `/mnt/storage/docker` has 77 G free (92% used); `/home` has 24 G free. Compose v2.36.0 (has `--dry-run`). The app-main worktree's git dir is the **live checkout's** submodule gitdir | `docker images`, `df`, `docker compose version`, `git rev-parse --git-common-dir` |

## Risk

| Axis | Score | Why |
|---|---|---|
| Blast radius | 4 | Every public user of `:8443` (Funnel), every web feature, plus the shell on each paired machine with a node that trusts `:8443` |
| Reversibility | 2 | The container rolls back in under a minute, proven by hash (E1), and the image is kept (E14). Writes the new web makes to prod data are not undone. That class of write already exists through the beta today (ADR 0040), so this is not a new one-way door |
| Cost on failure | 4 | A broken handoff login means no user can sign in (E7) until the rollback. A develop page-content bug writes to production rows with no server-side validation behind it (E5) |
| Confidence | **4** | Today: CI red, browser tests skipped (E11); main lacks the feature (E2); the plan's candidate check is broken (E6); the prod sign-in path is untested by the beta (E7); the pty socket was never exercised end to end (E12) |

**Worst: confidence (4).** With D1–D6 met, it drops to 2 and the verdict stands.

## Failures nobody mentioned

1. **The candidate check can never pass** (E6). Production's index says `image`. Set
   `VITE_APP_VERSION: main-<S8>` in `web-main.yml`, or step 4 either fails or is skipped in silence.
2. **The beta proved the wrong sign-in.** It uses portal mode; production uses the Prismatica
   handoff (E7). If the handoff breaks, production has a total sign-in outage that the beta cannot
   show. That makes V2 the first check after the switch and R2 an immediate rollback.
3. **"Up to the step-up" is not "the terminal works"** (E12). The WebSocket, Chrome's LNA on that
   WebSocket (U1) and `Sec-Fetch-Site` on a nested frame's socket (U5) have not run yet. If U5 is
   wrong, the frame fails closed. Safe, but the feature the owner deploys for tonight would not work.
4. **ADR 0041 gates main, not only develop** (E12). Fast-forwarding main without Firefox/Safari,
   U6 and W7 breaks a recorded condition, unless the owner waives it in writing the way W15 was.
   Every one fails closed into W14's panel, so the waiver costs UX, not security.
5. **The "~180 commits" figure is wrong both ways** (E5): 258 on the web, 88 on the bridge. The
   bridge-to-web dependency is small, and the terminal's part of it is identical (E3).
6. **The worktree writes into the live checkout's gitdir** (E14). `git worktree add` and
   `git fetch` in `app-main` change refs and metadata under
   `~/Documents/groot/.git/modules/apps/osionos/app`. That is harmless if it stays
   `worktree add --detach` + `fetch`. Never `checkout` in `app/`.
7. **A develop push during the window** starts a beta rebuild (`nice`/`ionice`, up to 2700 s) on
   the same host as the prod build. It only costs load, but it can push the build past an operator's
   patience. Pin S and ignore later develop pushes.

## Conditions

S is the one osionos sha that ships; S8 is its first 8 characters. Paths on the host are relative
to `~/Documents/groot-wt/deploy`. Run each build/up under `devil watch`.

### Before (go/no-go: all must hold, or there is no deploy tonight)

- **D1 Green, for real.** The CI run on S is `success` with every Browser tests shard, the gate-on
  job, the stub-bridge job and `quality (root)` **run and green**. A skipped shard is not green.
  `origin/main` == S (a fast-forward, `git merge-base --is-ancestor b6e316c3 S`), and
  `git merge-base --is-ancestor 72535a15 S`. Today: **fails** (E2, E11).
- **D2 Beta at S, the whole path.** The beta's `deployed` == S, and its index meta says `beta-S`.
  On the beta in Chrome, the owner passes the step-up, types `whoami` in the in-place shell and gets
  output, then opens a second shell. This is the first time U1 (on the WebSocket) and U5 are
  exercised. If it fails on the beta, it will fail on prod: fix it first, or ship without counting
  on the terminal (D3b).
- **D3 Waivers in writing.** (a) The owner records in ADR 0041 Consequences that main ships with
  Firefox, Safari, U6 and W7 unmeasured, with W14's panel shown as the fallback; or they are
  measured. (b) If D2 was skipped, the owner accepts that the terminal may not work tonight and
  that a terminal failure alone is not a rollback (R-list).
- **D4 Overlay is a three-line diff.** `web-main.yml` = `machine-web.yml` with only `image:
  track-binocle/osionos-web:main-<S8>`, `build.context: …/deploy/app-main`, and
  `build.args.VITE_APP_VERSION: main-<S8>`. Proof: the `dc.sh config osionos-app` output under each
  DC_EXTRA, diffed, shows exactly those three lines. No env, port, healthcheck, mem_limit or other
  service differs.
- **D5 Clean source.** `git -C app-main rev-parse HEAD` == S, `git -C app-main status --porcelain`
  is empty, and `git -C app-main submodule status --recursive` shows no `-` or `+` prefix. Created
  with `worktree add --detach` (failure 6).
- **D6 Rollback rehearsal (no-op, before anything changes):**
  1. `docker image inspect -f '{{.Id}}' track-binocle/osionos-web:machine-adc07efc` starts `sha256:2c5aebe9a9ee`.
  2. `DC_EXTRA=$PWD/machine-web.yml ./dc.sh config --hash osionos-app` == the running label `59cfc7580dc73c14364ff579de96d36b128ed4d104f51c67681095b5b4ea17ac`.
  3. `DC_EXTRA=$PWD/machine-web.yml ./dc.sh --dry-run up -d --no-deps --no-build osionos-app` recreates nothing.
  4. `DC_EXTRA=$PWD/web-main.yml ./dc.sh --dry-run up -d --no-deps --no-build osionos-app` names `osionos-app` and nothing else.
  5. Write the rollback command (below) into `logs/rollback-main-<S8>.sh` before the switch.
  6. Baseline: `docker ps --format '{{.Names}} {{.Image}} {{.Status}}'` snapshot, a `docker images` ID snapshot, and the bridge's last 15 min of `/api/` 404 and 5xx by route (`docker logs --since 15m track-binocle-osionos-bridge-1`).

### During

- **D7 Build only the web.** `DC_EXTRA=$PWD/web-main.yml ./dc.sh build osionos-app`. Afterwards
  `main-<S8>` exists and every other `track-binocle/*` tag keeps its image ID (diff against D6.6).
- **D8 Candidate check (replaces plan step 4).** `docker run -d --rm --name web-candidate
  --network none track-binocle/osionos-web:main-<S8>`; within 30 s `wget -qO- http://127.0.0.1/`
  inside it contains `<title>` **and** `<meta name="osionos-build" content="main-<S8>" />`; then
  remove it. If either is missing, stop: nothing has switched.
- **D9 Switch one container.** `DC_EXTRA=$PWD/web-main.yml ./dc.sh up -d --no-deps --no-build
  osionos-app`. Within 60 s `track-binocle-osionos-app-1` is `healthy` on `main-<S8>`. In the
  `docker ps` diff against D6.6, it is the **only** line that changed: the bridge is still
  `machine-904b9a0e` with uptime > 27 h, the AI service still `cors-4fb0102c`.

### After: the verify list, in this order

- **V1** `curl --noproxy '*' -sD - https://baas.tail10f2ea.ts.net:8443/` gives 200, meta `main-<S8>`, and the same CSP/XFO/Permissions-Policy as E9.
- **V2 Production sign-in (the beta never ran this one).** Sign in as `dev.pro.photo@gmail.com` through the Prismatica handoff: `/api/auth/bridge/consume` 200, landing in a workspace. Reload a signed-in tab: still signed in.
- **V3** Switch workspaces, open a page, edit a block, reload: the edit persists. Open one database view.
- **V4** The assistant answers one question; its AI requests are 200.
- **V5** Settings › Machines lists the owner's machine as online.
- **V6** Terminal → New Terminal: the frame opens in place (no window); `identity` 2xx, `token` 403 `sudo_required`, then step-up, then `token` 200; the owner types `whoami` and gets output; a second shell opens.
- **V7** Bridge 15 min after the switch: no `/api/` route returns 404 that did not in D6.6, and no new 5xx class.
- **V8** A tab opened **before** the switch, navigated to a lazy view (database, mermaid), reloads once and works. No reload loop.
- **V9** Record in `DEPLOY-NOTES.md`: S, the image ID, the time, V1–V8 results. Keep `machine-adc07efc` and `main-<S8>` at least 7 days; no prune.

### Roll back on any one of

- **R1** V1 fails, or the container is not healthy within 60 s.
- **R2** V2 fails for the working account (sign-in or session reload).
- **R3** V3: an edit not persisted, or a page that renders on the old build renders blank or broken.
- **R4** V4 fails (it passed on the beta against the same AI service, so a failure is the build's).
- **R5** V7 shows a new 404 route or a new 5xx class.
- **R6** Anyone reports data that looks wrong. Roll back first, investigate on the beta.

**Not a rollback on its own:** V6 (terminal) or V5 failing. Leave production up, debug on the beta,
and fix forward. A rollback would only bring back the window card.

**Rollback:** `DC_EXTRA=$PWD/machine-web.yml ./dc.sh up -d --no-deps --no-build osionos-app`.
Then confirm that the meta says `image`, the container label hash == `59cfc758…` (E1), and the
bridge and AI lines are unchanged. Clients pick up the old shell on their next navigation
(network-first, E13). What it does **not** undo: rows the new web wrote.

- **D10 Ownership.** One operator runs D6–D9 and holds the rollback; the owner runs V2–V6 in their
  browser. Nobody else deploys to the host during the window: no `make public-up`, no
  `public-funnel.sh`, no bridge or AI recreate (`dc.sh` header).
- **D11 The beta stays as it is.** No change to the beta or its timer is needed. Its rebuilds touch
  only `osionos.beta=1` objects (`update.sh`).
- **D12 Not tonight.** This plan does not cover a bridge or AI rebuild from main. The bridge's
  content validation (E5) reaches production only with that later, separately ruled step.

## Caveat

E5's dependency scan is a grep over the web's calls to new bridge behaviour. It catches a new route
or a new body flag by name. It misses a web change that depends on a changed **response shape** of
an existing route. V3 and V7 cover that, and the beta's day of traffic is the rest of the evidence.
