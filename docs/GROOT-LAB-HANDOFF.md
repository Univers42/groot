# Groot Lab handoff: spaces, granular access, live co-editing

How to use: open Claude Code in `/goinfre/dlesieur/groot` and paste everything below the rule, or run

    claude "$(sed 1,10d docs/GROOT-LAB-HANDOFF.md)"

It names no secret value. Written 2026-10-18 ~00:50 CEST by the session that did P0, P1 and the
explorer half of P3. The full design records it cites are on persistent NFS (below), not in git.

---

You are taking over a multi-phase feature in groot (the ft_transcendence orchestration monorepo).
This prompt is your brief. Every fact here was true at 2026-10-18 00:50 CEST. **Re-verify each one
with a command before you act on it.** Other sessions push to these repos concurrently.

## 0. Read first, in this order

1. `CLAUDE.md` (root), then `apps/grobase/CLAUDE.md` and `apps/osionos/app/CLAUDE.md`.
2. `.claude/rules/*`: risk, prompt-contract, run-safely, caveat, minimalism-*, quality-bar.
3. The records directory **`/sgoinfre/students/dlesieur/groot-collab/2026-10-17/`** (NFS, mode 700,
   survives a goinfre wipe):

   | File | What it is |
   |---|---|
   | `plan.md` | The approved plan, P0–P7. Its "Amendments after P0" section overrides the rest |
   | `devil-p1p2.md` | Devil round 1 on P1/P2: BLOCK, B1–B6, acceptance criteria C1–C20 |
   | `p1p2-amended.md` | The amended design that answers B1–B6 |
   | `devil-p1p2-r2.md` | Devil round 2: PROCEED-WITH-CONDITIONS, N1–N10. **Binding for P2** |
   | `p1-contract.md` | The P1 contract (schema, model grammar, routes, scopes, gate numbers) |
   | `devil-push.md` | Devil ruling on publishing: C1–C9. **Binding for §3 below** |
   | `HANDOFF.md` | The older, layered handoff (§1–§10). This prompt supersedes it |
   | `r2/`, `spike-*/RESULTS.md` | Measurement scripts and the P0 spike results |
   | `*.log` | Gate and test evidence |
   | `tools/` | `gh.sh`, `ci-wait.sh`, `probe/run.sh` + specs, compose overrides (see §6) |

4. Memory index: `/home/dlesieur/.claude/projects/-goinfre-dlesieur-groot/memory/MEMORY.md`.
   Especially `groot-lab-collab-status`, `local-grobase-on-host`, `concurrent-sessions-share-checkout`,
   `opus-orchestrates-sonnet-builds`, `prod-actions-are-human-run`, `home-is-a-4g-quota`.

## 1. Mission

A file made in the IDE sandbox showed "Not a page yet". The user wants Notion-style spaces:

> "the filesystem should understand that we have a shared space and private space.. as notion do
> … a system like github of team organization workspace, member … granularize the control ABAC …
> absolutely real time changes in shared space."
> Later: "cover all the phases and verify each one of them with playwright and google dev chrome mcp".

- Workspaces (orgs) with members, roles (owner, admin, member, guest), and email or link invites.
- Teamspaces (open, closed, private); a Private section per member; a Shared section.
- Inherited, granular page permissions: ABAC plus relationship tuples, enforced server-side.
- Real-time co-editing of shared pages: a Yjs CRDT, server-authoritative, every update
  permission-checked.
- The IDE sandbox mirrors the spaces: `/workspace/Private/`, `/workspace/Teamspaces/<name>/`,
  `/workspace/Shared/`. A root-level file goes to Private.
- A lab of real accounts around `dylan@gmail.com`: alice (admin, Engineering), bob (Engineering,
  closed), carol (Design, private), dave (guest, viewer on "Launch Plan"), eve (outsider). It is
  proven by multi-browser Playwright specs.

**Binding user decisions; do not re-open them:**
1. Generic primitives go in grobase, and osionos consumes them.
2. Co-editing uses Yjs/yrs with server checks.
3. The sandbox roots are `Private/ Teamspaces/ Shared/`.
4. The lab is built around dylan@gmail.com.
5. Test against a **local grobase on this host**. The VM stays untouched.
6. Verify every phase with Playwright **and** the chrome-devtools and playwright MCPs.

## 2. Phase status

