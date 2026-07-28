# osionos IDE — Backlog & Living Design Record

> **What this file is.** The single source of truth for the osionos in-app IDE: what it
> is, why it is shaped the way it is, what is done, what is missing, and where we are
> going. It is a **living document** — every agent or human who touches the IDE updates
> the relevant section and appends to the [Changelog](#changelog). It supersedes the
> scattered narrative in commit messages and the infra runbook
> (`infrastructure/docker/osionos/ide-sandbox/README.md`), which it now reconciles.
>
> Last reconciled: **2026-07-20** (branch `feat/ide-full-mode`).

---

## 1. Vision & scope

osionos already treats a document as a tree of blocks. The IDE extends that same substrate
into a **real development environment inside the workspace**: a code file is just a page
(`surface:"code"`), a folder is a page, and a workspace can flip into a full VS Code-style
shell — editor, file explorer, an interactive terminal, language intelligence, source
control, and live code execution — **without leaving osionos and without a second
persistence layer**.

Two execution models sit behind it, deliberately separated:

- a **stateless code runner** — "run this snippet," no shell, no state, no egress; and
- a **persistent per-`(user, workspace)` sandbox** — a real Linux container with a shell,
  a persistent volume, git, and network egress for `pip`/`npm`/`git`, whose files sync
  bidirectionally with the page tree.

The persistent sandbox *inverts every safety guarantee* of the stateless runner (it has
state, a shell, and egress), so it is wrapped in a defense-in-depth isolation architecture
and gated behind a risk-reviewed acceptance corpus. **Nothing ships on by default.**

The end state we are driving toward: a genuinely powerful, multi-language IDE (compiled
languages, rich language servers, a debugger, tests, tasks) that also runs in the cloud
(fly-machines), not only on a single developer's machine.

---

## 2. How to update this file (the living-doc contract)

- **Statuses** are one of `TODO` · `DOING` · `DONE` · `DEFERRED` · `BLOCKED`.
- **Every `DONE` cites proof** — a commit hash and/or a `file:line` — per the repo's
  `prompt-contract.md` ("evidence, not adjectives"). No "done" without a pointer.
- **Update the section you changed**, not the whole file. Keep the current-state matrix
  (§4) and the gaps catalogue (§5) honest — if you close a gap, move it; if you find one,
  add it.
- **Append to the [Changelog](#changelog)** with the date, what changed, and the proof.
- **Convert relative dates to absolute** (this file outlives the sprint).
- When code and this doc disagree, **the code wins** — fix the doc and note it in the
  changelog.

---

## 3. Architecture & design choices (the durable knowledge)

### 3.1 Two planes, three gate layers

| Plane | What | Container / net | Gate(s) | Sudo to enable? |
|---|---|---|---|---|
| **A — code runner** | one-shot `POST /api/ide/run` (SSE) + `/api/ide/format` | `track-binocle-osionos-runner`, `osionos-runner-net` (`internal`, no egress) | bridge `OSIONOS_RUNNER_URL` + compose profile `runner` | **No** |
| **B — persistent sandbox** | shell (PTY), LSP, live file-sync, git, ripgrep search | per-`(user,workspace)` container on an **isolated 2nd Docker daemon**, fronted by `osionos-ide-socket-proxy` on `osionos-ide-control-net` | bridge `OSIONOS_IDE_SANDBOX=1` **and** `OSIONOS_IDE_DOCKER_HOST` **and** compose profile `ide` | **Yes** (2nd daemon host prep) |

A **third, frontend** gate — the `osio.ide` feature flag (`featureFlags.ts:174`, default
**OFF**) — controls whether any IDE UI is even reachable. It is explicitly **not** a
security control (execution is server-gated); it just keeps the additive feature off the
normal block-editor surface. Turn on with `?osio.ide=1`, the `osio.ide` localStorage key,
or `VITE_OSIO_IDE=1` at build time.

**Why "everything ships OFF + double/triple-gated":** the persistent sandbox is a real
code-execution + egress surface. Safe-by-default means an operator must consciously flip
every gate, and a misconfigured frontend can never open an execution path on its own.

### 3.2 The load-bearing idea: "a code file is a page"

`src/features/ide/model/codeFile.ts` — a `surface:"code"` page stores its whole file as one
`code` block in `page.content`; a `surface:"folder"` page is a directory. Consequences:

- **No new table, route, or persistence layer.** Files ride the existing page save path —
  offline-first outbox/ledger sync, ACL, hydrate (`src/store/`, `src/store/sync/`).
- **The file tree *is* the page tree**, filtered + sorted folders-first
  (`src/features/ide/model/ideFileTree.ts`).
- **The page tree is the sync manifest** — path↔pageId is *derived* (`idePaths.ts`
  `pathForPage`), so there is no `.osio/manifest.json` to keep in step.
- The bridge already whitelists the surface: `PAGE_SURFACE_VALUES` includes `'code'`
  (`scripts/bridge-api.mjs:104`), applied on read + write; no DB `CHECK` constraint blocks
  it — a created code page survives reload.

### 3.3 The isolation model (Plane B) — why it is shaped this way

Documented in full in `infrastructure/docker/osionos/ide-sandbox/README.md`. The spine:

- **A dedicated, isolated second Docker daemon** (`docker-ide.service`, a *second rootful*
  dockerd with `--userns-remap` + `--iptables=false`, own loopback data-root) runs the
  sandboxes — so a sandbox/provisioner compromise **cannot see the 28 `mini-baas-*`
  backend containers** on the main daemon (the catastrophic-blast-radius fix). Rootless
  dind was rejected because this host keeps `apparmor_restrict_unprivileged_userns=1`,
  which we do **not** relax.
- **A custom socket-proxy** (`ide-socket-proxy/proxy.mjs`) is the only path from the
  provisioner to that daemon. Its differentiator over off-the-shelf proxies is
  **create-body vetting** (`unsafeCreateBody`): it rejects `Privileged`, host
  `Binds`/bind-`Mounts`, host `NetworkMode/PidMode/…`, `CapAdd`, `Devices`,
  `seccomp=unconfined`. It also **allowlists endpoints** and **pins container ids** to the
  `ide-<32hex>` shape so an exec can never target a foreign container.
- **A connect-time-IP-revalidating egress proxy** (`ide-egress-proxy/proxy.mjs`): a
  CONNECT proxy that re-resolves the hostname, validates the **resolved IP**, and dials
  that literal IP — so a hostname resolving to `169.254.169.254` (cloud metadata) or a
  backend IP is refused (DNS-rebind / SSRF safe). The sandbox net is `internal`, so this
  proxy is the **only** route off-box, and it is **CONNECT/443-only against a fixed host
  allowlist** (npm/pypi/crates/goproxy/github + configured git hosts).
- **Everything is server-derived** — no client field reaches the Docker API. Sandbox names
  are `sha256(user:workspace)[:32]`; git subcommands are allowlisted with **`config`
  explicitly denied** (so nobody can set `credential.helper=store` and defeat the per-op
  PAT); writes are base64-in-argv with `..`/leading-`/` traversal guards; search passes the
  query after `--` (no flag injection).
- **The PAT model:** a git Personal Access Token is injected **per git op** via `docker exec
  -e GIT_PAT`; the system credential helper emits the secret **only** when `GIT_PAT` is in
  the git process env, so the long-lived interactive shell never carries it. Core dumps are
  disabled so a git crash can't drop a PAT-bearing core on `/workspace`.

### 3.4 Frontend design choices

- **CodeMirror 6, not Monaco** (`src/features/ide/model/codeMirrorSetup.ts`). CodeMirror
  themes entirely through the app's `--osio-*` CSS variables, so the editor follows all 7
  palettes + light/dark with zero JS theme-branching. Uncontrolled document (caret never
  jumps); debounced writeback (1200 ms); Compartments reconfigure language/LSP without
  rebuilding the view; editor-scoped `Prec.highest` keymaps so IDE chords never collide
  with the global automations dispatcher. **Deliberately no autocomplete / no in-editor
  lint panel** in the base editor ("colors + write code, no intellisense") — LSP adds the
  intelligence in IDE mode.
- **xterm.js** terminal, lazy-loaded so it never lands in the warm chunk; PTY geometry sent
  **out-of-band** as an APC control frame (`ESC _ osio-resize:COLS,ROWS ESC \`).
- **Small single-purpose zustand stores:** `ideModeStore` (persisted, per-workspace IDE
  mode + active panel), `useDevMode` (persisted), `diagnosticsStore` (transient, keyed by
  URI → Problems panel). The page store (`usePageStore`) stays the single source of truth;
  all IDE state derives from it.
- **Two layers of the shell:** (1) a page *surface* — `PaneContent.tsx` swaps in
  `CodeFileView` for `code` pages (double-guarded on surface AND flag); (2) a workspace
  *mode* — `IdeShell` (`widgets/ide-shell/`) that **reuses `WorkspaceGrid` verbatim** as
  its editor area, wrapped in activity bar / side panel / terminal strip / status bar.
- **Pervasive code-splitting** (perf is a first-class concern): the whole `IdeShell`, each
  language grammar, each Prettier plugin, xterm, and `@codemirror/lsp-client` are all
  separate lazy chunks.

### 3.5 The transport map

All IDE traffic goes through the **bridge** (`:4000`), authenticated per call with the
app-session JWT, never direct to grobase. All routes are **auth-first + double-gated**.

| Transport | Route | Phase | Notes |
|---|---|---|---|
| REST | `POST /api/ide/run` (SSE) · `/api/ide/format` | P1 | Plane A runner |
| REST | `POST /api/ide/session` (GET/DELETE) | P2 | provision/reuse/reap sandbox |
| WS | `/api/ide/pty` | P3 | interactive `bash -l`, APC resize |
| WS | `/api/ide/fsync` | P4 | fs-agent event stream (container→pages) |
| REST | `POST /api/ide/fs` | P4 | editor→container write (base64 argv) |
| WS | `/api/ide/lsp?lang=` | P5 | LSP stdio relay |
| REST | `POST /api/ide/git` | P6 | status/commit/push; `config` denied; per-op PAT |
| REST | `POST /api/ide/search` | P7 | `rg --json`; query after `--` |

Key bridge modules: `scripts/bridge-runner.mjs`, `bridge-ide-sandbox.mjs` (provisioner),
`bridge-ide-exec.mjs` (PTY/LSP/fsync WS relays), `bridge-ide-ops.mjs` (fs/git/search),
`ide-docker.mjs` (exec engine), `ide-ws.mjs` (hand-rolled dependency-free WebSocket),
`ide-sandbox-spec.mjs` (all server-derived specs). **Gotcha:** any new `bridge-ide-*.mjs`
must be added to the `COPY` list in **both** `infrastructure/docker/osionos/bridge.Dockerfile`
**and** `apps/osionos/app/deploy/bridge-fly/Dockerfile`, or it is silently absent from the
built containers.

---

## 4. Current-state matrix (reconciling the three label axes)

The history uses **three overlapping axes**. This table is the reconciliation.

### 4.1 Backend "P-phases" (route/plane phases)

| Phase | Scope | Status | Proof |
|---|---|---|---|
| P1 | Stateless code runner | `DONE` (built) | `infrastructure/docker/osionos/runner/{Dockerfile,server.mjs}`, `bridge-runner.mjs` |
| P2 | Hardened isolated sandbox plane | `DONE` (built + activated + verified) | commit `4b835e9e`; live corpus 15/15 in `19b324dd` |
| P3 | Interactive PTY shell | `DONE` | `bridge-ide-exec.mjs`, WS `/api/ide/pty`; commit `c760e1ba`/`3d17e518` |
| P4 | fs-agent + bidirectional live sync | `DONE` | commits `22e2b017`, `9c6fee17`; `osio-fs-agent.mjs`, `useIdeFsSync.ts` |
| P5 | LSP relay (TypeScript + Pyright) | `DONE` (2 servers only) | `bridge-ide-exec.mjs` `LSP_SERVERS`; `lspClient.ts` |
| P6 | Git brokering / Source Control | `DONE` | commit `c760e1ba`; `POST /api/ide/git`, `useIdeGit.ts` |
| P7 | ripgrep search **+ fly provider** | search `DONE`; **fly provider `DEFERRED`** | `POST /api/ide/search` shipped; fly-machines not started |

### 4.2 Rollout "Parts" (the live-IDE integration arc)

| Part | Scope | Status |
|---|---|---|
| A | Infra — isolated `docker-ide` daemon | `DONE` (`3d17e518`) |
| B | Terminal — xterm.js | `DONE` |
| C | LSP — CodeMirror lsp-client | `DONE` |
| D | Bidirectional pages↔sandbox sync | `DONE` (`9c6fee17`) |
| E | **Live activation** (host prep + `verify.sh` 15/15 + e2e) | `DONE in code/commit` `19b324dd` — but **not performed on every machine**; must be re-run per host |

### 4.3 Frontend e2e "P0/P1" (unrelated to backend P-phases)

| Label | Scope | Status | Proof |
|---|---|---|---|
| P0 | Dedicated IDE layout | `DONE` | `tests/e2e/functional/ideMode.spec.mjs` |
| P1 | File-explorer CRUD & search | `DONE` | `tests/e2e/functional/ideWorkspace.spec.mjs` |

### 4.4 Documentation-lag corrections (fixed here; runbook still to be edited)

- The runbook's **"Remaining to finish"** still lists *Live activation* as pending — but
  commit `19b324dd` performed it and reports **live hostile corpus 15/15** + full toolchain.
  → Live activation is **done in code**; it must simply be **re-run on each new host**.
- The runbook's **condition 12** ("PAT scoped + short-lived") reads *"deferred to P6"* — but
  **P6 shipped** (request-scoped per-op PAT, `config` denied). → Effectively addressed.
- The runbook prose says **"16/16 corpus"**; `verify.sh` actually emits **15 PASS** lines
  (some conditions are proven offline via unit tests / `--selfcheck`, condition 12 is
  deferred). → The live gate is **15/15**, not 16/16.

> **Action item (docs):** edit `ide-sandbox/README.md` to match §4.4. Tracked as gap
> `G-DOC` below.

---

## 5. Known limitations / gaps catalogue (feeds the roadmap)

| ID | Gap | Where | Severity |
|---|---|---|---|
| G-ACT | Live activation must be re-run per host (needs operator sudo) | `ide-sandbox/README.md` §Host prereqs | expected |
| ~~G-REAP~~ | ✅ **RESOLVED** — reaper scheduled on a guarded `unref()` interval in `startBridgeServer` | `bridge-api.mjs` | fixed |
| ~~G-CREATE~~ | ✅ **RESOLVED** — errors surfaced via `notifyCreateFailure` (+ canvas test) | `pageCreateFeedback.ts` | fixed |
| ~~G-DBSURFACE~~ | ✅ **RESOLVED (root cause of "can't create a dev page")** — the live `osionos_pages_surface_check` DB constraint allowed `page/agent/home/folder/wiki/app` but **not `code`**, so every `surface='code'` insert 400'd (`23514 check_violation`). The `notifyCreateFailure` fix surfaced it. The fix migration existed (`models/osionos-code-surface-migration.sql`, committed `ef168070`) but had **never been applied** to the live DB — applied it; Playwright-verified `surface='code'` now → **HTTP 201**. | `models/osionos-code-surface-migration.sql` | fixed |
| ~~G-MIGRUN~~ | ✅ **RESOLVED** — `scripts/apply-models.sh` (checksum ledger; adopts existing schema, applies only new/changed, never blindly replays the order-sensitive surface migrations). `make apply-models` wired into `make all`; `make apply-models-check` is a read-only gate that fails on a committed-but-unapplied migration (shellcheck-clean, gate proven). | `scripts/apply-models.sh` | fixed |
| ~~G-RUNLANG~~ | ✅ **RESOLVED** — all 13 runner languages installed + verified running | `runner/Dockerfile` | fixed |
| ~~G-EXEC~~ | ✅ **RESOLVED** — runner `/work` was `noexec` → every compiled language failed; made exec-able | `docker-compose.yml` | fixed |
| ~~G-SBXLANG~~ | ✅ **BUILT** (runtime pends Plane B) — gcc/g++/clang/make/go/rust/jdk added to the sandbox image | `ide-sandbox/Dockerfile` | fixed (built) |
| ~~G-LSP~~ | ◑ **PARTIAL** — go/rust/clangd added + wired (built); **Java (jdtls) still TODO** | `bridge-ide-exec.mjs`, `lspClient.ts`, `ide-sandbox/Dockerfile` | mostly fixed |
| ◑ G-DEBUG | Run panel now live (`IdeRunPanel` — streams the runner); **DAP debugger + test-runner + tasks still TODO** | `src/features/ide/ui/IdeRunPanel.tsx` | partial (Epic 3) |
| G-SEARCH | Frontend search is in-memory browser grep; the container `rg --json` route (`/api/ide/search`) exists but is unused by the UI | `browserSearch.ts`, `IdeSearchPanel.tsx` | polish |
| G-GIT | Git panel = status/commit/push only; no branch/stash/diff-view | `useIdeGit.ts:36-38` | polish |
| G-FLY | fly-machines provider deferred; `/api/ide/*` 404s on fly/Vercel (Docker-only today) | `ide-docker.mjs` | feature |
| G-QUOTA | Per-sandbox block quota off by default (needs xfs+pquota data-root; `OSIONOS_IDE_STORAGE_QUOTA` unset) | `ide-sandbox-spec.mjs:56-60` | hardening |
| G-FSW | fs-watch: 512 KiB file cap, binaries skipped, **no rename event** (rename = delete+write), no debounce, unbounded watcher-map growth | `osio-fs-agent.mjs` | polish |
| G-CREATEUI | Sidebar "New code file" uses a native `window.prompt`; the Explorer uses a proper inline input — inconsistent | `SidebarPageTree.tsx:391-393` | polish |
| G-LSPRE | No LSP reconnect beyond client-eviction-on-close + next-open | `lspClient.ts:85-95` | polish |
| G-TERMRE | No terminal auto-reconnect (relies on panel remount) | `useIdeTerminal.ts:35` | polish |
| G-WSCAP | WS message cap 1 MiB, no permessage-deflate — a very large LSP payload closes the socket | `ide-ws.mjs:25` | polish |
| ~~G-RUNSTDIN~~ | ✅ **RESOLVED (interactive run)** — the one-shot runner still has no stdin (`input()` → EOFError), but in IDE Workspace mode the **Run** action now executes the file in the real sandbox **PTY** (`terminalRunBus` → `useIdeTerminal` → `ws.send`), where `input()` works. Playwright-verified: interactive `input()` over the live PTY reads input and prints the result (no EOFError). | `terminalRunBus.ts`, `CodeFileView.tsx`, `useIdeTerminal.ts` | fixed |
| G-DOC | Runbook doc-lag (see §4.4) | `ide-sandbox/README.md` | docs |

---

## 6. Roadmap — the four priority tracks (epics)

Ordered fastest-value first. Each ships flag-gated where it adds surface, with tests in the
project frameworks (canvas `node --test`, e2e Playwright, bridge `node --test`), and the
runbook/OpenAPI updated per `.claude/rules/api-convention.md`. Security-sensitive changes
re-run the `verify.sh` gate.

### Epic 0 — Activation & correctness (unblocks "we can't do anything") — `DOING`
- [x] **G-CREATE** `DONE` — errors surfaced via `notifyCreateFailure` (`pageStore.actions.ts`
      → extracted to `src/store/pageCreateFeedback.ts`); canvas test
      `tests/canvas/ide-create-page-error.test.ts` (827/827 green).
- [x] **osio.ide** `DONE` — `VITE_OSIO_IDE=1` in `apps/osionos/app/.env`, threaded through
      compose build-args + `app.Dockerfile` `.env.production.local` (computed
      `import.meta.env[key]` read needs a .env FILE, not Dockerfile ENV). Verified baked:
      the app bundle contains `VITE_OSIO_IDE:"1"`.
- [x] **Plane A** `DONE` — `OSIONOS_RUNNER_URL=http://osionos-runner:7900` (in `.env.local`
      + app `.env`), runner up via `COMPOSE_PROFILES=runner`, app rebuilt (`make update_web`).
      Verified end-to-end: all **13** languages run through the runner (python/ruby/c/cpp/
      go/rust/java = 42).
- [x] **G-REAP** `DONE` — `reapExpiredSandboxes` scheduled on a guarded, `unref()`'d
      interval in `startBridgeServer` (`bridge-api.mjs`); self-gates OFF until Plane B.
      Bridge tests 89/89 green.
- [x] **Plane B** `DONE (activated)` — host prep was already in place; re-seeded the new
      toolchain image into `docker-ide`, **`verify.sh` 15/15**, flipped the bridge gate
      (`OSIONOS_IDE_SANDBOX=1` + `OSIONOS_IDE_DOCKER_HOST` in `.env.local` + app `.env`),
      recreated the bridge. Control path verified: daemon reachable, socket-proxy
      `/_ping 200`, bridge on `osionos-ide-control-net`. Browser E2E is the final confirm.
- **Acceptance:** create a code page (survives reload) ✅, Run + Format work ✅, a forced API
  failure shows an error ✅, the powerful terminal + LSP + live-sync + git are **armed**
  (`/api/ide/*` live) — confirm in the browser.

### Epic 1 — Languages + compile toolchains — `DONE` (runner) / `DONE, pending activation` (sandbox)
- [x] Runner image + `LANGS`: `DONE` — installed the missing 6 (ruby/php/lua/perl/go/rust,
      `lua` symlinked); all 13 declared languages now run (verified end-to-end).
- [x] Runner `/work` `noexec` bug (**G-EXEC**): `DONE` — compiled languages built a binary
      in `/work` and hit "Permission denied" (Docker tmpfs defaults noexec). Made `/work`
      exec-able (`docker-compose.yml`); c/cpp/go/rust/java now run. Isolation is unaffected
      (rests on caps/seccomp/read-only-rootfs/non-root/internal-net/limits, not noexec).
- [x] Sandbox image: `DONE (built)` — `gcc/g++/clang/make/rustc/cargo/default-jdk` via apt +
      modern Go via tarball (bookworm Go too old for gopls). `go`/`gofmt` symlinked into
      `/usr/local/bin` (the `bash -l` sandbox shell's `/etc/profile` drops the ENV PATH).
      Runtime verify pends Plane B activation.
- **Acceptance:** every language the UI marks runnable runs in the runner ✅; Go/Rust compile
  in the sandbox shell ⏳ (Plane B).

### Epic 2 — More LSP servers — `DONE (built + wired)`, runtime pending activation
- [x] Sandbox image: `DONE` — `gopls` (go install), `rust-analyzer` (release binary),
      `clangd` (apt). Binaries verified in the image (gopls v0.23, rust-analyzer 0.3.29,
      clangd 14). **jdtls (Java) deferred** — tarball + launcher is fiddly; tracked below.
- [x] `bridge-ide-exec.mjs` `LSP_SERVERS` (+`go`/`rust`/`clangd`) and `lspClient.ts`
      language→server map (`go`/`rust`/`c`/`cpp`) — `DONE` (quality + 89 bridge tests green).
- [x] Reused the exec-attach relay + `lspFraming.ts` codec unchanged.
- **Acceptance:** editing `.go`/`.rs`/`.c`/`.cpp` yields diagnostics/completion ⏳ (Plane B).
- **Follow-up:** add `jdtls` (Java LSP); wire `java` into the two maps once it lands.

### Epic 3 — Debugger / tests / tasks — Run panel `DONE`; debugger `TODO` — gap G-DEBUG
- [x] **Run panel** `DONE` — replaced the `IdeSidePanel` placeholder with `IdeRunPanel`
      (`src/features/ide/ui/IdeRunPanel.tsx`): runs the active code file through the live
      runner (Plane A), streams stdout/stderr + exit status, Run/Stop/Clear. Reuses
      `useCodeRunner` + `RunConsole`'s `streamClass`. (tsc/eslint verified.)
- [ ] **Debugger (DAP):** new relay `WS /api/ide/debug` mirroring the LSP relay (debugpy /
      js-debug in the sandbox image); breakpoint UI. **Needs Plane B** (sandbox) to run.
- [ ] **Test runner + tasks:** a test-runner action + a minimal tasks system.
- [ ] Flag-gated, argv unit-tested, `verify.sh`/OpenAPI extended.
- **Acceptance:** Run panel streams a file's output ✅; set a breakpoint and hit it ⏳ (DAP);
      run a test suite from the panel ⏳.

### Epic 4 — Cloud/prod sandbox (fly-machines provider) (`TODO`) — gap G-FLY
- [ ] Provision/attach/reap a fly Machine per `(user,workspace)`; wire egress + volume.
- **Acceptance:** with the fly provider configured, `/api/ide/*` provisions a remote sandbox
      from the deployed bridge instead of 404-ing.
- **⚠ Design finding (2026-07-20):** this is **NOT a clean drop-in** behind `ide-docker.mjs`.
  That client relies on Docker's **exec-attach hijack** — a raw bidirectional TCP upgrade
  (`POST /exec/{id}/start`) — for the PTY (`/api/ide/pty`) and LSP (`/api/ide/lsp`) relays.
  Fly Machines exposes no equivalent bidirectional exec-attach over its API. A fly provider
  therefore needs a **different terminal transport**: run a small shell/LSP-mux server inside
  the machine and connect to it over fly's private 6PN network (or a WS the machine serves),
  rather than reusing the Docker exec stream. So Epic 4 splits into: (a) a provider abstraction
  over lifecycle (create/start/stop/destroy + volume) that both Docker and fly implement, and
  (b) a transport abstraction so PTY/LSP work over either the Docker hijack **or** an in-machine
  server. (b) is the hard part. Cannot be verified without a Fly org + deploy.

### Epic 5 — Polish (fold in opportunistically) — gaps G-SEARCH, G-GIT, G-CREATEUI, G-LSPRE, G-TERMRE, G-FSW, G-WSCAP, G-QUOTA, G-DOC
- [ ] Swap frontend `browserSearch` → container `POST /api/ide/search`.
- [ ] Richer git (branch/diff/stash); unify the sidebar create-file UI with the Explorer.
- [ ] LSP + terminal reconnect; fs-watch rename events + debounce; per-sandbox xfs quota.
- [ ] Fix the runbook doc-lag (§4.4).
- [ ] **Runner formatters** — `runner/server.mjs` `FORMATTERS` only covers python/c/cpp,
      but the language registry declares `gofmt`/`rustfmt`/`shfmt`/`google-java-format`. Add
      them (gofmt ships with Go; `rustfmt`/`shfmt` are one apt package each) so the Format
      button works for Go/Rust/Shell/Java, not just Python/C/C++.

---

## Appendix — Plane B activation (ready-to-run)

The three images are **already built** on the main daemon
(`osionos-ide-{egress,socket-proxy,sandbox}:latest`), so skip the runbook's build step.
Only the `sudo` half remains (second Docker daemon). Run from the repo root; the
authority is `infrastructure/docker/osionos/ide-sandbox/README.md`.

```sh
# 1. Loopback data-root (ext4; use mkfs.xfs + mount -o loop,pquota for per-sandbox quota):
sudo fallocate -l 24G /var/lib/docker-ide.img
sudo mkfs.ext4 -q -O quota -E quotatype=prjquota /var/lib/docker-ide.img
sudo mkdir -p /var/lib/docker-ide
sudo mount -o loop,prjquota /var/lib/docker-ide.img /var/lib/docker-ide
echo '/var/lib/docker-ide.img /var/lib/docker-ide ext4 loop,prjquota,nofail 0 0' | sudo tee -a /etc/fstab
# 2. Isolated daemon:
sudo cp infrastructure/docker/osionos/ide-sandbox/docker-ide.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now docker-ide
# 3. Scoped egress NAT:
sudo sh infrastructure/docker/osionos/ide-sandbox/ide-egress-nat.sh up
# 4. Filtering socket-proxy (main daemon → /run/docker-ide.sock):
COMPOSE_PROFILES=ide docker compose up -d osionos-ide-socket-proxy
# 5. Seed the pre-built images + networks into docker-ide:
sudo sh infrastructure/docker/osionos/ide-sandbox/bootstrap.sh
# 6. HOSTILE-CORPUS GATE — must print 15 PASS before enabling:
sudo sh infrastructure/docker/osionos/ide-sandbox/verify.sh
# 7. Flip the bridge double-gate, then recreate the bridge:
#    add to ./.env.local:  OSIONOS_IDE_SANDBOX=1
#                          OSIONOS_IDE_DOCKER_HOST=osionos-ide-socket-proxy:2375
#                          OSIONOS_IDE_EGRESS_GIT_HOSTS=github.com
docker compose --env-file ./.env.local up -d osionos-bridge
```

After step 7: open a workspace in IDE mode → the terminal (`bash -l`), multi-language LSP
(go/rust/c/cpp/ts/python), bidirectional file-sync, and git all come alive. The reaper
starts automatically (self-gated until now).

## Changelog

- **2026-07-28 (f)** — **Phase 3 slice 1: the terminal became a real daily-driver
  surface.** (1) Bridge-OWNED PTY sessions (`ide-term-sessions.mjs`, in BOTH bridge
  Dockerfile COPY lists): the bridge holds the docker exec; browser sockets attach/
  detach; a reload reattaches to the SAME shell — history, cwd, running process — with
  a 256KiB replay ring painted first. Opening a terminal AUTO-PROVISIONS the sandbox
  (`ensureSandbox` shared with /api/ide/session; the dead-route era is over), the
  reaper's activity signal is session-aware (attached clients or output within 30min),
  and DELETE /api/ide/session disposes sessions. Frontend reconnects with backoff on
  network drops (deliberate closes stay closed, reason printed); `term.reset()` before
  replay so nothing doubles. (2) The VS Code bottom dock: Terminal / Problems / Output /
  Debug Console / Ports — terminal stays mounted across tab switches; Output carries
  fs-sync/terminal/conflict events (with a conflict badge); Ports lists sandbox TCP
  listeners via the new `/api/ide/ports` (`ss -tln`, list-only — forwarding needs the
  session proxy); Debug Console is an HONEST placeholder until DAP. Gates: bridge
  113/113 (full session lifecycle vs fake duplex), canvas 878/878, quality clean, IDE
  e2e 6/6 (new ideDock spec; cold-compile timeout bumps matched to the house pattern).

- **2026-07-28 (e)** — **Phase 2 slice 3: the sync engine got honest.** Silent
  last-writer-wins is GONE: inbound sandbox writes go through a three-way decision
  (`ideSyncEngine.decideInboundWrite` — echo / ignore / create / fast-forward /
  CONFLICT) against a session ledger of last-agreed hashes (recorded on outbound
  writes AND echo confirmations); conflicts keep the LOCAL content, surface in the
  status bar, and resolve one-click in an editor banner (Keep mine / Take sandbox).
  `useIdeFsSync` rewrote onto the VFS facade (`resolveFacadePath` — the per-event
  index rebuild from RECON §2 is gone) and now PUBLISHES raw agent events on a
  per-workspace bus; `sandbox://` `watch()` rides that bus (capability native when
  fed — one fsync socket, many watchers). Search migrated to a VFS walk
  (`vfsSearch` over the osionos:// mount — works over any future mount);
  `browserSearch.ts` deleted. Gates: canvas 875/875 (sync matrix + bus + watch
  scoping + search), bridge 107/107, quality clean, IDE e2e 4/4. Deferred by
  choice: explorer stays the reactive store view until the Phase 3 multi-root
  dock; bidirectional deletes/renames through SyncLink land with it.

- **2026-07-28 (d)** — **Phase 2 slice 2: the write-only sandbox hole is closed.** The
  bridge grew argv-safe VFS exec ops (`/api/ide/fs` + `op: read/list/stat/mkdir/delete/
  rename/write`; legacy no-op writes untouched; write is now ATOMIC via temp+mv), specs
  written busybox+debian-portable with tagged `VFSERR:` errors parsed client-side into
  the taxonomy. New `sandbox://` provider (injected transport) passes the SAME
  conformance corpus through a REAL local sh in the canvas suite — the exact scripts a
  live sandbox runs, proven without a stack. `PageFacade` went lazy (`readContent`), the
  real `usePageStore` adapter landed (`pageStoreFacade`), and `materialize` became the
  first SyncLink consumer (`mirrorTree` over two providers, echo-hash hook preserved,
  caps reported as counts). Gates: canvas 871/871 (corpus ×4 targets + synclink), bridge
  107/107, quality clean; live bridge probe: op route mounted, auth-first. Remaining for
  slice 3: explorer/search/fsync-index onto the mount table, bidirectional SyncLink with
  surfaced conflicts, provider.watch over the fsync stream.

- **2026-07-28 (c)** — **ADRs approved; Phase 2 (VFS core) begun. Two requirements added
  by the owner:** (1) the bottom strip must grow into a full VS Code-style dock —
  Terminal / Problems / Output / Debug Console / Ports as writable tabs (Phase 3 UI
  target; Problems moves/mirrors from the side panel, Output = runner/LSP/fsync logs,
  Ports = sandbox port map); (2) host integration is first-class: the same IDE must run
  over the real OS filesystem (Linux/Windows/macOS) via a `file://` provider under the
  Electron/Tauri shells, with POSIX-style presentation everywhere — recorded as an
  addendum in ADR-001; the conformance suite is the drop-in contract.

- **2026-07-28 (b)** — **Phase 0/1 of the daily-driver engagement + the approved hotfix
  batch.** Recon (`docs/ide/RECON.md`) and the three ADRs + interface spec
  (`docs/ide/ADR-00{1,2,3}-*.md`, `docs/ide/interfaces/ide-interfaces.ts`) landed in the
  monorepo root: VFS = mount-table over BOTH stores with an explicit SyncLink (page tree
  stays the workspace-default mount); terminal = bridge-owned sessions with replay ring on
  the existing byte-transparent transport; language layer = one manifest, all six existing
  registries become projections. Hotfixes (all with unit tests where a pure seam exists):
  LSP mux-header desync fixed by demuxing docker's non-TTY stream in the bridge (NOT
  Tty:true — a PTY would cook protocol bytes); strict full-frame resize parse (paste can
  no longer trigger it); reaper is activity-aware via a live per-container exec registry
  (soft 4h idle / hard 12h — no mid-terminal guillotine; bridge restart degrades to
  age-only); WS auth moved off the query string onto `Sec-WebSocket-Protocol`
  (`osio-token.<jwt>`, query fallback kept one transition); Origin allowlist enforced on
  upgrade (same predicate as REST CORS); all upgrade failures now answer with HTTP status
  pre-handshake or WS close code+reason post-handshake (4001/4004/4008/4013/4029) and the
  terminal prints the reason; `/api/ide/{git,search,fs}` gate-check precedes the method
  check (no route-disclosing 405 when disabled); `/api/ide/fs` got its own rate bucket
  (120 cap / 20 rps) so a 500-file materialize takes seconds instead of 429ing at 60,
  and materialize failures are counted + surfaced; fsync auto-reconnects with 1s/4s/15s
  backoff instead of dying silently; **Ctrl+`** toggles the terminal strip. New tests:
  `tests/bridge/ide-exec-parse.test.mjs` (resize/auth/demux/close-frame/handshake-echo),
  `tests/bridge/ide-reaper.test.mjs` (reap predicate), ops gate-order regression test.

- **2026-07-28** — **Regression found + fixed: the IDE vanished after a workspace teardown
  + `make all`.** Three-part cause: (1) the root `frontends-up --build` rebakes osionos-app
  with `VITE_OSIO_IDE` interpolated from `./.env.local`, where it was never set (it lived
  only in the app `.env` used by `make update_web`) → the rebuilt bundle compiled the whole
  IDE surface out; (2) the `runner` / `ide` compose profiles are outside `make all`, so the
  teardown removed `track-binocle-osionos-runner` + `osionos-ide-socket-proxy` and nothing
  restarted them; (3) bridge gates survived (they live in `./.env.local`) and the host
  `docker-ide` daemon stayed active/enabled. Fixes: `VITE_OSIO_IDE=1` added to
  `./.env.local` (so every root rebake keeps the UI), and `frontends-up` now resurrects the
  two plane containers — gated on `./.env.local` recording them as activated
  (`OSIONOS_RUNNER_URL` / `OSIONOS_IDE_SANDBOX=1`), so fresh machines/CI still start
  nothing (ships-off-by-default preserved).

- **2026-07-21 (f)** — Two follow-ups. (1) **Migration runner** —
  `scripts/apply-models.sh` (checksum ledger: adopt existing schema, apply only new/changed,
  never blindly replay order-sensitive migrations) + `make apply-models` (wired into
  `make all`) + `make apply-models-check` gate (shellcheck-clean; gate proven to catch a
  planted pending migration). Adopted the current live schema (34 files). (2) **Interactive
  Run** — in IDE mode the Run button now executes the file in the real sandbox PTY
  (`terminalRunBus`), so `input()`/stdin work instead of EOFError. **Playwright-verified**:
  `/api/ide/session` provisions (HTTP 200) and an interactive `input()` program over the
  live PTY prompts + reads input + prints the result. Commits: root `05c4be3d`; osionos
  `16b194c0`.
- **2026-07-20 (e)** — **Fixed the real root cause of "can't create a dev page."** The
  `notifyCreateFailure` fix exposed a live `400 23514 check_violation`: the
  `osionos_pages_surface_check` constraint lacked `'code'`. The fix migration existed
  (`models/osionos-code-surface-migration.sql`) but was never applied — applied it to the
  live DB (constraint now includes `code`). **Verified with dockerized Playwright** against
  the live stack (website login → osionos → bridge): `surface='code'` create → **HTTP 201**
  (was 400), control `surface='page'` → 201; probe pages cleaned up. Logged the process gap
  G-MIGRUN (no auto-apply for `models/*.sql`).
- **2026-07-20 (d)** — **Plane B activated.** Host prep (isolated `docker-ide` daemon,
  data-root, egress NAT, socket-proxy, egress proxy) was already in place from a prior
  session; re-seeded the new toolchain sandbox image, `verify.sh` **15/15**, added the
  bridge double-gate to `.env.local` + app `.env`, recreated the bridge. Verified daemon
  reachability, socket-proxy `/_ping 200`, control-net membership. The powerful terminal +
  multi-language LSP + live-sync + git are now live behind `/api/ide/*`.
- **2026-07-20 (c)** — Epic 3 Run panel shipped live (`IdeRunPanel`, quality green, in the
  bundle). Epic 4 (fly) assessed → design finding recorded (not a drop-in; exec-attach
  transport gap). Pre-built the three Plane B images on the main daemon so activation is
  sudo-only; added the ready-to-run activation block above. Committed: osionos `b3f6d23d`
  (core) + `d1855c8c` (Run panel); root `b883403e` + `d5f18d4e` (no co-author trailer,
  unpushed, pre-existing WIP untouched).
- **2026-07-20 (b)** — Epics 0–2 landed + verified.
  - **Plane A activated (live):** `VITE_OSIO_IDE=1` baked (compose build-arg →
    `app.Dockerfile` `.env.production.local`; verified `VITE_OSIO_IDE:"1"` in the bundle),
    app rebuilt (`make update_web`), runner up (`OSIONOS_RUNNER_URL`), bridge rewired. All
    **13 languages verified running** through the runner.
  - **Silent-create bug fixed** (`notifyCreateFailure`, extracted to
    `src/store/pageCreateFeedback.ts` so it's canvas-testable without the api/client graph
    that strip-types can't load; +2 tests, 827/827 canvas green).
  - **Reaper wired** (`startBridgeServer`, guarded `unref()` interval; 89/89 bridge tests).
  - **Runner `/work` noexec bug fixed** — compiled languages couldn't exec their binary;
    made `/work` exec-able. c/cpp/go/rust/java now run.
  - **Languages + LSP:** runner got the 6 missing toolchains; sandbox image got
    gcc/g++/clang/make/rustc/cargo/jdk + modern Go (tarball) + gopls/rust-analyzer/clangd
    (binaries verified in-image); `go`/`gofmt` symlinked for the `bash -l` shell; bridge
    `LSP_SERVERS` + frontend `lspClient.ts` extended for go/rust/c/cpp. Gates green (tsc,
    eslint, style, 827 canvas, 89 bridge). Sandbox runtime behavior pends Plane B activation.
  - **Still open:** Plane B live activation (needs operator sudo — see the runbook), Java
    LSP (jdtls), Epic 3 (debugger/tests/tasks), Epic 4 (fly provider).
- **2026-07-20 (a)** — File created. Reconciled the three label axes into §4, catalogued
  gaps in §5, laid out the four-track roadmap in §6. Grounded in a full file:line audit of
  the frontend (`src/features/ide/`, `src/widgets/ide-shell/`), the bridge IDE modules
  (`scripts/bridge-ide-*.mjs`), the infra plane
  (`infrastructure/docker/osionos/{runner,ide-*,ide-sandbox}/`), and the runbook.
