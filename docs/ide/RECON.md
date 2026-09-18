# RECON — osionos IDE Surface (Phase 0)

> Mission-brief Phase 0 deliverable. Read-only reconnaissance; no code was changed.
> Evidence style: `file:line` against monorepo root `/home/dlesieur/Documents/groot`
> (the osionos app is the submodule `apps/osionos/app`; paths below abbreviate it as `app/`).
> Compiled 2026-07-28 from four parallel file:line audits (frontend, bridge, infra, tests)
> plus the living record `IDE-BACKLOG.md` (last reconciled 2026-07-28).

---

## 0. Context slots (filled)

- **Repo root:** `/home/dlesieur/Documents/groot` — a Docker-first monorepo. The IDE spans
  TWO repos: the osionos app submodule (`apps/osionos/app` — frontend + bridge) and the root
  repo (`infrastructure/docker/osionos/` — runner, sandbox, proxies; compose wiring).
- **What osionos is:** a Notion-like block editor where a document is a tree of blocks,
  persisted through an `osionos-bridge` onto a self-hosted BaaS (grobase). The IDE extends
  that substrate: a code file is a page (`surface:"code"`), a folder is a page, and a
  workspace can flip into a VS Code-style shell. Two execution models sit behind it: a
  stateless runner (Plane A) and a persistent per-`(user,workspace)` sandbox (Plane B).
- **Current IDE surface:** web app — React 18 + Vite + zustand + **CodeMirror 6** editor +
  **xterm.js** terminal, mounted as a lazy `IdeShell` (`app/src/app/App.tsx:366`). Electron
  and Tauri shells exist for osionos generally but the IDE is the web surface.
- **Existing terminal:** NOT a stub — real PTY: xterm.js ↔ binary WebSocket frames ↔
  `docker exec /bin/bash -l` in the sandbox (`app/src/features/ide/ui/IdeTerminal.tsx:14`,
  `app/scripts/bridge-ide-exec.mjs:100`). Plus a second, unrelated `<pre>`-based
  "RunConsole" for one-shot runs (`app/src/features/ide/ui/RunConsole.tsx:37`).
- **Language of the core:** TypeScript (frontend) + Node ESM (bridge). Infra: sh + Dockerfiles.
- **Build:** dockerized pnpm via `app/scripts/docker-run.sh` (no host node). Dev run: root
  `make all` / `make update_web`. Test: `docker-run.sh test-canvas | test-bridge | test-e2e | quality`.
- **Target host platforms:** Linux x86_64 self-host today (Plane B needs an operator-prepped
  second Docker daemon; `rust-analyzer` fetch is amd64-only —
  `infrastructure/docker/osionos/ide-sandbox/Dockerfile:51`). fly-machines is deferred (Epic 4).
- **FS backends that must eventually plug in:** today there are exactly two, hard-wired:
  the **page tree** (BaaS; files ARE pages) and the **sandbox POSIX volume**. The brief's
  list (osionos-native, POSIX, Windows/NTFS, mem, overlay, remote) is confirmed as the
  target set; mem + overlay double as conformance-suite backends.
- **Hard non-goals (proposed — confirm):** no themes/marketplace/settings-UI/collab (§9);
  no Windows *host* support this engagement (the sandbox is a Linux container; Windows
  enters as a future FS backend, not a host); auth stays the existing bridge session tokens.

---

## 1. Architecture as it exists

### Process topology

```
browser (React IdeShell, xterm.js, CodeMirror, zustand)
   │  HTTPS/WSS (:4000)
osionos-bridge (Node, app/scripts/bridge-api.mjs — REST + one WS upgrade handler)
   │  ├── SSE proxy ──────────► osionos-runner :7900   (Plane A, main daemon,
   │  │                          internal-only net, no volume, sh -c per run)
   │  └── Docker Engine API ──► osionos-ide-socket-proxy :2375   (main daemon)
   │                                │ allowlisted HTTP → unix socket
   │                                ▼
   │                          docker-ide (SECOND dockerd, --data-root /var/lib/docker-ide,
   │                                userns-remap, bridge=none, 10.202/16)
   │                                ├── sandbox ide-<32hex>  (debian, uid 10001, RO rootfs,
   │                                │     /workspace volume, sleep infinity; exec: bash -l,
   │                                │     LSP servers, node fs-agent)
   │                                └── ide-egress (CONNECT-only :8080, allowlist, NAT out)
   └── BaaS (grobase) — pages, blocks, auth   ◄── the OTHER filesystem
```

