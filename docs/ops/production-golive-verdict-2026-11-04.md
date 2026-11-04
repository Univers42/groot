# Devil verdict: production go-live from osionos main (2026-11-04)

Plan: `docs/ops/plan-2026-11-04-night.md` item 5, plus the team lead's four steps (main ← develop,
bridge from main, web from main with the whiteboard URL, groot #174). Prior ruling: ADR 0043 and
`production-web-from-main-verdict-2026-11-01.md` (D1–D12, V1–V9, R1–R6), which still bind the web
step. Record: ADR 0046.

**Verdict: BLOCK now (08:20 CET). It becomes PROCEED-WITH-CONDITIONS G1–G16 once G1–G6 hold.**
The #174 proxy step (A) is independent of osionos. It may go now under G7–G8. The osionos steps
B–D may not:

- Develop CI on aebe75df is red, and PR #297 is still open (E1).
- ADR 0041 requires measurements before `main` that nobody has taken (E2).
- The bridge's own precondition hash does not match the running container (E3), so a bridge
  recreate tonight would change something nobody has named.

## Steel-man

The bridge drift is small and mostly additive (E4). 904b9a0e is an ancestor of main, and the
diff to develop touches 12 bridge files in `scripts/` (+332/−32 on main). There are no new tables,
columns or migrations (E5). The new machine token is byte-identical to the old one when
`remember` is false. The resume assertion carries its own prefix and domain tag, so an old node
refuses it (E6). Sessions live in Postgres under an unchanged `TOKEN_VERSION`, and step-up and
identity state live in Redis, so a restart signs nobody out (E7). Media signing is inert while
`MEDIA_URL_SECRET` is unset (E8). The web half was already ruled sound (ADR 0043). The whiteboard
needs one build arg that the Dockerfile already declares, and the hydrawn alias and the bridge
already agree on the origin (E9). Every image is kept on overlay2 under a distinct tag (E10). Each
step therefore has a rollback that is one command long.

## Evidence (measured 2026-11-04, 07:50–08:25 CET)