| # | Slice | Status |
|---|---|---|
| P0 | Diagnose + spikes | Done. yrs `=0.26.0` KEEP (0.27+ needs Rust > 1.89). PL/pgSQL evaluator KILL → Go evaluator. The "Not a page yet" e2e is still open (the IDE box cap was full, §6) |
| P1 | grobase authz | **Built and verified.** PR Univers42/grobase#43 → develop, head `2dbec802`. Not merged at writing (§3) |
| P2 | osionos projection triggers + shadow mode | Not started. Cleared by the devil under N1–N10 |
| P3 | Teamspace, member and invite routes; enforce; UI; lab seed; cl1/cl4/cl5 | **Explorer Private/Shared sections merged** to osionos develop (PR #26 → `44ace4ac`). The rest is not started |
| P4 | Sandbox roots, inbound rules, volume migration, cl6 | Not started. Needs its own devil verdict |
| P5 | grobase `realtime-ydoc` crate, migration 092, materialize | Not started. Needs a devil verdict. **Renumber its gates**: m231–m233 are now taken by authz |
| P6 | osionos CRDT binding, cl2/cl3 | Not started |
| P7 | Docs and ADRs | P2's ADR takes **0015 or later** (0014 is taken by an untracked ADR in the user's tree). An `.out-of-scope` record on "authz tuple rows shared across sources" is owed |

### What P1 is (grobase, `feat/authz-relationship-tuples`, 14 commits on main `9e176b50`)

- Migration `scripts/migrations/postgresql/091_authz_tuples.sql`:
  - `authz.tuples` with `source` in the primary key (N1). Each producing row owns its tuples.
  - `authz.models`.
  - The write primitive `authz.replace_source_tuples(app, object_type, object_id, source, tuples jsonb)`:
    a diff (an unchanged set writes 0 rows), SECURITY DEFINER, no `pg_notify` (N2).
  - Granted to `service_role` only.
- Go evaluator `src/control-plane/internal/authz`: per request, one `REPEATABLE READ READ ONLY`
  transaction, an `unnest` frontier prefetch (N3), tri-state ALLOW / DENY / CUT where CUT denies,
  depth 16, a node budget, a bounded pool that answers 503 (N4), and an exclude that fails closed (N6).
- HTTP behind **`AUTHZ_ENABLED` (default off = not mounted)**: `PUT|GET /v1/authz/model`,
  `POST /v1/authz/tuples`, `/check`, `/check-batch` (≤ 1000). API key only (a JWT gets 401), scopes
  `authz:read` / `authz:write`, a body `app` gets 400, and a model change that orphans tuples gets 409.
  Kong exposes the public self-auth route `/authz/v1`.
- Gates (call them by full file name): `m231-authz-tuples.sh` PASS, `m233-authz-source-races.sh`
  PASS, **`m232-authz-perf.sh` RED**. Its batch-500 1-client p95 measured 22.0 / 24.6 / 26.1 ms
  against 25. That is disclosed in the PR. The threshold is unchanged on purpose: the devil ruled
  the only alternative design worse (34.8 ms). **`AUTHZ_ENABLED` stays unset everywhere** until
  m232 passes or a devil ruling amends N4 (push condition C2).

### What the P3 explorer is (osionos, merged to develop)

- `src/features/page-file/model/pageSections.ts`, `sectionDeps.ts`, `sectionedFacade.ts`.
- Private = a root page I own that is not shared, in every workspace. Shared = everything else I
  can read. The empty-section hint is in `src/features/ide/ui/WorkspaceExplorerRow.tsx`.
- Browser-verified on the local stack: Private and Shared visible, zero console errors.

## 3. Unfinished at writing: the publish (main == develop in all 3 repos)

The user asked: "push all the result of your work in github.. main and develop with the same
commit". The devil's conditions C1–C9 in `devil-push.md` apply. Refs at writing:

| Repo | main | develop | Gitlinks on groot develop |
|---|---|---|---|
| grobase | `9e176b50` | `8b9321a6` (an ancestor of main) | grobase `9e176b50` |
| osionos | `08418d7f` | `44ace4ac` (main fast-forwards to it) | osionos `ab21ebd7` |
| groot | `b03dcbdc` | `3f0e7e7b` (main fast-forwards to it) | |

**Re-read every ref first** with
`git ls-remote git@github.com:Univers42/<repo>.git refs/heads/main refs/heads/develop`. If one moved,
re-inspect before you continue (C1). Then finish in order:

1. **grobase #43 CI.** Wait on head `2dbec802` with
   `tools/ci-wait.sh grobase <sha> '^(Unit tests \(go\)|Shellcheck|Formatters|Security gates|Build tenant-control|Build \(infra\) kong|Secrets in the tree|Verified secrets|Dependency advisories)'`.
   On the previous head everything was green except Formatters, which `f0e42488` fixes.
   SonarCloud is advisory.
2. **Merge #43** into develop:
   `tools/gh.sh PUT /repos/Univers42/grobase/pulls/43/merge '{"merge_method":"merge","sha":"<head>"}'`.
   The `sha` guards against a moved head. Never merge red. A grobase main move publishes
   `ghcr.io/univers42/grobase-*:latest` (C5).