- **Gates (three, independent):** frontend flag `osio.ide`
  (`app/src/shared/config/featureFlags.ts:174`, baked via `VITE_OSIO_IDE`); per-workspace
  IDE mode (`app/src/features/ide/model/ideModeStore.ts:46`); bridge double-gate
  `OSIONOS_IDE_SANDBOX=1` + `OSIONOS_IDE_DOCKER_HOST` (+ `OSIONOS_RUNNER_URL` for Plane A),
  compose profiles `runner`/`ide` (`docker-compose.yml:131,638`).
- **IPC inventory:** REST `POST /api/ide/{run,format,git,search,fs,session}`; WS upgrades
  `/api/ide/{pty,lsp,fsync}` — one handler (`app/scripts/bridge-ide-exec.mjs:60`), hand-rolled
  RFC6455 (`app/scripts/ide-ws.mjs`), binary frames, 1 MiB/message cap, no deflate.
- **PTY data path is byte-transparent** (a genuine strength): container bytes → binary WS
  frames unmodified (`bridge-ide-exec.mjs:106`) → `term.write(Uint8Array)`
  (`app/src/features/ide/model/useIdeTerminal.ts:63`). Resize is out-of-band via APC magic
  `\x1b_osio-resize:` (`bridge-ide-exec.mjs:36`); Ctrl-C is a plain 0x03 keystroke (TTY line
  discipline does the rest). Backpressure server→client exists (`:106-108`); client→stdin
  does not. Scrollback is client-only (5000 lines); no replay on reconnect — and there is
  **no reconnect** (`useIdeTerminal.ts:36`).
- **Run button routing** (`app/src/features/ide/ui/CodeFileView.tsx:83-104`): IDE-mode +
  runnable language → write file, then dispatch `lang.runCmd` into the PTY via a one-slot
  bus (`terminalRunBus.ts:32`). Otherwise → one-shot SSE runner (no stdin by design;
  `runner/server.mjs:30` ponytail note). `IdeRunPanel.tsx:56` always takes the one-shot
  path and runs the *saved* (up to 1200 ms stale) content.
- **Build graph:** IDE ships as a lazy chunk (`app/src/app/lazyAppRegions.tsx:45`); xterm is
  a second-level lazy inside it (`IdeBottomStrip.tsx:17`). The editor area **reuses the main
  `WorkspaceGrid`** — no forked tab system (`IdeShell.tsx:61`).

### Security architecture (Plane B) — solid bones, verified design

Server-derived everything: names/volumes are `sha256(userId:workspaceId)` slices
(`app/scripts/ide-sandbox-spec.mjs:41-49`); client strings reach Docker only as argv items
(git allowlist `:112-131`, rg after `--` `:146`, write path+base64 `:155-164`). Socket-proxy
allowlists 12 endpoint shapes, pins container paths to `ide-[0-9a-f]{32}`, vets create
bodies (no Privileged/Binds/CapAdd/bind-mounts/host namespaces)
(`infrastructure/docker/osionos/ide-socket-proxy/proxy.mjs:35-72`). Egress: CONNECT-only,
443-only, host allowlist, resolved-IP revalidation dialing the validated literal IP
(`ide-egress-proxy/proxy.mjs:91-121`). Sandbox: uid 10001, CapDrop ALL, RO rootfs, 1 GiB /
1 CPU / pids 512 (`ide-sandbox-spec.mjs:56-96`).

---

## 2. Filesystem access inventory (every site + its assumptions)

**There are two filesystems and neither is authoritative.**