| # | Fact | Proof |
|---|---|---|
| E1 | `origin/main` = 6daa23ba, `origin/develop` = aebe75df, 27 ahead, 0 behind. Develop CI on aebe75df: **failure** (Browser tests shard 6/6, stub bridge URL). PR #297 is OPEN at dcd80bda, which contains aebe75df and has all checks pass. Its 10 extra commits do not touch `scripts/` | `git rev-list --count`; `gh run view <id> --json jobs`; `gh pr checks 297`; `git diff --stat aebe75df dcd80bda -- scripts/` (empty) |
| E2 | ADR 0041:42 says "Firefox, Safari and U6 are measured before main". ADR 0041:67 says "R-U1 (the production access-token TTL) and R-U2 (Safari, Firefox) stay open before main". No waiver is recorded | `sed -n 42p;67p docs/adr/0041-*.md` |
| E3 | **Bridge drift.** As written in #174 step 3, the render errors with `required variable OSIONOS_PUBLISH_SOCKET_DIR is missing`. With the running mount (`~/.local/state/osionos-publish/sock`), it renders `91df09c4…` against a running label of `d08c238f…`. Env (compared by hashed values), image, mem_limit and volumes all match. Every input file predates the container (created 17:58:45Z, `machine-release.yml` mtime 17:56:53Z). The differing field is **unknown** | `DC_EXTRA=$BR dc.sh config --hash osionos-bridge` vs the label; a python field diff (env/vol/image equal) |
| E4 | Bridge 904b→develop: content validation (422 on a bad page or database shape), the blank-database guard, a workspace_id fix that no longer clears, `ipPrefix` hidden when private, a Turnstile proof header (sent only when `enforce` and verified, and prod sets no mode), resume, signed media, and the node `isNodeHost` guard | `git diff 904b9a0e origin/develop -- scripts/` |
| E5 | No migration. The diff adds no `osionos_*` table to the bridge, and the stat has no `.sql`, `models/` or migration file | `comm` of the table names; `git diff --stat \| grep -iE 'migrat\|sql\|schema'` → only a test seed |
| E6 | `signMachineToken` without `remember` is the old byte format. Resume = `osionos_mr1` + `osionos-machine-resume-v1` | `scripts/ide-machine-protocol.mjs` @develop (KINDS, signMachineToken doc) |
| E7 | `TOKEN_VERSION = 'osionos_v1'` at both shas. The bridge has `OSIONOS_BRIDGE_REDIS_URL` set | `bridge-sessions.mjs:53`; `docker inspect` env names |
| E8 | The only new env names are `MEDIA_URL_SECRET{,_PREVIOUS}` and `MEDIA_URL_ENFORCE`, all unset in prod, so `signMediaPath` returns null and bare reads still serve. **#233/#235 are not closed by this deploy** | `comm` of the env names; `bridge-media-sign.mjs` header |
| E9 | `app.Dockerfile:55 ARG VITE_WHITEBOARD_APP_URL=https://localhost:3007`. The live checkout's `docker-compose.public.yml:46` sets it to `""`, so the overlay must win (it is last in DC_EXTRA). hydrawn alias: `frame-ancestors https://baas.tail10f2ea.ts.net:8443`. Bridge: `OSIONOS_WHITEBOARD_ORIGIN=https://osionos.hydrawn-app.pages.dev` (from `whiteboard.yml`). The prod bundle holds `localhost:3007` (`EmbedFrame-*.js`) | `grep` on the host; `curl -D -` |
| E10 | The storage driver is overlay2 (not the containerd snapshotter). Kept: web `machine-adc07efc` 2c5aebe9a9ee, bridge `machine-904b9a0e` 70b800b16330. /mnt/storage has 108 G free | `docker info`, `docker images`, `df` |
| E11 | The proxy renders `ab7b4692…` == running. The app renders `59cfc758…` == running (ADR 0043 E1 still holds) | `dc.sh config --hash` |
| E12 | LiveKit 7880/7881 and UDP 50000–50060 are already on 127.0.0.1, and no container publishes on 0.0.0.0. The "loopback" half of #174 needs no host change | `docker port track-binocle-livekit-1`; `ss -ltn` |
| E13 | `agents/settings`, `web/settings` and `ai/access-tokens` are served by **osionos-ai**, not the bridge. They exist in the running `cors-4fb0102c` (an ancestor of 904b). `/api/imports`, `/api/billing` and `/api/settings/actions` are mounted by **no server** on develop (`ImportPanel.tsx:58`, #239). The bridge deploy fixes none of these | `git cat-file -e 4fb0102c:…`; `git grep` |
| E14 | The whiteboard routes are identical at 904b and develop (`bridge-whiteboard*.mjs` are not in the diff): prod already serves them | `git diff --stat` |
| E15 | Production CI pushes GHCR `:latest` on main. Nothing on the host pulls it; the only timer is `osionos-beta.timer` (~3 min) | `ci.yml:94-121`; `systemctl --user list-timers` |

## Risk

| Axis | Score | Why |
|---|---|---|
| Blast radius | 5 | The bridge serves prod **and** the beta. The proxy fronts :8443, :10000 and the apps for everyone |
| Reversibility | 3 | Container swaps reverse in one command, but the bridge rollback target is unproven (E3). Rows written under the new validation are not undone. A main fast-forward is a published ref |
| Cost on failure | 4 | A bridge that 422s a legacy page loses that page's edits for every user who opens it (E4: old `safeJsonArray` coerced, the new one refuses). The client's behaviour on a 422 save is **unverified** |
| Confidence | **4** | CI red (E1); ADR 0041 gates unmet (E2); bridge drift unexplained (E3); stored data never run through the validator; the new bridge has never served live traffic (the beta uses the prod bridge) |

**Worst: confidence 4, blast 5.** With G1–G6 met, confidence drops to 2.

## Failures nobody mentioned

1. **#174 step 3 cannot pass as written** (E3): it omits `OSIONOS_PUBLISH_SOCKET_DIR`, and even
   with it the bridge hash differs. "Run step 4 without the overlay" is therefore not a proven
   rollback either.
2. **The new bridge has never served live traffic.** The beta proves develop **web** × the 904b
   **bridge**, not the reverse. Content validation is new refusal behaviour aimed at stored rows
   that predate it.
3. **Order matters, and only one order is proven.** Web from S × bridge 904b has run on the beta
   for days. Old web adc07efc × new bridge has been tested nowhere. So the web goes first.
4. **The security claim is overstated** (E8). Signed links only start once `MEDIA_URL_SECRET` is
   set, and they are only enforced with `MEDIA_URL_ENFORCE`. Tonight's deploy ships the code, not
   the protection.
5. **"Console zero" cannot come from this deploy** (E13). The three dead routes 404 on every bridge;
   the web must stop calling them.
6. **Remember goes live for prod and the beta at once.** Under the R5 override (ADR 0041), any
   develop commit can then run commands in the owner's shell without a code. That risk was
   accepted, but only once the main gates are met (E2).
7. My own probe pulled `public.ecr.aws/docker/library/node:22-bookworm-slim` onto the host
   (07:55 CET). Every layer already existed, but the tag is new. `bridge.Dockerfile:13` builds
   from it, so the next bridge build uses that digest (`sha256:4b150b48…`).

## Conditions

S = the osionos sha that ships, S8 its first 8 characters. Host paths are relative to
`D=~/Documents/groot-wt/deploy`.
`BR="$D/publish-socket.yml:$D/whiteboard.yml:$D/share-release.yml:$D/machine-release.yml"` and
`export OSIONOS_PUBLISH_SOCKET_DIR=/home/dlesieur/.local/state/osionos-publish/sock`.
Run every build and `up` under `devil watch`.

| # | Condition | TEST |
|---|---|---|
| G1 | #297 merged; S = develop head; the CI run on S is `success` with **no** skipped or failed job (6 shards, stub bridge, gate on, quality root including `make test-bridge`) | `gh run list -R Univers42/osionos --branch develop -L1 --json headSha,conclusion` → S, success; `gh run view <id> --json jobs --jq '.jobs[]\|select(.conclusion!="success")'` → empty |
| G2 | The beta serves S, and the ADR 0043 D2 path passes on it (step-up, `whoami`, second shell) | `curl --noproxy '*' -s https://baas-beta.tail10f2ea.ts.net/ \| grep -o 'beta-S8'` |
| G3 | ADR 0041 main gates **measured**, not waived by an agent: Firefox and WebKit on the beta either open the shell or show the W14 panel, with no hang; U6 recorded; R-U1 = `exp−iat` of a production access token | Playwright `--project=firefox,webkit` on the beta terminal spec; for R-U1, decode the JWT payload `exp-iat` of a live token, recorded in ADR 0041 |
| G4 | **Stored data passes the S validator**: 0 refusals for every `osionos_pages.content` and `osionos_object_databases.state` row | Read-only export of `(id, content)` and `(id, state)`, then `node -e` importing `validatedPageContent` and `validatedDatabaseState` from S's `scripts/bridge-content-validation.mjs` → refused count 0. If >0, stop and fix the data or the validator first |
| G5 | **The bridge drift is explained**: the field behind `91df09c4` ≠ `d08c238f` is named and judged harmless, or the container is first re-created under the *unchanged* set (still 904b) and shown healthy, which makes the rollback target real | `DC_EXTRA=$BR dc.sh config --hash osionos-bridge` == the running label; otherwise a written field diff |
| G6 | Backups taken and tested before any bridge write path changes: a dump of `osionos_pages` and `osionos_object_databases` dated today, which `pg_restore --list` (or `jq length`) can read | `ls -l <dump>`, `pg_restore --list <dump> \| wc -l` > 0 |
| G7 | Proxy step: the hash precondition holds, the dry run names only `local-https-proxy`, and the rollback is written to `$D/logs/rollback-proxy-174.sh` before the switch | `dc.sh config --hash local-https-proxy` == `ab7b4692…`; `DC_EXTRA="$D/livekit-tls.yml:$D/frame-ancestors.yml" dc.sh --dry-run up -d --no-deps --no-build local-https-proxy` |
| G8 | After the proxy step: `nginx -t` rc 0, healthy ≤ 60 s, `:8443` and `:10000/api/auth/bridge/health` 200, and the two apps answer with `frame-ancestors … :8443 https://baas-beta.tail10f2ea.ts.net` | the #174 comment 6624357594 verify block |
| G9 | Web overlay `web-main.yml` = `machine-web.yml` + 4 lines: image `main-S8`, context `$D/app-main` (detached at S, clean), `VITE_APP_VERSION: main-S8`, `VITE_WHITEBOARD_APP_URL: https://osionos.hydrawn-app.pages.dev` | `diff <(DC_EXTRA=$D/machine-web.yml dc.sh config osionos-app) <(DC_EXTRA=$D/web-main.yml dc.sh config osionos-app)` → exactly those lines |
| G10 | ADR 0043 D5–D9 hold for the web; the candidate bundle contains the hydrawn URL and not `localhost:3007` | `docker run --rm --network none … grep -rl osionos.hydrawn-app.pages.dev /usr/share/nginx/html/assets` ≥ 1; `localhost:3007` → 0 |
| G11 | Bridge overlay `bridge-main.yml` is listed **after** `machine-release.yml` and sets only `image: osionos-bridge:main-S8` and `build.context: $D/app-main`. `OSIONOS_WHITEBOARD_ORIGIN`, the secrets and the allowlist are unchanged. Do not set `MEDIA_URL_*` tonight | `diff` of `dc.sh config osionos-bridge` under `$BR` vs `$BR:$D/bridge-main.yml` → image and build only |
| G12 | A candidate bridge boots offline: `node --check` and an import of `scripts/bridge-api.mjs` in the image exit 0 | `docker run --rm --network none osionos-bridge:main-S8 node -e "import('./scripts/bridge-api.mjs').then(()=>process.exit(0))"` |
| G13 | Distinct tags only, no prune for 7 days; old IDs unchanged after each build | `docker image inspect -f '{{.Id}}'` for `machine-adc07efc` (2c5aebe9a9ee) and `machine-904b9a0e` (70b800b16330), before and after |
| G14 | LiveKit env (`livekit-tls.yml`) is added to the bridge in its **own** recreate after the bridge is verified, and stays in DC_EXTRA for every later recreate | `docker inspect … \| grep ^LIVEKIT_CLIENT_URL=` → `wss://baas.tail10f2ea.ts.net:10000/livekit`; `curl …/livekit/rtc/v1/validate` 4xx, not 502 |
| G15 | V-checks after each step, by the owner's working account in Chrome with chrome-devtools: console has 0 errors and 0 warnings **except** the known dead routes (E13), which are listed and not counted as regressions | the V-list below |
| G16 | One operator, one window. The beta timer is stopped during the bridge step (it rebuilds on every develop push), then re-enabled. No other host deploy | `systemctl --user stop osionos-beta.timer` … `start`; `systemctl --user is-active osionos-beta.timer` |

## Order of operations, with a rollback per step

| Step | Action | Gate | Rollback |
|---|---|---|---|
| 0 | Snapshots: `docker ps`, image IDs, the bridge's 15-min 404/5xx by route, write all rollback scripts | — | — |
| A | Proxy: recreate with `livekit-tls.yml:frame-ancestors.yml` (can go now) | G7 → G8 | `bash $D/dc.sh up -d --no-deps --no-build local-https-proxy` (no DC_EXTRA) → hash `ab7b4692…` |
| B | Merge #297 → CI green on S → the beta at S → `main` fast-forwarded to S | G1–G3 | No ref rollback (never force-push main); production is untouched until C, so fix forward |
| C | Web `main-S8` with the whiteboard URL | G9, G10, ADR 0043 D6–D9 → V1–V8 + whiteboard frame | `DC_EXTRA=$D/machine-web.yml dc.sh up -d --no-deps --no-build osionos-app` → hash `59cfc758…` |
| D1 | Bridge `main-S8` (image only) | G4–G6, G11–G13, G16 → V2, V3, V7, V10–V12 | `DC_EXTRA=$BR dc.sh up -d --no-deps --no-build osionos-bridge` → the G5-proven hash, image 904b |
| D2 | Bridge + `livekit-tls.yml` | G14 | `DC_EXTRA="$BR:$D/bridge-main.yml"` recreate (drops the env) |

**V-list (in addition to ADR 0043 V1–V9):**

- V10: whiteboard: `/draw` opens the hydrawn frame, `POST /api/whiteboard/token` 200, and a board lists.
- V11: Mail and Calendar embed on the beta with no frame-ancestors console error.
- V12: a page with an image renders; media 200 (bare URLs, since signing is off).
- V13: `POST /api/machines/:id/resume` from the prod web after "remember": a shell opens without a code; on the beta, the same.

**Roll back the bridge on any one of these:**

- a 422 on a page save that 904b accepted;
- a new 404 or 5xx route;
- any sign-in failure (V2);
- the container not healthy in 60 s.

A terminal, whiteboard or remember failure alone is fixed forward.

## Not covered

- The owner's node `--remember-origin` and the `~/.osionos/src` update (laptop, a separate step).
- A beta whiteboard (it needs its own hydrawn alias; whether the bridge accepts more than one
  origin is unverified).
- Setting `MEDIA_URL_SECRET`.
- A second-machine LiveKit media path (ADR 0045).
- An AI service rebuild.

## Caveat

G4 is only as good as the export. A row written between the export and the switch is not checked;
the rollback trigger "a 422 on a save" covers that window. E3's field diff compared env, image,
volumes, mem_limit, user, command, networks and labels; it did not find the drifting field. The
cause may lie in a field the hash covers and I did not inspect, such as the healthcheck, network
aliases or `expose`.

## Executed

- **Step A, 2026-11-04 08:23 CET:** G7 held (hash `ab7b4692` = the running label; the dry run named only `local-https-proxy`; `logs/rollback-proxy-174.sh` was written first). Recreated with `livekit-tls.yml:frame-ancestors.yml`. G8 held: healthy in about 10 s, `nginx -t` ok, `:8443` 200, `:10000/api/auth/bridge/health` 200, both app hosts serve `frame-ancestors https://baas.tail10f2ea.ts.net:8443 https://baas-beta.tail10f2ea.ts.net`, and the `/livekit/rtc` include is loaded (1).
- **G4, 2026-11-04 (read-only): held, 0 refusals.** A node script ran inside the running production bridge (`track-binocle-osionos-bridge-1`, 904b) with `configFromEnv` + `createPg(...).asService()` from `/app/scripts`. It made GET requests only, paging `osionos_pages` by id and `osionos_object_databases` by `(owner_id, db_key)`, and passed each row through osionos develop `19f9f011`'s `scripts/bridge-content-validation.mjs` (sha256 `e7026816…`, identical to `origin/develop`). The validator was copied to the container's `/tmp/g4`, never `/app`, and `/tmp/g4` was deleted afterwards (`ls` → no such file).

  | Table | Rows | Refused (422) |
  |---|---|---|
  | `osionos_pages.content` (`validatedPageContent`) | 10,057 | **0** |
  | `osionos_object_databases.state` (`validatedDatabaseState`) | 782 | **0** |

  Not vacuous: 9,023 pages carry 30,684 top-level blocks (children walked to depth 64), 1,034 hold `[]`, none is null, and all 782 database slices hold at least one of `databases`/`pages`/`views`. No repair or tolerance is needed. Caveat: this was a snapshot. A row written after the read, or between pages of the offset scan, was not checked; the rollback trigger "a 422 on a save" covers that window.