3. **main ← develop fast-forwards are user-run.** The auto-mode classifier refused the API ref
   PATCH as "CI Bypass". Do not work around it. Hand the user these lines (non-force; the
   rulesets refuse a non-fast-forward):

       ! git -C /goinfre/dlesieur/groot/apps/grobase fetch origin && git -C /goinfre/dlesieur/groot/apps/grobase push origin origin/develop:main
       ! git -C /goinfre/dlesieur/groot/apps/osionos/app fetch origin && git -C /goinfre/dlesieur/groot/apps/osionos/app push origin origin/develop:main

4. **groot pin.**
   - Worktree `/goinfre/dlesieur/wt/groot-pins`, branch `chore/pin-authz-and-explorer`. Reset it
     to the new `origin/develop`.
   - Set **only** the gitlinks `apps/grobase` and `apps/osionos/app` to the new main SHAs:
     `git update-index --cacheinfo 160000,<sha>,<path>`, by explicit path, never `-A` (C6).
   - Commit `chore(submodules): pin grobase main <sha>, osionos main <sha>`.
   - Push, open a PR into develop, wait for `baas-ci`, `fresh-machine`, `gitleaks` and
     `graph-studio*`, then merge.
   - Name the pre-existing red check `build osionos-app + serve the pack (bats)` (red since
     `8d07be56`) in the PR.
   - Then the user runs:
     `! git -C /goinfre/dlesieur/groot fetch origin && git -C /goinfre/dlesieur/groot push origin origin/develop:main`.
5. **This handoff's own PR** (`docs/groot-lab-handoff`) is merged into develop before step 4 if the
   user agreed. Otherwise it rides the same fast-forward.
6. **C8, the finish line:** `ls-remote` shows main == develop in all 3 repos, and groot's gitlinks
   equal the new grobase and osionos main SHAs. Report it with the command output.

Out of this publish:
- root `.mcp.json`: hardcoded `/goinfre` paths, and CLAUDE.md says MCPs go through
  `scripts/tools.sh` (C7);
- `infrastructure/tls/nginx.conf`, which another session edited;
- the untracked ADRs 0002–0014 and `.out-of-scope/` in the user's tree;
- grobase `fix/waf-921130-osionos-content` (b0ca9846): a duplicate of another session's fix.
  Never push it. Offer to delete it.

## 4. Next work after the publish, in order

Each slice: a worktree, the devil before code, Sonnet `builder` agents with detailed briefs, and
you verify by re-running the gates yourself. Commit in the submodule first, then the root pins it.

1. **P2.** Projection, plus a bridge module in shadow mode.
   - Root `models/` migrations: teamspaces, invites, and the authz projection.
   - Projection triggers are `AFTER INSERT OR DELETE` plus
     `AFTER UPDATE … WHEN (OLD.<access cols> IS DISTINCT FROM NEW.<access cols>)`.
   - The mapping is a pure function of OLD/NEW, shared by the triggers, the backfill and the
     drift view. The drift view must be empty.
   - `scripts/ensure-authz-tenant.sh`: a dedicated tenant `osionos` with an `authz:read` key in
     `./.env.local` as `OSIONOS_AUTHZ_API_KEY`. Never in a `VITE_*` var, and covered by a bats
     leak test.
   - `scripts/bridge-authz.mjs`: `OSIONOS_AUTHZ_MODE=legacy|shadow|enforce`, default legacy. Add
     it to **both** bridge Dockerfile COPY lists.
   - Every condition in `devil-p1p2-r2.md` (N1–N10, C10–C20) is an acceptance criterion.
     Re-submit the written SQL to the devil.
2. **P3, the rest.**
   - Teamspace, member and invite routes (link-first, since mail is quota-limited and goes
     through grobase only).
   - `tools/seeds/seed_groot_lab.sh`: refuses staging/prod, keeps passwords in a git-ignored env
     file, and works through bridge routes.
   - `utils/mk/lab.mk` (`lab-seed`, `lab-e2e`, each followed by a `## ` help line).
   - Specs `tests/e2e/specs/cl1-*`, `cl4-*`, `cl5-*`.
   - Enforce only at zero unexplained shadow disagreements, both directions. A CUT, budget or
     store error answers 503, never a legacy fallback.
3. **P4** (devil first): sandbox roots and inbound rules in `pageIndex`, the ledger v2 migration
   in `reconcileOnAttach.ts`, and cl6 (SKIP, never pass, without a sandbox plane). Re-run
   `probe-terminal` to close "Not a page yet".
4. **P5/P6** (devil first, renumber the gates): the yrs crate, migration 092, materialization, the
   CRDT binding behind `osio.collab.crdt`, and cl2/cl3 co-typing in 3 browsers.
5. **P7:** fix the false live-collab claims at `wiki/DEFENSE.md:90` and
   `wiki/product/02-osionos.md:57-68`, write the ADRs, and run `make pretty-check` on the diff.