### Plane 1 — the page tree (BaaS). A file IS a page.

All ops go through `usePageStore` actions (outbox/ledger/ACL for free):
create file/folder, rename (re-infers language), archive-as-delete, move, import, export —
`app/src/features/ide/model/useIdeFileOps.ts:34-106`; editor writes are debounced 1200 ms
block updates (`CodeFileView.tsx:154`); reads are `fetchPageContent`. Works offline; no
sandbox needed. Drag-move via MIME `application/x-osio-ide-page` (`IdeTreeRow.tsx:44`).

### Plane 2 — the sandbox volume (bridge `/api/ide/*`)

| Op | Exists? | Site |
|---|---|---|
| write | ✔ `POST /api/ide/fs` (base64 → `sh -c` argv) | `ideFsClient.ts:20` → `ide-sandbox-spec.mjs:164` |
| watch (inbound) | ✔ WS `/api/ide/fsync` ← node fs-agent, NDJSON, base64 content | `useIdeFsSync.ts:124` ← `osio-fs-agent.mjs:97` |
| read / list / stat / delete / rename / mkdir | **✘ none** | — |

**The sandbox FS is write-only from the app.** Reads exist only as pushed watch events.

### Path semantics (the leaks the brief predicts, already present)

- Paths are **strings, `/`-joined, derived from page titles** — never stored. `pathForPage`
  walks ancestors with a cycle guard (`idePaths.ts:28-38`). `sanitizeSegment` (`:46-56`)
  replaces `/` and `\` with **spaces**, collapses `..+`→`.`, control chars→space — so two
  titles can silently collide on one sandbox path (first-wins, no report).
- **Three consumers must agree byte-for-byte** on that sanitization: materialize
  (`materialize.ts:31`), LSP URIs (`CodeFileView.tsx:231` → `file:///workspace/<rel>`), and
  the fsync reverse index (`useIdeFsSync.ts:38`). A drift in one desyncs the others.
- Server re-validates independently (rejects `..`, leading `/`) — `ide-sandbox-spec.mjs:155`.
- One place shell-interpolates a path (single-quote escaped) instead of argv:
  the PTY run command (`CodeFileView.tsx:93`).
- Encoding: UTF-8 assumed throughout; hashes are `sha256(bytes).slice(0,16)` on both ends
  (`ideFsEcho.ts:25`, `osio-fs-agent.mjs:54`); LSP framing counts bytes not chars
  (`lspFraming.ts:25`). No NFC/NFD handling anywhere; no non-UTF-8 name handling.
- **Sync model = echo-suppression + last-writer-wins.** Local writes record a 15 s hash TTL
  (`ideFsEcho.ts:21`); inbound events matching are dropped; otherwise
  `block.content !== content → updateBlock` (`useIdeFsSync.ts:107`). No merge, no conflict
  surface. fs-agent has no rename event (delete+write), no debounce, 512 KiB file cap;
  binary/oversized arrive as `content:null` and are silently skipped (`useIdeFsSync.ts:101`).
- **Caps that bite silently:** materialize 500 files (`materialize.ts:18`) charged against a
  60-token bucket refilling 1/s (`bridge-ide-ops.mjs:63`) — materializing >60 files 429s and
  `ideFsWrite` returns `false` with **no user signal** (`ideFsClient.ts:31`).
- The reverse index `Map<relPath,…>` is rebuilt **on every single fsync event**
  (`useIdeFsSync.ts:29-35`).

---

## 3. Language/file-type hardcodes (the registry sprawl)

Six-plus independent tables; adding one language today touches up to five repos/files:

1. **`IDE_LANGUAGES`** — 35 records × 5 axes (extensions, CodeMirror loader, accent color,
   runCmd, formatterId): `app/src/features/ide/model/ideLanguages.ts:63-135`; derived
   `BY_ID`/`BY_EXT` `:147-149`; dotless names → whole-name language (`Dockerfile`) `:157-161`.
