# Beta and release pipeline (Cloudflare Pages + host pull timer) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** every push to `develop` of osionos, osionos-mail and osionos-calendar is live as a beta
(`develop.<project>.pages.dev` + a beta bridge on this host pulled from ghcr by provenance), and
every push to `main` is a release bundle on `<project>.pages.dev` (dark for the osionos app until
Phase 2).

**Architecture:** static bundles are built in CI and pushed to Cloudflare Pages with a build meta
tag that CI polls back; the osionos bridge image is built and attested in osionos CI, and a systemd
user timer on this host pulls it by digest only after `gh attestation verify` proves it was built
by `ci.yml` on `refs/heads/develop`, behind a beta nginx on `127.0.0.1:4001` exposed by the apps
node's Funnel on port 10000. Nothing is pushed into the host; nothing holds a cross-repo token.

**Tech Stack:** GitHub Actions (`cloudflare/wrangler-action`, `actions/attest-build-provenance`,
`docker/build-push-action`), Cloudflare Pages, ghcr, `gh attestation`, docker compose, nginx,
Tailscale Funnel (userspace node), systemd user units, bash + bats + shellcheck.

**Spec:** `docs/superpowers/specs/2026-10-26-beta-release-pipeline-design.md` (rev 3, approved
2026-10-26). The devil BLOCKED rev 1; C1–C13 are folded into rev 3 and carried below as
acceptance criteria. **Gate G0 (ruled 2026-10-26): PROCEED-WITH-CONDITIONS**, new conditions
C14–C20 below (verdict: `.claude/agent-memory/devil/beta-pipeline-rev3-verdict.md`). Gating:
Tasks 1–5 and 8–11 proceed; Task 3 commits only in its C17 shape; the Task 6 and Task 7 commits
and Task 12 Step 5 onward need C14, C15, C16, C18 and C19 green.

## Global Constraints

- Secrets are pasted by the user with `gh secret set`; Claude never writes a secret value anywhere
  and never prints one (names + set/unset only).
- Every CI image pull goes through `mirror.gcr.io` under its `public.ecr.aws` name (the
  `graph-studio.yml` step is the pattern).
- Actions pinned to tags (`actions/checkout@v7`, `actions/setup-node@v7`, `docker/login-action@v4`,
  `docker/metadata-action@v5`, `docker/build-push-action@v6`); `cloudflare/wrangler-action` and
  `actions/attest-build-provenance` pinned to the newest `vN.x.y` tag older than two weeks, read
  with `gh release list -R <owner/repo>`; wrangler itself pinned by `wranglerVersion`.
- Every new shell script: `shellcheck -S style` clean, a bats file under `scripts/tests/`, a
  `Caveat:` line on every heuristic/timeout/poll (rules/caveat.md), every external command under
  `timeout`.
- Backward compatible: nothing changes until a variable, secret or make target is used.
  `make public-up` with no new variables prints the C13 baseline recorded in Task 1.
