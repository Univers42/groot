# 0075. A deploy keeps the last five builds' assets in a per-deployment volume, and `/assets/` never falls back to the app page

- Status: accepted. PROCEED-WITH-CONDITIONS D313-1–D313-15 (osionos#313). On groot develop 0167a00d
  and osionos develop 483c5b0f4. Live 2026-11-23 (web d2db4373 rebuilt with groot 7ebe3935's
  app.Dockerfile): D313-12 seeded 1158 files before the swap; D313-15 a chunk only the previous
  build had answers 200 `public, immutable`.
- Date: 2026-11-22
- Deciders: devil (ruling); osionos web operator (live with it)

## Context

A deploy recreates the web container from an image that holds only its own build. Every tab still
on the previous build then asks for chunks that no longer exist. Facts were measured on local live
images, `--network none`, on 2026-11-22.

- **Each build renames about 58 % of the chunks.** Consecutive live images add 630 of 1092 asset
  files, about 19.6 MB, even for a test-only commit (0e10ff56 on 6de25733). The hash change most
  likely starts in the baked `VITE_APP_VERSION` (inferred, not measured). Five builds together are
  3612 files, 113,318,175 bytes.
- **A missing `.js` answers 404 `text/html`. A missing `.ttf` answers 200 `text/html`
  (index.html).** The asset regex in osionos `nginx.conf` has no `ttf`, so `location /` falls back
  to the SPA.
- **The service worker caches any 200 for a build file forever.** A font URL that once got
  index.html keeps getting it. The worker never fetches a lazy chunk ahead of time, and `sw.js` has
  the same bytes on every deploy, so it does not reinstall per build.
- **The failed lazy import logs a warning, then the ADR 0061 reload fires.** That reload can show
  "Leave page?" when edits are unconfirmed. In Firefox the same failure reads "A ServiceWorker
  intercepted the request and encountered an unexpected error" (`sw.js?v=2` line 132), seen on the
  red run.
- **A failing `/docker-entrypoint.d/*.sh` aborts nginx start** (`rc=3`, measured), so a start
  script that can fail is a web outage.
- The beta builds osionos develop with groot main's Dockerfile, so anything the image needs at
  start must live in groot, not in the osionos submodule.

## Decision

1. **Keep step at start (D313-2–D313-5).** `app.Dockerfile` writes
   `/docker-entrypoint.d/40-keep-assets.sh` inline. On every start it copies the current
   `/assets` into `/var/lib/osionos-kept/assets` and keeps the union of the last **K = 5** distinct
   builds.
   - A build id is the sha256 of the sorted asset file list, so a restart of the same build is
     not a new build.
   - Each file is written under a temp name and renamed, and an existing name is never
     overwritten. Stray temp files are removed at start, and their names can never match a
     chunk URL.
   - The script exits 0 on every start path. It logs one `skipped:` line when the directory is
     not mounted, is read-only, or has under 1 GiB free.
2. **nginx fallback (D313-1).** `location ^~ /assets/` tries the image, then `@kept` (root
   `/var/lib/osionos-kept`), then 404. `/assets/` never reaches index.html. Both locations repeat
   the immutable cache headers and the CSP `frame-ancestors 'none'` / XFO DENY pair, because a
   location with its own `add_header` drops the server-level ones.
3. **Worker guard (D313-7).** `buildFile` never caches a `text/html` answer, and it evicts and
   re-fetches a kept HTML entry. That second rule repairs fonts already poisoned in browsers today.
   `WORKER_URL` stays `/sw.js?v=2`.
4. **One volume per deployment (D313-6).** Live mounts `track-binocle_osionos-kept-assets` and
   the beta mounts `osionos-beta_osionos-beta-kept-assets`. Beta churn never prunes live's grace
   window.
5. **Operator modes (D313-12, D313-13).** `--purge` keeps only the running build. `--seed` keeps an
   assets tar read from stdin. Both exit non-zero on failure. The runbook
   (`docs/ops/plan-2026-11-01-production-web-from-main.md`, "Kept builds") gives both commands. A
   security-hotfix or storage-format deploy purges, so no open tab keeps running the replaced code.

## Alternatives considered

- **Copy the previous image's `/assets` into the new image.** All four deploy paths would have to
  pass the previous image, each image grows about 19.6 MB per kept build, and a rollback image
  lacks the newer build's chunks. The volume needs no deploy-script change, because every path
  starts the container.
- **Precache chunks in the service worker.** `sw.js` has no build step and the same bytes on every
  deploy. A build is about 562 js files against the 400-entry cap. It also does nothing for a
  browser without the worker. It becomes right only with a build-generated, versioned worker.
- **An update prompt instead of the reload.** ADR 0061 already rejected a prompt in place of the
  reload, and no deploy-detection signal exists. It needs its own ruling.
- **Reload on a chunk 404 alone.** It already exists (ADR 0061), and the 404 and the warning are
  logged before it fires. It stays as the fallback beyond K.

## Consequences

- osionos 8a7970c6c, 181d39b3b, 66e2aa17c, 483c5b0f4: nginx locations, worker guard, three canvas
  cases (red first on the old `sw.js`), and `tests/e2e/deploy/keptAssets.spec.mjs`. The spec runs
  only when `DEPLOY_SWAP_DIR` is set and stubs the realtime socket.
- groot f51033e9 (red bats), 03501005, 29635b27, b000f38b, 8893df1d (red), 8135df64, 06e0ea05,
  9399c2ee, pin 0167a00d. `scripts/tests/osionos-kept-assets.bats` (8 tests) runs in CI with the
  docker socket.
- Evidence (builder run, logs in the coordinator's `r313/logs/`):
  - The A→B swap e2e failed on the pre-fix pair in Chromium and Firefox, then passed 3 times on
    both with the fix.
  - The `preloadErrorReload` e2e passed 5 of 5 on both engines.
  - The canvas suite passed 6414 of 6414.
  - Start to first 200, median of 7 runs: 131 ms with no keep step, 223 ms on the first start
    (1474 ms cold), 186 ms on a restart, 263 ms on the sixth build. The bound was 2 s.
- **Open tabs survive up to 5 deploys.** A tab open across more deploys still gets a 404, then
  the ADR 0061 reload. Two builds with identical file lists count as one. An unmounted volume
  means no grace at all. The script header's `Caveat:` names all three.
- **Old code lives longer.** Purging is part of the hotfix and format-change runbook.
- The volume holds at most about 113 MB per deployment, and no user data.
- **The first switch still breaks open tabs** unless the operator runs `--seed` from the running
  container right before it (a live action).
- Not done here:
  - The live `dc.sh` chain was not rendered.
  - The beta host's copy of `infrastructure/beta/compose.yml` must be updated by hand before the
    beta picks up its volume.
- Follow-up, not required: stop `VITE_APP_VERSION` from renaming about 630 chunks per build. That
  would shrink the 404 surface and the retention size. It needs its own issue and measurement.
- Revisit if the worker gains a build step, or if chunk churn per build is cut.