2. **Frontend LSP maps** — `LSP_SERVER` + `LSP_DOC_LANG` (`lspClient.ts:23-37`; the
   `tsx`/`jsx` keys are unreachable — no such ids exist in `IDE_LANGUAGES`).
3. **Bridge LSP table** — `LSP_SERVERS`: typescript/python/go/rust/clangd
   (`app/scripts/bridge-ide-exec.mjs:40-47`). No Java despite the JDK being in the image.
4. **Runner language table** — 13 langs, pure data `{file, cmd}`
   (`infrastructure/docker/osionos/runner/server.mjs:52-66`) — *the good pattern*, plus a
   **duplicate allowlist** kept in sync by comment (`app/scripts/bridge-runner.mjs:46-52`).
5. **Formatter tables ×3** — `formatterId` axis, `BROWSER_FORMAT` (7 prettier langs),
   `RUNNER_FORMAT_LANGS={python,c,cpp}` (`formatCode.ts:40-55`) mirroring the runner's own
   3-entry table (`server.mjs:71-75`).
6. **Two more registries outside the IDE**: block-editor picker, 55 names
   (`app/src/features/block-editor/ui/BlockEditor.tsx:78-88`) and highlight.js loader maps,
   52 grammars + 40 aliases (`app/src/shared/ui/molecules/CodeSyntaxHighlight/highlighter.ts:23-86`).

Toolchain reality: sandbox image ships gcc/g++/clang/make/rustc/cargo/JDK/go(tarball)/node/
python + typescript-language-server@4, pyright@1, gopls@latest (unpinned), rust-analyzer
latest (unpinned, amd64-only), clangd (`infrastructure/docker/osionos/ide-sandbox/Dockerfile:19-53`).

`surface` branching sites (the file-vs-page seam): `ideFileTree.ts:24`, `browserSearch.ts:47`,
`idePaths.ts:32`, `useIdeFileOps.ts:58`, `IdeRunPanel.tsx:37`, `PaneContent.tsx:75`,
`PageTreeItem.tsx:154`, type union `app/src/entities/page/model/types.ts:75`.

---

## 4. What works / what is stubbed / what is dead

**Works end-to-end (verified live or e2e-proven):** IDE mode toggle + shell; explorer CRUD
(page-backed, offline-capable); import folder / export zip; CodeMirror editing with
debounced save; client-side search; browser Prettier (7 langs); one-shot run (SSE, 13 langs);
PTY run path (write-then-dispatch bus); LSP framing + diagnostics→Problems; git
status/commit/push with request-scoped PAT; the whole Plane B isolation stack
(verify.sh 15/15 on this host).

**Stubbed / partial:** status bar git branch is a literal `—` (`IdeStatusBar.tsx:36`);
Problems/Search open the file but **discard line/column** (`IdeProblemsPanel.tsx:60`,
`IdeSearchPanel.tsx:56`); no debugger/tasks/test-runner (`IdeRunPanel.tsx:29`); git panel has
no branch/stash/diff; sidebar "New code file" still uses `globalThis.prompt`
(`SidebarPageTree.tsx:391`).

**Dead / unreachable:** **`POST /api/ide/session` has zero callers** — the app cannot
provision its own sandbox; every transport merely attaches and 409s/"No running sandbox"
when absent (`bridge-ide-sandbox.mjs:69` defined; grep of `src/` finds nothing; SCM panel
says "Start it, then reopen this panel" with no start affordance, `IdeSourceControl.tsx:32`).
Container ripgrep search `/api/ide/search` implemented, never called (UI uses the in-memory
grep). `ensureNetwork` dead (`ide-docker.mjs:75`). `tsx`/`jsx` LSP keys unreachable.

**Latent defects found statically (not yet fixed — listed for the ADR/fix queue):**

- **LSP exec spec omits `Tty:true`** (`bridge-ide-exec.mjs:52`) — Docker multiplex headers
  can land mid-stream and desync the frontend's Content-Length deframer
  (`lspFraming.ts:43`); every other exec spec sets Tty for exactly this reason
  (`ide-sandbox-spec.mjs:185`).