**Done** means: the gates are green (re-run by you), the Playwright spec passes, there is an MCP
screenshot or DOM check, and the evidence goes to the user as commands plus output.

## 5. Hard rules (each has burned this project before)

- **Concurrent sessions share the checkout.** Never switch, merge, commit or stash in
  `/goinfre/dlesieur/groot` or its submodule checkouts. Use worktrees under `/goinfre/dlesieur/wt/`
  and explicit refspecs. Coordinate with live peers through `ListAgents`/`SendMessage` before you
  recreate shared containers.
- **Never push without asking.** The user authorized the publish in §3 only.
- **grobase commits carry no Co-Authored-By.** Root and osionos follow the session's attribution
  reminder. A builder once put the trailer inside subject lines; check `git log --format=%s`.
- **Never print secret values.** `tools/gh.sh` reads `GH_PAT` from groot `./.env` (the last line;
  the first one is stale) and never echoes it. Edit KEY=VALUE files with `scripts/lib/envfile.sh`.
- **Human-run only:** vault42/42ctl commands, anything on the VM or prod, real-mail sends, and the
  WAF rule 10150 deploy (owned by the titan-mail session). Hand the user `! <command>` lines.
- **Don't work around classifier denials**, and don't guess passwords.
- **Disk:** `/goinfre` was at 2.1 GB free at writing. Run `df -h /goinfre` before any build and
  stop under 3 GB. Caches go under `/goinfre/dlesieur/.cache`, never `$HOME` (4.7 GB quota).
- **Host quirks:**
  - The shell is zsh-like: `for x in $VAR` does not split, so wrap scripts in `bash -c`.
  - Docker is rootless: `--user $(id -u)` fails.
  - `pkill -f <pattern>` can kill your own shell.
- **Run the whole quality gate before you push osionos** (`bash scripts/docker-run.sh quality`),
  not only `test-canvas`. A literal `text-[12px]` once failed CI.
- Every heuristic, timeout, cache or budget carries a `Caveat:` line. Comments say why. Negative
  tests are mutation-tested, because a bats `! cmd` that is not last is vacuous.

## 6. Environment and how to verify

**Local stack.**
- grobase devlean runs on this host, not through the VM link.
- Start it only with the scratch override:

      make -C apps/grobase up EDITION=devlean COMPOSE_FILE="docker-compose.yml -f /sgoinfre/students/dlesieur/groot-collab/2026-10-17/tools/grobase-net-external.yml"

  The override declares the stale `mini-baas_mini-baas` network external, sets `cpus: 0` (rootless
  docker has no CPU cgroup), and blanks the orchestrator's SMTP credentials so local Mailpit
  works.
- Never run a plain `make all` or `make backend-up` here: they pull vault42 and need sudo for the
  CA.
- Every local relaxation is listed in memory `local-grobase-on-host`. The auth-gateway runs with
  `AUTH_LOGIN_EMAIL_OTP=false`, because the ghcr `:latest` grobase has no OTP route.

**Tests.**
- grobase Go:

      docker run --rm -v "$PWD/src/control-plane":/src -w /src -v mini-baas-gomod:/go/pkg/mod -v mini-baas-gobuild:/root/.cache/go-build public.ecr.aws/docker/library/golang:1.26.9 go test ./internal/authz/ ./cmd/tenant-control/

  Run it from the grobase worktree. Formatting is `gofumpt v0.8.0` and `mvdan/shfmt:v3.10.0 -i 2`
  (`orchestrators/makes/prettier.mk`).
- osionos (in its worktree): `bash scripts/docker-run.sh quality | test-canvas | test-bridge | build`.
  Last merge tree: quality rc=0, test-canvas 2424/0, test-bridge 975/0, build rc=0.
- e2e scratch probes: `tools/probe/run.sh <spec>`, specs in `tools/probe/specs/`. It runs image
  `groot-e2e:1.63.0` with the `tests/e2e/lib` helpers, and the demo password comes from
  `scripts/lib/demo-login.sh`. `probe-sections.spec.ts` with `SECTIONS_EXPECT=1` asserts the
  Private/Shared roots.
- Real specs go in `tests/e2e/specs/`: `bash tests/e2e/run.sh specs/<name>.spec.ts`.
- MCPs: chrome-devtools and playwright (in the uncommitted root `.mcp.json`). Never type real
  passwords into an MCP fill call, because it lands in the transcript. Log in through specs.

**IDE plane.**
- It runs on the VM, reached by a hand-opened ssh control master forward (memory
  `local-grobase-on-host`).
- Its box cap of 2 was full, so a session POST got 503. Raising the cap is user-run.
- `probe-terminal` stays the open check for "Not a page yet".