- Commit messages: Conventional, trailer-free (no `Co-Authored-By`, no "Generated with").
- Landing (user's rule 2026-10-26): local merge into `develop` then `main`, pushed to the ssh
  remote with bypass; no PR merges; every workflow on the pushed commit green; an outdated workflow
  is repaired against the new behaviour, never skipped. Never force-push.
- Never `tailscale funnel reset` on the baas VM node or on the apps node; close single ports with
  `funnel --https=<port> off`.
- Pages project names: `osionos` (exists, adopted), `osionos-mail`, `osionos-calendar`.
- Beta bundle: `VITE_AUTH_MODE=portal`, `VITE_API_URL=https://osionos-apps-1.tail10f2ea.ts.net:10000`.
  Release bundle: `VITE_AUTH_MODE=` (empty), `VITE_API_URL=https://baas.tail10f2ea.ts.net:10000`.
  Both: `VITE_BAAS_URL=https://baas.tail10f2ea.ts.net:8443`, the other public args of
  `docker-compose.public.yml:29-52` with `VITE_MAIL_APP_URL`/`VITE_CALENDAR_APP_URL` = the Pages
  origins of the same branch (`https://develop.osionos-mail.pages.dev` / `https://osionos-mail.pages.dev`, same for calendar).
- **C14** the attestation proves the branch from the Sigstore certificate, never from the
  predicate: `gh attestation verify … --cert-identity https://github.com/Univers42/osionos/.github/workflows/ci.yml@refs/heads/<branch> --deny-self-hosted-runners`;
  the predicate ref is a second check only.
- **C15** the beta bridge env is an allowlist (`KEY: ${KEY}` per key the bridge reads), no
  `env_file: .env.local`, no `volumes`; none of `GITHUB_PAT FLY_API_TOKEN DOCKER_PAT DOCKER_PAS
  DOCKER_USER DOCKER_USERNAME SONAR_TOK EMAIL_RECUP_ADMIN_VAULT` reaches the container.
- **C16** no unverified reference ever runs in beta: `make beta-up` = `release-pull.sh beta --once`
  (verify, then run `repo@sha256:`); "unchanged" only when the running digest is in the
  verified-state file, else verify first; a hand rollback to `:sha-<prev>` is verified the same way.
- **C17** osionos CI: a build-only job on every branch with `contents: read`; a separate
  push+attest job with `packages/id-token/attestations: write` only on `push` to main/develop.
- **C18** the `develop` ruleset is created before the branch is pushed, with
  `require_last_push_approval: true` and `dismiss_stale_reviews_on_push: true`.
- **C19** rollback by the previous verified `repo@sha256:` digest (state file), never an image id;
  the live negative test uses `:sha-<main sha>` (attested to `refs/heads/main` only) → exit 2.
- **C20** (non-blocking, before Phase 2): implement the `public-up` lock claimed in the spec or
  strike it.
- Measured 2026-10-26: the app bundle is 966 files, 35 MiB (`track-binocle/osionos-web:public`,
  `/usr/share/nginx/html`), under Pages' 20,000-file cap; the per-file cap is 25 MiB.

## Review Focus

1. **A Pages deploy whose `index.html` still says `%VITE_APP_VERSION%`** (env unset in the build)
   must fail the job, not poll for 15 min: Task 5 `pages-wait.sh` treats a literal `%` as a
   mismatch and the build step greps the meta before deploying.
2. **A file over 25 MiB or more than 20,000 files in the bundle** (a future pack growth) must fail
   before `wrangler pages deploy` with the offending path: Task 5 build step counts and sizes.
3. **A timer tick racing `make beta-up`** must wait or refuse, never recreate twice: Task 7 bats
   `holds the lock: a second runner exits 75 with "locked"` and Task 6's make target takes the
   same lock.
4. **An attested image whose certificate ref is a feature branch** (built by a `ci.yml` edited
   on `feat/x` whose predicate claims `refs/heads/develop`, hand-tagged `:develop`) must be
   refused: Task 7 bats `refuses a certificate whose ref is not refs/heads/develop even when the
   predicate says so` (C14).
5. **A visitor's stale service worker (`public/sw.js`) serving the old bundle after a deploy** is
   not detectable from CI: Task 5 polls with `Cache-Control: no-cache` and the runbook says a
   hard reload is the user-side check; no test pins it (recorded as a caveat).

---

### Task 1: C13 baseline and the devil re-rule record

**Files:**
- Modify: `wiki/runbooks/public-funnel.md` (new section "Baseline 2026-10-26 (before the beta pipeline)")
- Create: `docs/adr/0030-beta-release-pipeline.md`

**Interfaces:**
- Produces: the baseline text later tasks compare `make public-verify --pre` against; ADR 0030
  which Tasks 6, 7 and 12 cite for "beta's own Redis", "portal login for beta", "fail-closed
  provenance", "Phase 1/2 split".

- [ ] **Step 1: Record the baseline**

Run: `timeout 300 make public-verify PUBLIC_VERIFY_ARGS=--pre 2>&1 | tee /tmp/claude-1000/-home-dlesieur-Documents-groot/6aca345c-e7cf-4181-a2ce-ba7fa871acaa/scratchpad/c13-baseline.txt`
Expected: the `verify (pre): N pass, M fail, K skip` line with `FAIL node-name` and `FAIL nobridge`
(known red, runbook line 81). Paste the full output verbatim into the new runbook section with the
command and the date.

- [ ] **Step 2: Write ADR 0030** in the format of `docs/adr/0027-*.md` (Status accepted, Date
2026-10-26, Deciders: devil rev 1 BLOCK + conditions C1–C13, user decisions of 2026-10-26).
Sections: Context (the four facts: release bridge composed from 4 files, osionos public with 16
pushers and no `develop`, legacy login cannot return to a beta origin, ghcr anonymous 401),
Decision (Phase 1 beta only; beta Redis `redis-beta` not the release Redis; portal login for beta;
provenance fail-closed on `ci.yml` + `refs/heads/develop`; no cross-repo token, 15-min schedule;
Phase 2 = baas:8443 cut-over with its own verdict; **the Gate G0 conditions C14–C20 verbatim from
Global Constraints**), Consequences (15 min latency; a Sigstore outage freezes beta; the release
Pages URL is dark; the release bridge still carries the deploy tokens C15 strips from beta —
out of scope here, reported to the user).

- [ ] **Step 3: Gate G0 record** — the devil ruled rev 3 PROCEED-WITH-CONDITIONS on 2026-10-26
(C14–C20, already in Global Constraints and in the ADR from Step 2). Update the memory file
`beta-release-pipeline-verdict.md` with the re-rule, the date and C14–C20.

- [ ] **Step 4: Commit**

```bash
git add wiki/runbooks/public-funnel.md docs/adr/0030-beta-release-pipeline.md
git commit -m "docs(public): record the public-verify --pre baseline and ADR 0030 (beta/release pipeline)"
```

---

### Task 2: osionos repo — bridge Dockerfile copy, build meta, Pages routing files

**Files (in `apps/osionos/app`, repo Univers42/osionos, branch `feat/beta-release-pipeline` off `main`):**
- Create: `docker/services/bridge/Dockerfile` (byte-identical to groot's
  `infrastructure/docker/osionos/bridge.Dockerfile` except the header's build example)
- Create: `docker/services/bridge/Dockerfile.dockerignore` (copy of groot's `bridge.Dockerfile.dockerignore`)
- Modify: `index.html:5` — add `<meta name="osionos-build" content="%VITE_APP_VERSION%" />` after the viewport meta
- Create: `public/_redirects` with the single line `/* /index.html 200`
- Create: `public/_headers`

**Interfaces:**
- Produces: `docker/services/bridge/Dockerfile` (context = repo root, `COPY scripts/bridge-*.mjs scripts/ide-*.mjs ./scripts/`, `EXPOSE 4000`, healthcheck on `/api/auth/bridge/health`) used by Task 3's job and Task 11's repoint; the meta name `osionos-build` read by Task 5's `pages-wait.sh`.

- [ ] **Step 1: Copy the Dockerfile and its dockerignore; prove parity**

Run: `diff <(sed '1,12d' ../../../infrastructure/docker/osionos/bridge.Dockerfile) <(sed '1,12d' docker/services/bridge/Dockerfile) && diff ../../../infrastructure/docker/osionos/bridge.Dockerfile.dockerignore docker/services/bridge/Dockerfile.dockerignore`
Expected: no output, exit 0 (only the 12 header lines differ: the osionos header says
`docker build -f docker/services/bridge/Dockerfile -t osionos-bridge:local .`).

- [ ] **Step 2: Build it the way CI will**

Run: `timeout 600 docker build -f docker/services/bridge/Dockerfile -t osionos-bridge:plan-check . && docker run --rm --entrypoint sh osionos-bridge:plan-check -c 'ls /app/scripts | wc -l; ls /app'`
Expected: build ok; the second line lists `scripts` only (no `node_modules`, no `.git`), the count
equals `ls scripts/bridge-*.mjs scripts/ide-*.mjs | wc -l` run in the repo.

- [ ] **Step 3: Write `public/_headers`** — copy the five headers of `vercel.json` (HSTS,
`X-Content-Type-Options`, `X-Frame-Options: DENY`, `Referrer-Policy`, `Permissions-Policy`) under
`/*`, plus `Content-Security-Policy: frame-ancestors 'none'` (the public nginx's value,
`infrastructure/tls/nginx.conf`, the app server block).

- [ ] **Step 4: Verify the meta is replaced at build time**

Run: `VITE_APP_VERSION=plan-sha pnpm exec vite build >/dev/null && grep -o '<meta name="osionos-build" content="[^"]*"' build/index.html && ls build/_redirects build/_headers`
Expected: `content="plan-sha"`; both files listed.

- [ ] **Step 5: Run the repo's own gate for what changed**

Run: `pnpm run lint && pnpm run typecheck` (the `quality` job's scripts; read `package.json` for the exact names) — Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add docker/services/bridge index.html public/_redirects public/_headers
git commit -m "feat(deploy): bridge Dockerfile in-repo, build meta tag, Pages routing and headers"
```

---

### Task 3: osionos CI — attested bridge image, write permissions only on the push job (C17)

**Files:**
- Modify: `.github/workflows/ci.yml:21-24` (top-level `permissions` → `contents: read` only), `:39-82` (`build-image` gets job-level `permissions: {contents: read, packages: write}`), two new jobs `build-bridge-image` and `push-bridge-image` after it.

**Interfaces:**
- Produces: `ghcr.io/univers42/osionos-bridge:develop`, `:main`, `:sha-<sha>` with a Sigstore
  attestation whose certificate identity is
  `https://github.com/Univers42/osionos/.github/workflows/ci.yml@refs/heads/<pushed branch>` (C14)
  and whose predicate `buildDefinition.externalParameters.workflow.ref` is the same ref. Task 7
  verifies the certificate first, the predicate second.

- [ ] **Step 1: Write the two jobs** (C17; same step shape as `build-image`):

```yaml
  build-bridge-image:
    name: Build bridge image
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - checkout (no submodules needed)
      - ./.github/actions/docker-hub-access (as build-image)
      - docker/build-push-action@v6: file docker/services/bridge/Dockerfile; push: false; provenance: false; sbom: false
  push-bridge-image:
    name: Push & attest bridge image
    needs: build-bridge-image
    if: github.event_name == 'push' && (github.ref == 'refs/heads/main' || github.ref == 'refs/heads/develop')
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
    env:
      BRIDGE_IMAGE: ghcr.io/${{ github.repository_owner }}/osionos-bridge
    steps:
      - checkout; docker-hub-access; docker/login-action@v4 (ghcr)
      - docker/metadata-action@v5: images BRIDGE_IMAGE; tags `type=sha,prefix=sha-` and `type=ref,event=branch`
      - docker/build-push-action@v6 id: build; file docker/services/bridge/Dockerfile; push: true; provenance: false; sbom: false
      - actions/attest-build-provenance@<pinned>: subject-name BRIDGE_IMAGE; subject-digest ${{ steps.build.outputs.digest }}; push-to-registry: true
```

`provenance: false` on buildx: the attestation step is the single signer (C2 verifies one
predicate type). The build-only job runs on every branch so a feature PR still proves the
Dockerfile builds; no write permission exists on a branch run. Check: `yq '.jobs[] | select(.permissions.packages == "write") | .name' .github/workflows/ci.yml` lists only `build-image` and `push-bridge-image`.

- [ ] **Step 2: Lint the workflow**

Run: `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.7 -color`
Expected: no findings.

- [ ] **Step 3: Push the branch and watch** — `git push -u origin feat/beta-release-pipeline`;
`gh run watch --repo Univers42/osionos --exit-status $(gh run list --repo Univers42/osionos --branch feat/beta-release-pipeline --limit 1 --json databaseId --jq '.[0].databaseId')`
Expected: `build-bridge-image` green with the push/login/attest steps skipped; `build-image`
still green (its push is main-only). If `quality` or `test-gate` fail on this branch for a
pre-existing reason, record the run id and the failing step here before proceeding — the Task 12
landing has to be green on the merged commit, so a stale check is repaired there.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci(bridge): build and attest ghcr.io/univers42/osionos-bridge; packages:write only on the push jobs"
```

---

### Task 4: osionos `develop` branch, ruleset, package visibility (C3)

**Files:** none in git; GitHub state.

**Interfaces:**
- Produces: `refs/heads/develop` on Univers42/osionos protected like `main`; package
  `osionos-bridge` pullable anonymously (Task 7 pulls with no login).

- [ ] **Step 1: Create the `develop` ruleset first, stricter than main's (C18)**

Run: `gh api repos/Univers42/osionos/rulesets --jq '.[] | select(.name=="main") | .id'` then
`gh api repos/Univers42/osionos/rulesets/<id> > scratch/ruleset-main.json`; edit the copy: `name: develop`,
`conditions.ref_name.include: ["refs/heads/develop"]`, in the `pull_request` rule set
`require_last_push_approval: true` and `dismiss_stale_reviews_on_push: true`, drop
`id`/`node_id`/`_links`/`created_at`/`updated_at`;
`gh api -X POST repos/Univers42/osionos/rulesets --input scratch/ruleset-develop.json`.
Expected: `gh api repos/Univers42/osionos/rules/branches/develop --jq 'map(.type)'` equals the same
command's output for `main`, and `… --jq '.[] | select(.type=="pull_request") | .parameters | [.require_last_push_approval, .dismiss_stale_reviews_on_push]'` prints `[true, true]` (the branch does not exist yet; the rules endpoint evaluates the ref name).

- [ ] **Step 2: Create `develop` from `main`** (after Task 12 merges this work into osionos `main`
the branch is fast-forwarded; creating it now lets the first attested `:develop` image exist):
`git push origin main:refs/heads/develop`. Expected: `gh api repos/Univers42/osionos/branches/develop --jq .name` prints `develop`.

- [ ] **Step 3: Package visibility** — after the first push to `develop` creates the package: the
user sets it to **Public** in the package settings page (no REST endpoint changes container
visibility). Verify anonymously:
`DOCKER_CONFIG=$(mktemp -d) timeout 60 docker manifest inspect ghcr.io/univers42/osionos-bridge:develop >/dev/null && echo public`
Expected: `public`. Until then the host's existing ghcr login in `~/.docker/config.json` serves
the timer's pulls, and the runbook says so.

- [ ] **Step 4: Image contents check** (design §2 "verify the image carries nothing but the repo's scripts"):
`docker run --rm --entrypoint sh ghcr.io/univers42/osionos-bridge:develop -c 'find /app -type f | sed "s#/app/##" | sort | head -200; find /app -type f | wc -l'`
Expected: only `scripts/bridge-*.mjs` and `scripts/ide-*.mjs`; the count equals the repo's glob count at that sha. Record the count in the runbook.

---

### Task 5: groot — Pages deploy workflow for the osionos app, with the head and meta scripts

**Files:**
- Create: `scripts/pages-head.sh`
- Create: `scripts/pages-wait.sh`
- Create: `scripts/tests/pages-head.bats`, `scripts/tests/pages-wait.bats`
- Create: `.github/workflows/osionos-pages.yml`

**Interfaces:**
- Produces: `pages-head.sh <branch> <deployed-url> <meta-name>` → prints `sha=<40 hex>` and
  `deploy=true|false` and `reason=<word>` on three lines, exit 0; exit 2 on an API error.
  `pages-wait.sh <url> <meta-name> <sha> [timeout-seconds=900]` → exit 0 when the page's meta
  equals the sha, 1 on timeout, 3 when the meta is a literal `%...%`.
- Consumes: osionos check-run names `quality (root)`, `quality (markengine-submodule)`,
  `Browser tests` (Task 3's workflow); the meta name `osionos-build` (Task 2).

- [ ] **Step 1: Write `scripts/tests/pages-head.bats`** with stubs on PATH for `git` (answers
`ls-remote` from `$T/head`), `gh` (answers `api .../check-runs` from `$T/checks.json`) and `curl`
(answers from `$T/page.html`):

```bash
@test "deploys when the head is green and the deployed meta differs" {
  echo "aaaa… refs/heads/develop" >"$T/head"; green_checks; deployed_meta "bbbb…"
  run "$SCRIPT" develop https://develop.osionos.pages.dev osionos-build
  [ "$status" -eq 0 ]; has "deploy=true"; has "sha=aaaa…"
}
@test "skips when the deployed meta already equals the head" { …; has "deploy=false"; has "reason=current"; }
@test "refuses a head whose Browser tests check-run is missing" { …; has "deploy=false"; has "reason=gate-missing"; }
@test "refuses a head with a failed quality (root) check-run" { …; has "reason=gate-red"; }
@test "exits 2 when ls-remote fails" { …; [ "$status" -eq 2 ]; }
```

- [ ] **Step 2: Run it to see it fail** — `docker run --rm -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 -c 'apk add -q --no-cache coreutils jq && bats scripts/tests/pages-head.bats'` — Expected: every test fails on "no such file".

- [ ] **Step 3: Write `scripts/pages-head.sh`**: `git ls-remote https://github.com/Univers42/osionos refs/heads/<branch>` (C1, never an input), `gh api repos/Univers42/osionos/commits/<sha>/check-runs --paginate --jq '.check_runs[] | [.name, .conclusion] | @tsv'`, require the three names above each `success`, `curl -fsS -H 'Cache-Control: no-cache' <url>` and read the meta with `grep -o`. Header `Caveat:` lines: a check-run renamed in osionos CI reads as `gate-missing` (fails closed); the meta compare sees only the CDN edge curl reached.

- [ ] **Step 4: Run the bats file — Expected: PASS.** Then `shellcheck -S style scripts/pages-head.sh` — Expected: clean.

- [ ] **Step 5: Write `scripts/tests/pages-wait.bats`** (stub `curl` returns `$T/page.html`, stub `sleep` records calls):

```bash
@test "returns 0 as soon as the meta equals the sha" { … }
@test "returns 1 after the timeout with the last meta in the message" { … [ "$status" -eq 1 ]; has "last meta: bbbb…"; }
@test "returns 3 at once on a literal %VITE_APP_VERSION% meta" { … [ "$status" -eq 3 ]; }
```

- [ ] **Step 6: Run to fail, write `scripts/pages-wait.sh`** (poll every 20 s, `Cache-Control: no-cache`, `Caveat:` on the CDN edge and the service worker), run to pass, shellcheck clean.

- [ ] **Step 7: Write `.github/workflows/osionos-pages.yml`**:

```yaml
name: osionos app on Cloudflare Pages
on:
  push: { branches: [develop, main], paths: [".github/workflows/osionos-pages.yml", "scripts/pages-*.sh", "infrastructure/docker/osionos/app.Dockerfile", "infrastructure/docker/osionos/app.Dockerfile.dockerignore", "apps/graph_render"] }
  schedule: [{ cron: "*/15 * * * *" }]
  workflow_dispatch:
permissions: { contents: read }
jobs:
  plan:    # outputs targets: schedule or main push → ["develop","main"]; develop push → ["develop"]
  deploy:
    needs: plan
    strategy: { fail-fast: false, matrix: { target: ${{ fromJSON(needs.plan.outputs.targets) }} } }
    concurrency: { group: pages-osionos-${{ matrix.target }}, cancel-in-progress: false }
    timeout-minutes: 45
    env:
      PROJECT: osionos
      URL: ${{ matrix.target == 'develop' && 'https://develop.osionos.pages.dev' || 'https://osionos.pages.dev' }}
      API_URL: ${{ matrix.target == 'develop' && 'https://osionos-apps-1.tail10f2ea.ts.net:10000' || 'https://baas.tail10f2ea.ts.net:10000' }}
      AUTH_MODE: ${{ matrix.target == 'develop' && 'portal' || '' }}
      MAIL_URL: …-mail.pages.dev per target; CALENDAR_URL likewise
    steps:
      - checkout groot (actions/checkout@v7)
      - head: bash scripts/pages-head.sh "$TARGET" "$URL" osionos-build → GITHUB_OUTPUT; stop early when deploy=false
      - require secrets: `[ -n "$CLOUDFLARE_API_TOKEN" ] || { echo "::error::CLOUDFLARE_API_TOKEN is unset in groot"; exit 1; }` (same for ACCOUNT_ID)
      - osionos checkout at the head sha: git clone https://github.com/Univers42/osionos, `git checkout <sha>`, `git submodule update --init --recursive` (insteadOf as graph-studio.yml)
      - mirror.gcr.io base images (copy of graph-studio.yml's step)
      - GRAPH_RENDER_SHA from `git ls-tree HEAD apps/graph_render` (as graph-studio.yml)
      - docker build --target runtime -f infrastructure/docker/osionos/app.Dockerfile with the Global Constraints' args, `VITE_APP_VERSION=<sha>`, `GRAPH_RENDER_SHA`, `-t osionos-pages:<target>` (context = the osionos clone; retry loop copied from graph-studio.yml)
      - extract: `docker create` + `docker cp <ctr>:/usr/share/nginx/html ./site`
      - bundle checks: `grep -q "name=\"osionos-build\" content=\"$SHA\"" site/index.html`; `find site -type f | wc -l` ≤ 20000; `find site -type f -size +25M` empty; `test -f site/_redirects`
      - cloudflare/wrangler-action@<pinned> (apiToken, accountId, wranglerVersion pinned) command: `pages project create osionos --production-branch main || true` — Caveat: "already exists" is swallowed by `|| true`; a permission error is caught by the deploy that follows
      - cloudflare/wrangler-action: `pages deploy ./site --project-name osionos --branch <target> --commit-hash <sha> --commit-dirty=false`
      - bash scripts/pages-wait.sh "$URL" osionos-build "$SHA" 900
      - summary: `echo "deployed <sha> to $URL" >> "$GITHUB_STEP_SUMMARY"`; for main add the line `release Pages is DARK until Phase 2 (ADR 0030): the release bridge allows only baas:8443`
```

- [ ] **Step 8: Lint** — `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.7 -color` — Expected: clean. Run the whole groot bats suite as fresh-machine does (`fresh-machine.yml:93-97` command) — Expected: all pass (the two new files included).

- [ ] **Step 9: User action (blocking for the live check only):** `gh secret set CLOUDFLARE_API_TOKEN -R Univers42/groot` and `CLOUDFLARE_ACCOUNT_ID` (token scope: Account → Cloudflare Pages: Edit). Record "set" in the runbook, never the value.

- [ ] **Step 10: Commit**

```bash
git add scripts/pages-head.sh scripts/pages-wait.sh scripts/tests/pages-head.bats scripts/tests/pages-wait.bats .github/workflows/osionos-pages.yml
git commit -m "ci(pages): deploy the osionos app bundle to Cloudflare Pages per branch head, verified by build meta"
```

---

### Task 6: groot — the beta stack (`docker-compose.beta.yml`, `nginx-beta`, `make beta-up`)

**Files:**
- Create: `docker-compose.beta.yml` (standalone, project `track-binocle-beta`; my call: standalone rather than an overlay so the project holds exactly three services and the `config_files` label lists one file)
- Create: `infrastructure/tls/beta/nginx.conf`
- Create: `.env.beta.example`; `.gitignore` gains `.env.beta` (keep `!.env.beta.example`)
- Create: `utils/mk/beta.mk`
- Create: `scripts/tests/beta-compose-shape.sh`

**Interfaces:**
- Produces: services `osionos-bridge-beta`, `nginx-beta`, `redis-beta`; the host port
  `127.0.0.1:4001`; make targets `beta-up`, `beta-down`, `beta-check`; the lock path
  `${XDG_RUNTIME_DIR}/osionos-release.lock` (variable `RELEASE_LOCK`), which Task 7 shares.
- Consumes: `OSIONOS_BRIDGE_BETA_IMAGE` (default `ghcr.io/univers42/osionos-bridge:develop`),
  `.env.local` / `.env.public` / `.env.beta` **as compose `--env-file` for interpolation only** —
  the service has no `env_file:` (C15); Task 7's `release-pull.sh beta --once` (C16).

- [ ] **Step 1: Write `scripts/tests/beta-compose-shape.sh`** (bash, like `scripts/tests/ide-compose-shape.sh`, asserting on `docker compose -f docker-compose.beta.yml --env-file .env.beta.example config --format json | jq`):

- exactly the three services; `osionos-bridge-beta` has no `ports`; `nginx-beta.ports` is exactly `127.0.0.1:4001->4000/tcp`; `redis-beta` has no `ports`
- the only network is the external `mini-baas` (`name: mini-baas_mini-baas`), on every service (C4)
- `osionos-bridge-beta.environment` has `OSIONOS_BRIDGE_REDIS_URL=redis://redis-beta:6379`, `OSIONOS_BRIDGE_CLIENT_IP_HEADER=x-real-ip`, `OSIONOS_APP_URL` and `OSIONOS_ALLOWED_ORIGIN` = `https://develop.osionos.pages.dev`, `OSIONOS_AGENT_CLAUDE=""`, `OSIONOS_IDE_TOKEN_SECRET=""`, `OSIONOS_IDE_ACCESS=""`, `OSIONOS_RUNNER_URL=""`, `OSIONOS_SQL_RO=""`, `OSIONOS_MODERATION_ACTIONS=log`, `OSIONOS_BAAS_URL=http://mini-baas-kong:8000`, `AUTH_GATEWAY_URL=http://auth-gateway:8787` (C6; the same block as `docker-compose.public.yml:78-96` + the worktree overlay's keys `OSIONOS_MFA_SECRET_KEY`, `OSIONOS_RECOVERY_PEPPER`, `OSIONOS_EMAIL_SEAL_KEY`, `OSIONOS_EMAIL_SEAL_KEY_PREVIOUS`, `OSIONOS_EMAIL_LOOKUP_KEY` from `.env.local`)
- C15: `osionos-bridge-beta` has no `env_file` and no `volumes`; its `environment` keys are exactly the allowlist (the explicit block above + `rg -o 'process\.env\.[A-Z_0-9]+' apps/osionos/app/scripts/bridge-*.mjs | sort -u` names, written `KEY: ${KEY}`); none of `GITHUB_PAT FLY_API_TOKEN DOCKER_PAT DOCKER_PAS DOCKER_USER DOCKER_USERNAME SONAR_TOK EMAIL_RECUP_ADMIN_VAULT` is a key of the rendered `environment`
- `osionos-bridge-beta.image` defaults to `ghcr.io/univers42/osionos-bridge:develop`; `mem_limit` 128m; `restart: unless-stopped`
- `nginx -t` passes on `infrastructure/tls/beta/nginx.conf` with the two includes: `docker run --rm -v …/beta/nginx.conf:/etc/nginx/nginx.conf:ro -v …/public.d/bridge-public.conf:/etc/nginx/track-binocle.d/bridge-public.conf:ro -v …/http-limits.conf:… public.ecr.aws/docker/library/nginx:1.27-alpine nginx -t`

Run it — Expected: fails on the missing compose file.

- [ ] **Step 2: Write `docker-compose.beta.yml`** per the assertions; `redis-beta` uses the same image reference as `docker-compose.yml`'s existing redis service and no volume (a restart drops in-flight handoffs: `Caveat:` in the file). `nginx-beta` mounts `beta/nginx.conf`, `bridge-public.conf`, `http-limits.conf` read-only, `read_only: true` + tmpfs like `x-static-preview`, healthcheck `wget -q -O /dev/null http://127.0.0.1:4000/api/auth/bridge/health`. Bridge healthcheck as `docker-compose.yml`'s.

- [ ] **Step 3: Write `infrastructure/tls/beta/nginx.conf`**: one `http` block, `server { listen 4000; }` (plain HTTP: the Funnel terminates TLS), `set $track_binocle_upstream osionos-bridge-beta:4000;`, the `proxy_set_header` lines of `infrastructure/tls/nginx.conf:50-57` (`X-Real-IP $remote_addr` is what C5 asserts), `include /etc/nginx/track-binocle.d/bridge-*.conf;` before `location / { proxy_pass http://$track_binocle_upstream; }`, `include …/http-limits.conf` at http level, `resolver 127.0.0.11 valid=10s;`, no `/api/ai/` location (no AI service in beta: answers 404 via the bridge). Header comment: why plain HTTP and why `X-Real-IP` is tailscaled's loopback address for every visitor (same as release, `http-limits.conf` caveat).

- [ ] **Step 4: Write `utils/mk/beta.mk`** (`##@ Beta (Pages + pulled bridge)` section with `##` help lines so `make-help.bats`' repo contract passes):

```make
RELEASE_LOCK ?= $(XDG_RUNTIME_DIR)/osionos-release.lock
BETA_COMPOSE = docker compose -p track-binocle-beta -f docker-compose.beta.yml --env-file ./.env.local --env-file ./.env.public --env-file ./.env.beta
beta-check: ## Shape test of the beta stack (compose + nginx -t), no containers
beta-up: beta-check ## Verify the beta bridge attestation, then (re)create the three beta services by digest, wait healthy
	bash scripts/release-pull.sh beta --once
beta-down: ## Stop the beta stack (the Funnel port stays mapped; public-funnel.sh down closes it)
```

C16: `beta-up` never pulls by tag; `release-pull.sh --once` (Task 7) resolves the tag in
`.env.beta`, verifies the certificate, then runs `up` for the whole project with the image pinned
`repo@sha256:`. It takes `RELEASE_LOCK` itself. Until Task 7 lands the target fails on the missing
script (fail closed).

`.env.beta.example`: `OSIONOS_BRIDGE_BETA_IMAGE=ghcr.io/univers42/osionos-bridge:develop`, `BETA_APP_ORIGIN=https://develop.osionos.pages.dev`, each with a comment.

- [ ] **Step 5: Run `bash scripts/tests/beta-compose-shape.sh`** — Expected: every assertion PASS, exit 0. Wire the script into `beta-check` and into `fresh-machine.yml`'s `clone-and-make-all` job (the docker-capable one) as a step after `make all`.

- [ ] **Step 6: C4 measurement, pre-change** — `docker run --rm --network mini-baas_mini-baas public.ecr.aws/docker/library/alpine:3.20 nslookup osionos-bridge | grep -c "Address"` — record the number (expected 1 + the server line) in the runbook; the same command after `make beta-up` in Task 12 must print the same.

- [ ] **Step 7: Commit**

```bash
git add docker-compose.beta.yml infrastructure/tls/beta/nginx.conf .env.beta.example .gitignore utils/mk/beta.mk scripts/tests/beta-compose-shape.sh .github/workflows/fresh-machine.yml
git commit -m "feat(beta): beta bridge stack behind nginx on 127.0.0.1:4001, on the mini-baas network only"
```

---

### Task 7: groot — `scripts/release-pull.sh`, its timer and its tests (C2, C8)

**Files:**
- Create: `scripts/release-pull.sh`
- Create: `scripts/tests/release-pull.bats`
- Create: `infrastructure/systemd/user/osionos-release-pull.service.in`, `osionos-release-pull.timer.in`
- Modify: `utils/mk/beta.mk` (targets `release-autostart`, `release-autostart-off`, `release-pull-once`)
- Create: `scripts/release-pull-autostart.sh` (render + enable, the `grobase-link-autostart.sh:23-45` pattern)

**Interfaces:**
- Produces: `release-pull.sh <beta|release> [--once] [--dry-run]`; exit 0 unchanged/updated,
  75 when the lock is held, 2 on refusal (attestation, ref, >1 container, missing label), 1 on a
  failed recreate (after rollback). State dir `${XDG_STATE_HOME:-$HOME/.local/state}/osionos-release-pull/`
  with `<target>.verified-digests` (one `repo@sha256:…` per verified digest, C16),
  `<target>.previous-digest` (the last `repo@sha256:` that ran, C19) and `<target>.log`.
  `--once` (used by `make beta-up`) ups the whole project (all three services); the timer mode
  recreates `osionos-bridge-beta` only.
- Consumes: Task 6's service names, lock path and compose file; Task 3's attestation; `gh ≥ 2.49`
  on the host (installed in Task 12 from GitHub's apt repo).

- [ ] **Step 1: Write `scripts/tests/release-pull.bats`** with stubs for `docker` (image digest
from `$T/remote-digest`, running container digest from `$T/running-digest`, `ps` count from
`$T/containers`, `inspect` label from `$T/config-files`, `compose up` recorded to `$T/docker.log`,
health from `$T/health`), `gh` (`attestation verify` exit from `$T/attest-rc`, `--format json`
body from `$T/predicate.json`), `flock`, `curl`, `timeout` (pass-through):

```bash
@test "unchanged: remote digest equals the running one, nothing is recreated" { … has "unchanged"; [ ! -s "$T/docker.log" ]; }
@test "updates: verified digest recreated by digest with the labelled compose files, health probed" {
  … has "up -d --no-build --wait --wait-timeout 120 osionos-bridge-beta"; has "@sha256:"; has "-f /repo/docker-compose.beta.yml"; }
@test "refuses when gh attestation verify fails and logs why" { echo 1 >"$T/attest-rc"; … [ "$status" -eq 2 ]; has "attestation"; [ ! -s "$T/docker.log" ]; }
@test "verifies with the certificate identity of refs/heads/develop and --deny-self-hosted-runners" { … has "--cert-identity https://github.com/Univers42/osionos/.github/workflows/ci.yml@refs/heads/develop"; has "--deny-self-hosted-runners"; }
@test "refuses a certificate whose ref is not refs/heads/develop even when the predicate says so" { cert refs/heads/feat/x; predicate ref refs/heads/develop; … [ "$status" -eq 2 ]; has "attestation"; [ ! -s "$T/docker.log" ]; }
@test "refuses a predicate whose workflow ref is not refs/heads/develop (second check)" { ref refs/heads/feat/x; … [ "$status" -eq 2 ]; has "refs/heads/feat/x"; }
@test "unchanged only when the running digest is in the verified-state file; otherwise verify first" { running == remote, empty state → gh called, state gains the digest; state has it → gh not called; }
@test "--once ups the whole project by digest (no service name) and runs with zero containers" { echo 0 >"$T/containers"; … has "up -d --no-build --wait --wait-timeout 120"; ! has "osionos-bridge-beta$"; has "@sha256:"; }
@test "a tag in .env.beta is resolved and verified; a reference already pinned @sha256 is verified, never trusted" { … }
@test "refuses when the service has more than one container" { echo 2 >"$T/containers"; … [ "$status" -eq 2 ]; has "containers"; }
@test "refuses when the config_files label is empty" { … [ "$status" -eq 2 ]; has "config_files"; }
@test "rolls back to the previous verified repo@sha256 digest when health fails after up, exit 1" { … has "rollback"; rollback line has "@sha256:"; ! has "rollback sha256:"-bare image id; [ "$status" -eq 1 ]; }
@test "holds the lock: a second runner exits 75 with \"locked\"" { … [ "$status" -eq 75 ]; }
@test "release target is refused in Phase 1 naming ADR 0030" { run … release; [ "$status" -eq 2 ]; has "ADR 0030"; }
@test "--dry-run prints the plan and runs no docker compose" { … }
@test "the sigstore outage case (gh exit 1 with 'TUF') is a refusal, not a retry" { … }
```

- [ ] **Step 2: Run it** (bats container as in Task 5) — Expected: all fail, script missing.

- [ ] **Step 3: Write `scripts/release-pull.sh`**, functions in this order, each under `timeout 60` (pull: `timeout 300`):

- `remote_digest()`: `docker buildx imagetools inspect "$image" --format '{{.Manifest.Digest}}'`
- `running_digest()`: `docker ps -q -f label=com.docker.compose.project=track-binocle-beta -f label=com.docker.compose.service=osionos-bridge-beta` → refuse if count ≠ 1 → `docker image inspect --format '{{join .RepoDigests ","}}'` of its `.Image`
- `verify_attestation()` (C14): `gh attestation verify "oci://$image@$digest" --repo Univers42/osionos --cert-identity "https://github.com/Univers42/osionos/.github/workflows/ci.yml@refs/heads/$branch" --deny-self-hosted-runners --format json` → gh itself refuses a certificate at another ref; then the second check `jq -r '.[0].verificationResult.statement.predicate.buildDefinition.externalParameters.workflow.ref'` must equal `refs/heads/$branch` (the builder confirms the path on a real predicate in Task 12 and pastes `…signature.certificate.sourceRepositoryRef` into the runbook). On success append `$image@$digest` to `<target>.verified-digests`.
- `compose_files()`: `docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}'` → `-f` per entry, refuse when empty; with zero containers (`--once` first run) use `$GROOT/docker-compose.beta.yml`
- `recreate()`: write the running `repo@sha256:` to `<target>.previous-digest` (C19); `OSIONOS_BRIDGE_BETA_IMAGE=$image@$digest docker compose -p track-binocle-beta <files> --env-file ./.env.local --env-file ./.env.public --env-file ./.env.beta up -d --no-build --wait --wait-timeout 120 [osionos-bridge-beta]` (service name omitted under `--once`); confirm `running_digest` = `$digest`; `curl -fsS http://127.0.0.1:4001/api/auth/bridge/health`
- `rollback()`: same `up` with `OSIONOS_BRIDGE_BETA_IMAGE=<previous repo@sha256:>` (a pruned image re-pulls); exit 1
- `main`: target arg; `release` → exit 2 "disabled until Phase 2 (ADR 0030)"; `flock -n "$RELEASE_LOCK"` (exit 75); image reference = `OSIONOS_BRIDGE_BETA_IMAGE` from `.env.beta` (default `ghcr.io/univers42/osionos-bridge:develop`), any `@sha256:` suffix stripped before `remote_digest`; C16: "unchanged" only if `running_digest` is listed in `<target>.verified-digests`, else `verify_attestation` first; log one line per tick to `<target>.log` and stdout.
- Header `Caveat:` lines: a tag moved and moved back between ticks is one change; a Sigstore outage stops updates (fail closed); the health probe is one GET, not a login.

- [ ] **Step 4: Run bats — Expected: PASS. `shellcheck -S style scripts/release-pull.sh scripts/release-pull-autostart.sh` — clean.**

- [ ] **Step 5: Units and make targets**: `osionos-release-pull.timer.in` (`OnBootSec=3min`, `OnUnitActiveSec=2min`, as `grobase-link-heal.timer.in`); `.service.in` `Type=oneshot`, `ExecStart=/usr/bin/bash @GROOT@/scripts/release-pull.sh beta`, `WorkingDirectory=@GROOT@`; `release-pull-autostart.sh install|remove` renders with `sed s|@GROOT@|…|` and `systemctl --user enable --now osionos-release-pull.timer`; make targets `release-autostart`, `release-autostart-off`, `release-pull-once` (`bash scripts/release-pull.sh beta --once`). Add the autostart script's bats (two tests: rendered unit names the groot path; remove disables the timer) under `scripts/tests/release-pull-autostart.bats` following `scripts/tests/grobase-link-autostart/`.

- [ ] **Step 6: Commit**

```bash
git add scripts/release-pull.sh scripts/release-pull-autostart.sh scripts/tests/release-pull.bats scripts/tests/release-pull-autostart.bats infrastructure/systemd/user/osionos-release-pull.* utils/mk/beta.mk
git commit -m "feat(beta): pull the beta bridge by attested digest every 2 min, roll back on a failed recreate"
```

---

### Task 8: groot — Funnel port 10000 on the apps node, verify, `public-node.sh status` fix (C11)

**Files:**
- Modify: `scripts/lib/public-tailnet.sh:13` (add `BETA_FUNNEL_MAP="10000:4001"`), `:20` (`tsa()` binary default)
- Modify: `scripts/public-funnel.sh` (`up beta`, `down beta`, usage text), `scripts/lib/public-verify-apps.sh` (`check_apps` exposure accepts the beta port)
- Modify: `scripts/public-node.sh:45,188,191`, `cmd_status`
- Modify: `scripts/tests/public-funnel.bats`, `scripts/tests/public-funnel-helpers.bash`
- Modify: `wiki/runbooks/public-funnel.md`, `utils/mk/public.mk` (`public-down` help text)

**Interfaces:**
- Produces: `public-funnel.sh up beta` → `tsa funnel --bg --https=10000 http://127.0.0.1:4001`;
  `public-funnel.sh down beta` → `tsa funnel --https=10000 off` (never reset); `verify` accepts apps
  ports `443,8443`, `443,8443,10000` and `10000`.

- [ ] **Step 1: Add the bats tests** to `public-funnel.bats` (stub `funnel --https=10000 off` in the helpers: remove the line from `$T/funnel-apps`):

```bash
@test "up beta opens exactly 10000 on the apps node onto plain http 4001" { run_pf up beta; [ "$status" -eq 0 ]; grep -qx '[apps] funnel --bg --https=10000 http://127.0.0.1:4001' "$T/ts.log"; [ "$(funnel_calls)" -eq 1 ]; }
@test "up beta refuses when the apps node is not running" { rm "$T/apps-node"; run_pf up beta; [ "$status" -ne 0 ]; [ "$(funnel_calls)" -eq 0 ]; }
@test "down beta turns 10000 off and never resets" { …; grep -qx '[apps] funnel --https=10000 off' "$T/ts.log"; ! grep -q 'funnel reset' "$T/ts.log" || false; }
@test "verify apps passes with 443,8443,10000 open on the apps node" { … }
@test "down (no scope) still resets both nodes and the runbook line says beta goes with it" { … }
```

Run — Expected: the new tests fail. Note: `has "verify (pre): 37 pass…"` changes only if a new
check is added to `pre`; the beta port check belongs to `check_apps` in full mode, so the 37 stays.

- [ ] **Step 2: Implement** in `public-funnel.sh` (`cmd_up` gains `beta`: requires `tsa status`
answering, no `verify --pre` dependency on `.env.beta`), `public-tailnet.sh` (`BETA_FUNNEL_MAP`),
`public-verify-apps.sh` (accepted port sets). Run bats — PASS; shellcheck clean.

- [ ] **Step 3: `public-node.sh status` fix** (measured 2026-10-26: `~/.local/bin/tailscale` does
not exist, the client is `/usr/bin/tailscale` 1.104.2, the daemon `/usr/sbin/tailscaled` 1.104.1;
`status --json` succeeds on stdout and prints `Warning: client version … != tailscaled server
version …` on stderr): default `TAILSCALE_BIN`/`TAILSCALED_BIN` to `command -v tailscale`/`tailscaled`
when the `~/.local/bin` path is absent (in `public-node.sh:45,188,191` and `public-tailnet.sh:20`),
and make `cmd_status` print the version warning line verbatim after the node line instead of
"not running". bats (`scripts/tests/public-node.bats` if present, else add two tests to
`public-funnel.bats` using the `tsa` stub): `status prints the DNS name when only /usr/bin/tailscale exists`; `status prints the version-skew warning`.

- [ ] **Step 4: Runbook** — new section "Beta bridge (Pages develop + port 10000)": the order
`make beta-up` → `bash scripts/public-funnel.sh up beta` →
`make release-autostart`; "`make public-down` and `reset_both` close the beta port too (reset on
the apps node)"; the dark-release note; the gh apt install line; the C13 baseline reference.

- [ ] **Step 5: Commit**

```bash
git add scripts/public-funnel.sh scripts/lib/public-tailnet.sh scripts/lib/public-verify-apps.sh scripts/public-node.sh scripts/tests/public-funnel.bats scripts/tests/public-funnel-helpers.bash wiki/runbooks/public-funnel.md utils/mk/public.mk
git commit -m "feat(public): Funnel scope beta (apps node 10000 -> nginx-beta), verify learns it, public-node status finds the system tailscale"
```

---

### Task 9: osionos-mail and osionos-calendar — meta, Pages files, deploy job

**Files (each repo, branch `feat/pages-deploy` off `main`):**
- Modify: `index.html:5` — `<meta name="osionos-mail-build" content="%VITE_APP_VERSION%" />` (calendar: `osionos-calendar-build`)
- Create: `public/_redirects` (`/* /index.html 200`), `public/_headers`
- Modify: `.github/workflows/ci.yml` — job `deploy-pages` after `typecheck-build`

**Interfaces:**
- Consumes: nothing from groot (the apps are self-contained; `VITE_MAIL_BRIDGE_URL=""` /
  `VITE_CALENDAR_BRIDGE_URL=""` + `VITE_CALENDAR_BAAS_URL=""` as the `:public` preview builds).
- Produces: `https://develop.osionos-mail.pages.dev`, `https://osionos-mail.pages.dev` (calendar alike).

- [ ] **Step 1: `public/_headers`**: the five `vercel.json` headers minus `X-Frame-Options` (the
app is framed), plus `Content-Security-Policy: frame-ancestors https://baas.tail10f2ea.ts.net:8443 https://develop.osionos.pages.dev https://osionos.pages.dev`.

- [ ] **Step 2: Verify locally** — `VITE_APP_VERSION=plan-sha npm run build && grep -o 'name="osionos-mail-build" content="[^"]*"' dist/index.html && ls dist/_redirects dist/_headers` — Expected: `content="plan-sha"`, both files.

- [ ] **Step 3: Job** (`needs: typecheck-build`, `if: github.event_name == 'push' && (ref develop || ref main)`, `concurrency: pages-<app>-<branch>` no cancel, `permissions: contents: read`): checkout, setup-node 22 + `npm ci`, `VITE_APP_VERSION=$GITHUB_SHA VITE_MAIL_BRIDGE_URL= npm run build`, `grep` the meta in `dist/index.html`, require the two secrets by name, wrangler-action `pages project create osionos-mail --production-branch main || true` then `pages deploy ./dist --project-name osionos-mail --branch <branch> --commit-hash $GITHUB_SHA --commit-dirty=false`, then an inline poll (15 min, 20 s, `Cache-Control: no-cache`, fail on a literal `%`) — the same logic as groot's `pages-wait.sh`, inlined because these repos have no scripts dir (`Caveat:` comment names that duplication and groot's script as the source).

- [ ] **Step 4: Lint** with actionlint (Task 3 Step 2 command). **User action:** `gh secret set CLOUDFLARE_API_TOKEN -R Univers42/osionos-mail` + `CLOUDFLARE_ACCOUNT_ID`, same for `osionos-calendar`.

- [ ] **Step 5: Commit** (each repo)

```bash
git add index.html public/_redirects public/_headers .github/workflows/ci.yml
git commit -m "ci(pages): deploy develop and main to Cloudflare Pages, verified by build meta"
```

---

### Task 10: groot — records owed and the make help

**Files:**
- Create: `.out-of-scope/groot-dispatch-pat.md`
- Modify: `docs/adr/0030-beta-release-pipeline.md` (any G0 conditions), `README`/wiki index that lists runbook sections if one exists (`rg -n "public-funnel.md" wiki docs README.md`)

- [ ] **Step 1: Write `.out-of-scope/groot-dispatch-pat.md`**: what was rejected (a Contents:write
PAT from osionos to groot), why (groot holds vault42 secrets; 16 pushers' feature runs could read
it), the fact that would change the answer (groot holding no long-lived secrets + protected
branches, or an Actions-only token in an osionos *environment* restricted to main/develop), and
the 15-min latency it would remove.

- [ ] **Step 2: `make help`** — run `bash tools/selfcheck.sh` if present and the make-help bats:
`docker run … bats scripts/tests/make-help.bats` — Expected: PASS (the `##@ Beta` section and
every new target carry `##` summaries).

- [ ] **Step 3: Commit**

```bash
git add .out-of-scope/groot-dispatch-pat.md docs/adr/0030-beta-release-pipeline.md
git commit -m "docs(beta): record the rejected dispatch token and its reversal condition"
```

---

### Task 11: groot — pin osionos, repoint the bridge Dockerfile, delete groot's copy (C12 stage 2)

**Files:**
- Modify: `apps/osionos/app` gitlink (to the osionos `main` that contains Task 2–3)
- Modify: `docker-compose.yml:74` → `dockerfile: docker/services/bridge/Dockerfile`
- Modify: `scripts/tests/bridge-image-closure.bats:18`, `scripts/tests/make-all-footprint.bats:41`, `scripts/tests/ide-compose-shape.sh:321`
- Modify: `/home/dlesieur/Documents/groot-wt/deploy/account-release-build.yml:19` (outside git; the live release overlay) — `dockerfile: /home/dlesieur/Documents/groot-wt/deploy/app/docker/services/bridge/Dockerfile`
- Delete: `infrastructure/docker/osionos/bridge.Dockerfile`, `bridge.Dockerfile.dockerignore`
- Run `bash scripts/pin-reach.sh` (memory: unpushed submodule pins) before pushing.

- [ ] **Step 1: Pin** — `git -C apps/osionos/app fetch origin && git -C apps/osionos/app checkout <main sha>`; `diff infrastructure/docker/osionos/bridge.Dockerfile apps/osionos/app/docker/services/bridge/Dockerfile` — Expected: only the header lines differ (Task 2 Step 1's parity).

- [ ] **Step 2: Repoint and delete**; `make-all-footprint.bats:41` lists the Dockerfiles whose base images are pulled: replace the groot path with `$REPO/apps/osionos/app/docker/services/bridge/Dockerfile`.

- [ ] **Step 3: Run the bats suite and the shape script** (fresh-machine command; `bash scripts/tests/ide-compose-shape.sh`) — Expected: all PASS, no SKIP line for the bridge closure. `docker compose --profile dev config | grep -A2 'osionos-bridge:' | grep dockerfile` prints the new path.

- [ ] **Step 4: Build the release image the live way, without deploying** — `docker compose --profile dev build osionos-bridge` — Expected: ok. Also `bash scripts/pin-reach.sh` — Expected: the pinned sha is on GitHub.

- [ ] **Step 5: Commit**

```bash
git add apps/osionos/app docker-compose.yml scripts/tests/bridge-image-closure.bats scripts/tests/make-all-footprint.bats scripts/tests/ide-compose-shape.sh
git rm infrastructure/docker/osionos/bridge.Dockerfile infrastructure/docker/osionos/bridge.Dockerfile.dockerignore
git commit -m "chore(osionos): pin <sha>; the bridge Dockerfile lives in the osionos repo now (C12 stage 2)"
```

---

### Task 12: Land, bring up, measure the done-when

**Files:** none new. Host state: `gh` upgrade, beta stack, Funnel port, timer, `.env.beta`.

- [ ] **Step 1: Land osionos first** (user's rule): `git checkout main && git merge --no-ff feat/beta-release-pipeline && git push origin main`; `gh run watch` to green; on red: real regression → fix; stale check → repair the check, say why in the commit. Expected: `push-bridge-image` pushed `:main` and `:sha-<M>` with an attestation. **C19 negative test, before develop moves:** after Step 4's gh upgrade (do Step 4 now if needed), `OSIONOS_BRIDGE_BETA_IMAGE=ghcr.io/univers42/osionos-bridge:sha-<M> bash scripts/release-pull.sh beta --once --dry-run` → exit 2, the log names the certificate ref `refs/heads/main` (only main attested that digest at this moment). Then `git push origin main:develop`; watch to green; Expected: `:develop` attested (`gh attestation verify oci://ghcr.io/univers42/osionos-bridge:develop --repo Univers42/osionos --cert-identity https://github.com/Univers42/osionos/.github/workflows/ci.yml@refs/heads/develop` from the runner's gh, printed in the job log). Paste the real `sourceRepositoryRef` field into the runbook (C14).

- [ ] **Step 2: Land mail and calendar** the same way; watch to green; `curl -s https://develop.osionos-mail.pages.dev | grep -o 'content="[0-9a-f]\{40\}"'` equals the develop head (same for main and for calendar).

- [ ] **Step 3: Land groot** — merge the feature branch into `develop`, push over ssh, watch every workflow green (fresh-machine, graph-studio, osionos-pages, supply-chain, …); repair a stale one against the new behaviour; then merge `develop` into `main`, push, watch. Expected after `osionos-pages.yml` runs: `https://develop.osionos.pages.dev` and `https://osionos.pages.dev` serve the osionos head metas; the main summary says DARK.

- [ ] **Step 4: Host `gh`** — `gh --version` (2.45.0 today); install from GitHub's apt repository per the runbook line (one apt change, user-visible in the runbook); Expected: `gh attestation --help` exits 0 and `gh attestation verify oci://ghcr.io/univers42/osionos-bridge:develop --repo Univers42/osionos` prints the predicate (TUF fetch returned 200 on 2026-10-26).

- [ ] **Step 5: Bring up beta** (only with C14, C15, C16, C18, C19 green in the ledger) — `cp .env.beta.example .env.beta && chmod 600 .env.beta`; `make beta-up` → `release-pull.sh beta --once` logs "verified … updated"; `docker compose -p track-binocle-beta ps` shows three healthy, the bridge image reference contains `@sha256:`; C15 live: `docker inspect track-binocle-beta-osionos-bridge-beta-1 --format '{{range .Config.Env}}{{println .}}{{end}}' | cut -d= -f1 | grep -cE '^(GITHUB_PAT|FLY_API_TOKEN|DOCKER_PAT|DOCKER_PAS|DOCKER_USER|DOCKER_USERNAME|SONAR_TOK|EMAIL_RECUP_ADMIN_VAULT)$'` → 0 (names only, never values); C4: the nslookup of Task 6 Step 6 prints the same count; `curl -fsS http://127.0.0.1:4001/api/auth/bridge/health` → 200.

- [ ] **Step 6: Funnel** — `bash scripts/public-funnel.sh up beta`; `curl -fsS https://osionos-apps-1.tail10f2ea.ts.net:10000/api/auth/bridge/health` → 200; `bash scripts/public-funnel.sh status` lists apps ports `443,8443,10000`.

- [ ] **Step 7: Timer** — `make release-pull-once` → "unchanged" (digest already running); `make release-autostart`; `systemctl --user list-timers | grep osionos-release-pull`; after the next osionos develop push: `journalctl --user -u osionos-release-pull -n 20` shows "updated <digest>" and the running container's RepoDigest equals the attested one.

- [ ] **Step 8: Measurements (done-when table), recorded in the runbook with commands and outputs:**
  - portal login on `https://develop.osionos.pages.dev` ends logged in on the same origin (browser-testing skill: screenshot before/after; the login screen's build line shows the sha)
  - `/realtime/v1/ws` handshake from that origin: `curl -i -H 'Origin: https://develop.osionos.pages.dev' -H 'Upgrade: websocket' -H 'Connection: Upgrade' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Version: 13' https://baas.tail10f2ea.ts.net:8443/realtime/v1/ws` → record the status (101 = works; 403 = Phase 2 gateway item, reported, not papered over)
  - C5: `curl -s -H 'X-Real-IP: 203.0.113.9' -H 'X-Forwarded-For: 203.0.113.9' https://osionos-apps-1.tail10f2ea.ts.net:10000/api/auth/bridge/health`, then the bridge's log line for that request shows a loopback/tailscaled address, not `203.0.113.9`
  - C14/C19: the Step 1 negative test's output (`:sha-<M>` attested to `refs/heads/main` → exit 2); the `:develop` tag is never moved by hand
  - release untouched: `docker ps -q -f name=track-binocle-osionos-bridge-1` before and after Step 1 is the same id
  - C13: `make public-verify PUBLIC_VERIFY_ARGS=--pre` output equals the Task 1 baseline except the `apps` exposure line

- [ ] **Step 9: Commit the runbook evidence and push** (develop → main as Step 3); update the memory file `beta-release-pipeline-verdict.md` with "Phase 1 live <date>" and the measured results (realtime status, C5 address, nslookup count).

---

## Self-review

- **Spec coverage:** §1 Pages (Tasks 2, 5, 9), portal/beta args (Global Constraints, Task 5 env), no Pages Function and `VITE_BAAS_URL` (Task 5 args), dark release (Task 5 summary, runbook Task 8), 15-min schedule + head check + no token (Task 5, `.out-of-scope` Task 10); §2 Dockerfile staged move (Tasks 2, 11), attested image + narrowed permissions (Task 3), branch + ruleset + package (Task 4), beta stack/env/network/nginx (Task 6), Funnel + verify + status fix (Task 8), pull timer with lock/label/digest/rollback/dry-run (Task 7), hand rollback (`.env.beta` `OSIONOS_BRIDGE_BETA_IMAGE=…:sha-<prev>` + `make beta-up`, Task 6); §3 Phase 2 deferred (release target refused, Task 7); Constraints (Global Constraints; C13 Task 1; ADR Task 1; landing Task 12); Done-when (Task 12 Step 8). Gap found and fixed: the `_headers` for the osionos app had no source — now copied from `vercel.json` + nginx (Task 2 Step 3).
- **Step scan:** every step names a file, a command and its expected output; the two "builder
  confirms" items (predicate jq path, wrangler project-create permission) are stated as a check
  with a fallback, not left open.
- **Type consistency:** `osionos-bridge-beta`, `nginx-beta`, `redis-beta`, `track-binocle-beta`,
  `RELEASE_LOCK`, `OSIONOS_BRIDGE_BETA_IMAGE`, meta names `osionos-build` / `osionos-mail-build` /
  `osionos-calendar-build`, exit codes 0/1/2/75/3 are used identically in Tasks 5–8 and 12.
- **Review Focus:** items 1–4 have their tests in Tasks 5 and 7; item 5 is a documented caveat.
- **Gate G0 (2026-10-26):** C14–C20 folded in: Global Constraints, Task 1 (ADR), Task 3 (C17 split), Task 4 (C18 order + parameters), Task 6 (C15 allowlist, C16 `beta-up`), Task 7 (C14 cert identity, C16 verified-state, C19 digest rollback + `--once`), Task 12 (C19 negative test on `:sha-<main>`, C15 live check).
- **Proportion:** 656 lines for a 364-line spec, 12 tasks across four repos plus host state; code blocks are assertions, signatures and
  workflow skeletons, not bodies.