- Resize APC magic is 14 bytes (comment claims 20); a paste containing it triggers a
  spurious resize (`bridge-ide-exec.mjs:120`).
- Reaper is **max-lifetime (4 h), not idle** — it kills a terminal mid-use
  (`bridge-ide-sandbox.mjs:135-152`).
- `405-before-404` on `/api/ide/{git,search,fs}` discloses route existence with the IDE
  disabled (`bridge-ide-ops.mjs:76-77`); WS auth token travels in the query string
  (`bridge-ide-exec.mjs:69`); **no Origin check** on WS upgrade (`:58-80`).
- Materialize silently under-writes on 429 (see §2); fsync socket death is invisible
  (no onerror/onclose — `useIdeFsSync.ts:124-145`).
- All exec-path failures collapse to `socket.destroy()` with no close code and no log
  (`bridge-ide-exec.mjs:73-132`); ops errors leak raw upstream text
  (`bridge-ide-ops.mjs:102`). No error taxonomy anywhere.

**Infra/doc drift (runbook vs files):** README says rootless daemon ×6 sites — it is rootful
with userns-remap (`docker-ide.service:32-43`); "16-condition corpus" — verify.sh has 15;
egress NAT script is **wired to nothing** (reboot loses NAT until re-run,
`ide-egress-nat.sh:25`); `HTTP_PROXY` is set but the proxy is CONNECT-443-only so plain-HTTP
fetches fail at the proxy (`ide-egress-proxy/proxy.mjs:37,106`); socket-proxy claims
non-root in its own Dockerfile but has no `USER` directive and a RW socket mount
(`ide-socket-proxy/Dockerfile:3`, `docker-compose.yml:647`); sandbox volumes have **no
reclaim path** through the proxy (no `DELETE /volumes/*`); ~10 `OSIONOS_IDE_*` env keys are
registered in neither `.env.example` nor the Makefile.

---

## 5. Test infrastructure — what exists and whether it runs

| Layer | Size | Runs? | IDE coverage |
|---|---|---|---|
| canvas (`node --test`, in-Docker) | ~814 tests / 125 files | **Not in CI at all**; no local run artifacts | 26 tests: languages, tree, file-ops, fsync hashing/echo, LSP framing, create-error toast |
| bridge (`node --test`) | 89 tests / 15 files | **Not in CI at all** | 22 tests — but **only the runner's SSE path is exercised end-to-end**; sandbox/ops tests stop at the auth/gate layer |
| e2e (Playwright, own Vite, offline) | ~411 tests / 69 specs | CI 6-shard matrix exists; last local artifact = a 2-test run (2026-07-19) | **4 tests, 2 files** (`ideMode`, `ideWorkspace`): create/rename/search only |
| selfchecks | ws codec, fs-agent, both proxies | manual / `verify.sh` (needs sudo + live plane) | the only coverage the PTY/proxy trust boundary has |

**Zero automated tests exist for:** the PTY end-to-end (bridge-ide-exec is imported by no
test), fsync backend, LSP transport, `ide-docker.mjs`, `ide-ws.mjs` (self-described "trust
boundary — bytes flow to a shell's stdin", `ide-ws.mjs:17`), terminal UI, run-with-stdin,
delete/move/import/export via UI, SCM panel, Problems panel, formatting, multi-tab, watcher
round-trip, debugger (doesn't exist).

**Corpus-rule violations already present** (brief §6): 33 `waitForTimeout` calls (~19 s of
sleeps); 30 serial describes sharing one page/context (state bleed by design); `retries: 0`
with two specs opting into `retries: 2` (a flake marker); 12 env-gated `test.skip`s that
report green in default CI; screenshot specs with no `toHaveScreenshot` (cannot fail);
**no Playwright projects at all** (the FS-backend matrix requires a projects rework); no
fixtures/globalSetup; `tests/README.md` contradicts the actual CI workflow; CI's stated
test count is stale; canvas+bridge (903 tests) are gated by nothing.

---

## 6. The five biggest structural obstacles

1. **Two filesystems, no source of truth, write-only visibility.** The page tree and the
   sandbox volume are stitched by title-derived lossy paths, hash echo-suppression, and
   last-writer-wins. The app cannot even read/list/stat/delete on the sandbox side. The
   brief's VFS is not a refactor of one FS layer — it must either unify two stores with
   different semantics behind one mount table, or declare one authoritative and demote the
   other to a projection. This is ADR-001's core decision, and everything else (LSP URIs,
   terminal CWD, watcher, conformance suite) hangs off it.
2. **No lifecycle: nothing provisions, nothing reconnects, the reaper kills live sessions.**
   `/api/ide/session` is a dead route; sandboxes exist only if an operator made one. PTY
   and fsync die silently with no reconnect/replay; the 4 h max-lifetime reap guillotines
   an active terminal. "The IDE disappeared" as experienced by the user is largely this
   obstacle plus the env-gate bake (fixed 2026-07-28, see IDE-BACKLOG changelog).
3. **Language knowledge in ≥6 unsynchronized registries.** The runner's pure-data table is
   the right embryo, but the same fact (what is Python, how to run C) lives in the frontend
   registry, two LSP maps, a duplicated runner allowlist, three formatter tables, and two
   non-IDE highlight registries. The brief's manifest model requires collapsing these into
   one data source consumed everywhere — the diff is wide but mostly mechanical.
4. **The trust boundary is test-free and the E2E scaffolding contradicts the corpus rules.**
   Every byte a user types traverses code with zero automated tests (ws codec, exec glue,
   docker client), and the existing Playwright shape (no projects, sleeps, serial state
   bleed, ungated unit suites) cannot express the backend-matrix corpus without structural
   work. Phase 5 is not "add tests" — it is "rebuild the harness contract first".
5. **Single-host operational coupling with documented drift.** Plane B assumes a manually
   prepped second daemon on this exact host (systemd unit, NAT script wired to nothing,
   unpinned amd64-only toolchain fetches, unregistered env keys, runbook that contradicts
   the implementation in six places). Until provisioning/teardown/e2e-bootstrap is scripted
   and CI-visible, every machine event (reboot, teardown, fresh clone) silently degrades
   some part of the IDE — this week produced three live instances of exactly that.

---

## Appendix A — ponytail-debt ledger (IDE tree)

- `app/scripts/bridge-ide-exec.mjs:20` — no unit test for the exec glue. ceiling: live-only
  verification. upgrade: test with fake docker duplex. **(= obstacle 4)**
- `app/scripts/bridge-ide-exec.mjs:120` — paste containing resize magic triggers false
  resize. ceiling: cosmetic mis-resize. upgrade: length+terminator validation.
- `app/scripts/ide-ws.mjs:19` — no deflate, no >1 MiB streaming. ceiling: large paste
  rejected. upgrade: fragment outbound frames.
- `infrastructure/docker/osionos/runner/server.mjs:30` — one-shot runner has preset-stdin
  only, no live stdin. ceiling: `input()` EOFs on Plane A. upgrade: per-run id + ACL
  (superseded in practice by the PTY run path).
- `app/scripts/bridge-api.mjs:2866` — identity-only connection store; encrypted-token
  storage deferred until a provider needs it. (adjacent, not IDE-core)

5 markers, 1 with no trigger (the bridge-api one names the trigger loosely). Non-IDE
markers in the same files (`bridge-feed.mjs:146`, `bridge-tasks.mjs:68`) excluded.

## Appendix B — evidence trails

Full per-file audits (module maps, endpoint tables, isolation matrices, test-by-test
coverage) were produced by four scoped read-only audits on 2026-07-28 and are summarized
above; the authoritative live design record remains `IDE-BACKLOG.md`, whose §5 gap table
(`G-*`) this recon confirms and extends. Key IDE-BACKLOG cross-refs: `G-LSP` (Java),
`G-SEARCH` (dead rg route), `G-FSW` (fs-agent limits), `G-TERMRE` (no PTY reconnect),
`G-DOC` (runbook drift).
