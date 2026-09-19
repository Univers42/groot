# groot — restore the IDE sandbox, compile C in it, replace CodeMirror with Monaco

> This file is a self-contained handoff prompt for another AI agent. Whoever
> picks it up gets no other context: everything needed is below, with file:line
> evidence, measured against this VM on 2026-09-19.
>
> It ships to the repo it describes, at
> `b2b:/home/dlesieur/groot/IDE-SANDBOX-AND-MONACO-PROMPT.md`, so the agent can
> read it from inside the workspace it is about to change. It is untracked
> there — `git add` it only if you want it in the repo's history.

## Mission

You are working on **groot** (a.k.a. track-binocle / osionos), a self-hosted
web IDE + workspace app. Three outcomes, in this order:

1. **Restore the IDE sandbox plane** — the browser console currently loops
   `[terminal] session closed: sandbox unavailable` and
   `[fs-sync] disconnected — reconnecting in Ns`.
2. **Make compiling and running C work from the IDE** (Run button, interactive
   terminal, and a `tasks.json` build task).
3. **Replace CodeMirror 6 with Monaco Editor** as the IDE's code editor — a
   full replacement, not a side-by-side option — at full design parity with the
   app's palette system.

## Where the code is and how to reach it

The repo is **not on the host**. It lives inside a Debian VM reachable over
SSH as `b2b`:

```sh
ssh b2b                     # repo at ~/groot  (/home/dlesieur/groot)
```

Add `-o ClearAllForwardings=yes` to `ssh`/`scp` if an existing tunnel makes the
port-forward warnings noisy. The app is `~/groot/apps/osionos/app` (React +
Vite + TypeScript, FSD layout, pnpm 10.32.1, node 22). `node_modules` in the
host tree is **empty on purpose** — every build runs in a container via
`scripts/docker-run.sh` (`pnpm build`, `pnpm typecheck`, `pnpm lint`,
`pnpm test:canvas`, `pnpm test:e2e`).

## What has already been established (do not re-derive; do verify)

### The terminal/fs-sync failure is missing activation, not a bug

- The bridge is already gated ON. `docker inspect` of
  `track-binocle-osionos-bridge-1` shows `OSIONOS_IDE_SANDBOX=1`,
  `OSIONOS_IDE_DOCKER_HOST=osionos-ide-socket-proxy:2375`,
  `OSIONOS_RUNNER_URL=http://osionos-runner:7900`, `VITE_OSIO_IDE=1`.
- `track-binocle-osionos-ide-socket-proxy` is running, but the isolated daemon
  it proxies to does not exist: `systemctl is-active docker-ide` → `inactive`,
  no `/etc/systemd/system/docker-ide.service`, no `/run/docker-ide.sock`.
- Therefore `ensureSandbox()` rejects and
  `apps/osionos/app/scripts/bridge-ide-exec.mjs:204` closes the socket with
  code 4004 `sandbox unavailable`. fs-sync dies the same way — the proxy access
  log shows the WebSocket upgrade succeeding (`GET /api/ide/fsync… 101`) and
  the app closing it immediately after.
- An earlier, now-fixed symptom was `401 App session token signature is
  invalid` on every `/api/*` call: a stale browser session signed with a
  rotated `OSIONOS_APP_SESSION_SECRET`. Bridge and auth-gateway agree on the
  current secret; if 401s reappear, clear site data for `localhost` and log in
  again rather than rotating secrets backwards.
- The activation runbook already exists and is excellent — read it first:
  `infrastructure/docker/osionos/ide-sandbox/README.md` (§"Host prerequisites",
  §"Activation", and the 16-condition security table). Companion files in the
  same directory: `docker-ide.service`, `bootstrap.sh`,
  `install-egress-nat.sh`, `verify.sh`.

### C compilation is already implemented — it needs the services running, not new code

- `infrastructure/docker/osionos/runner/server.mjs:54` —
  `c: { file: "main.c", cmd: "gcc -O2 -std=c17 -o main main.c && ./main" }`.
  The image `dlesieur/osionos-runner:latest` (645 MB) is already pulled; the
  container is simply not up, because the `runner` compose profile is not
  enabled.
- `apps/osionos/app/src/features/ide/model/ideLanguages.ts:66` — C is
  `runnable: true`,
  `runCmd: "gcc -O2 -std=c17 -o /tmp/a.out {file} && /tmp/a.out"`,
  `formatterId: "clang-format"`.
- `CodeFileView.runNow()` already branches: in IDE-workspace mode it writes the
  file with `ideFsWrite`, then runs `runCmd` in the real PTY (so stdin works);
  otherwise it calls the stateless runner.
- `src/features/ide/model/ideTasks.ts` is a VS Code-style `tasks.json` model
  that runs commands in the PTY at `/workspace`; its header explicitly targets
  multi-file `gcc *.c` builds.
- The sandbox image installs `gcc g++ clang clangd make rustc cargo
  default-jdk-headless` (`ide-sandbox/Dockerfile:22`), and `clangd` is already
  in the bridge's LSP allowlist (`bridge-ide-exec.mjs:107`).

### Monaco replacement scope

Exactly **6 source files** import `@codemirror/*`, plus 2 test files:

| File | Lines | Role | Action |
| --- | --- | --- | --- |
| `src/features/ide/ui/CodeFileView.tsx` | 348 | the editor pane | rewrite the view layer; preserve every non-CM seam |
| `src/features/ide/ui/codeMirrorSetup.ts` | 124 | `osioEditorTheme`, `osioHighlightStyle`, `baseEditorExtensions()` | port to a Monaco theme (see Design), then delete |
| `src/features/ide/model/ideLanguages.ts` | ~130 | per-language `cmLoad()` thunks + run/format metadata | swap `cmLoad` for a Monaco language id; **keep `runCmd`, `formatterId`, `extensions`, `accent` untouched** |
| `src/features/ide/model/lspClient.ts` | 159 | `@codemirror/lsp-client` wiring, `lspServerFor()` | rewrite as a Monaco LSP adapter; keep `lspServerFor` |
| `src/features/ide/model/lspReady.ts` | 27 | `whenInitialized(client, closed)` | retype against the new client |
| `src/features/ide/model/lspFraming.ts` | 65 | Content-Length codec over the WS | **reuse unchanged** — transport-level, editor-agnostic |

Consumers/tests to update: `src/widgets/page-renderer/ui/lazyViews.tsx:101`
(`LazyCodeFileView`), `tests/e2e/functional/ideWorkspace.spec.mjs` and
`tests/canvas/ide-lsp-ready.test.ts` (they select `.cm-content` / `.cm-editor`).
`IdeProblemsPanel.tsx` + `diagnosticsStore.ts` must keep working — feed them
from `monaco.editor.setModelMarkers` instead of CM diagnostics.

`https://registry.npmjs.org/monaco-editor` is reachable from the VM (HTTP 200).
No `Content-Security-Policy` header is set by the app or its proxy, so Monaco's
web workers are not blocked.

## Hard constraints

- **Disk.** Inside the VM, `/var` is at **93% — 1.4 GB free of 19 GB**, and the
  sandbox image is ~2.8 GB. Docker holds ~8 GB reclaimable (≈4.3 GB build
  cache, ≈2.1 GB images, ≈1.6 GB volumes). The owner has approved reclaiming
  all of it, but **list dangling volumes for review before removing them**
  (`docker volume ls -qf dangling=true`). Other mounts: `/` 8.0 GB free,
  `/home` 4.0 GB free, `/opt` 1.7 GB free.
- **sudo has no tty over SSH** (`sudo -n` → "you must have a tty"). You cannot
  run the privileged steps yourself. Hand the owner an exact, copy-pasteable
  block and have them run it in a VM terminal, then verify the result yourself.
- **Do not weaken the security gates.** The isolated daemon is rootful with
  `--userns-remap`; the socket-proxy's body filter is the only thing between a
  sandbox and host root. Never disable the filter, never add `Privileged`, host
  binds or `--iptables=true`, and never skip `verify.sh`.
- **Do not `make all` or restart the whole stack** to fix one service; 28+
  `mini-baas-*` containers are healthy and carry data.
- The README's `fallocate -l 24G` **will not fit**. Size the loopback data-root
  to ~6 G, and site the backing file where there is room.

## Work plan

### Part A — prune, then the stateless runner (no sudo, no disk cost)

```sh
docker volume ls -qf dangling=true       # REVIEW with the owner first
docker builder prune -af
docker image prune -af
docker volume prune -f                   # only after the review
cd ~/groot && COMPOSE_PROFILES=runner docker compose up -d osionos-runner
docker logs track-binocle-osionos-runner   # expect "listening on :7900 — N languages"
```

Persist `COMPOSE_PROFILES=runner` (later `runner,ide`) in `~/groot/.env.local`
so a subsequent `make up` does not silently drop the profile. **Checkpoint:** a
`.c` page's Run button now compiles with gcc and prints to `RunConsole`.

### Part B — activate the sandbox plane (terminal, fs-sync, tasks, clangd)

Follow `ide-sandbox/README.md` §Activation exactly, with the 6 G deviation.

Owner-run (sudo) steps: create + mount the loopback ext4 data-root with
`prjquota` and add the `nofail` fstab line; install and enable
`docker-ide.service`; run `install-egress-nat.sh`; run `bootstrap.sh` (it seeds
images/networks into docker-ide and deletes the main daemon's 2.8 GB copy,
which is what makes 6 G workable); run `verify.sh`.

You-run steps: the three `docker build`s (egress proxy, socket proxy, sandbox),
`COMPOSE_PROFILES=ide docker compose up -d osionos-ide-socket-proxy`, and all
verification. The bridge env is already correct — no compose edit needed.

**Gate: `verify.sh` must be 16/16 green before declaring this done.**

### Part C — full Monaco replacement

Sequence it so the app is never broken for more than one commit:

1. `pnpm add monaco-editor`; wire Vite workers; keep the editor **lazy-loaded**,
   mirroring the existing `lazyViews.tsx` pattern, so Monaco (~5 MB with
   workers) never enters the warm chunk. Bundle size is the main risk here.
2. Rewrite `CodeFileView` on `monaco.editor.create()` while preserving its
   documented contract **verbatim**: the editor stays *uncontrolled* (store
   written debounced from `onDidChangeModelContent`, never pushed back into the
   editor while mounted, so the caret never jumps), rebuilt only when
   `[pageId, blockId]` changes, language swapped without a rebuild
   (`monaco.editor.setModelLanguage`, the analogue of CM's `Compartment`), and
   a pending save flushed on unmount. Reuse unchanged: `useCodeRunner`,
   `ideFsWrite`, `recordSyncedHash`, `useIdeSyncConflicts` (both resolutions
   read/replace the document), `useIdeRevealBus`, `useTerminalRunBus`,
   `pathForPage`, `canFormat`/`formatCode`, `RunConsole`.
3. Languages: Monaco ships Monarch grammars for C/C++/Python/Rust/Go/Java and
   most of the table, so nearly every `cmLoad` thunk collapses to a built-in
   id; write a Monarch definition only where no built-in exists.
4. LSP adapter: keep the existing WS transport to `/api/ide/lsp?lang=` and
   `lspFraming.ts`. Register completion/hover/definition providers and push
   diagnostics through `monaco.editor.setModelMarkers`, feeding the existing
   `diagnosticsStore.ts` so `IdeProblemsPanel` needs no change.
   `lspServerFor()` already maps languages → servers, `clangd` included.
5. Retarget the two tests to `.monaco-editor` / `.view-lines`.
6. **Remove the ~20 `@codemirror/*` dependencies last**, once 1–5 are green, so
   a rollback is a single revert.

## Design requirements (visual parity is part of "done")

The current editor is **100% CSS-variable driven**. `codeMirrorSetup.ts` reads
`--osio-code-{bg,fg,fg-muted,border,chip-bg,header-bg}`, `--osio-accent`,
`--osio-font-mono`, `--osio-danger`, and ten `--osio-syntax-*` colors. Those
tokens are defined in `src/app/styles/global.css` across **19 blocks**: a
default light/dark pair plus seven palettes — `mono`, `contrast`, `maximal`,
`nord`, `solarized`, `midnight`, `rose` — each in light and dark, selected by
`[data-palette="…"][data-theme="…"]` on the root element.

**The #1 gotcha: `monaco.editor.defineTheme()` takes literal colors and will
NOT resolve `var(--osio-…)`.** A naive port silently loses the entire palette
system. So:

- Resolve tokens at runtime —
  `getComputedStyle(document.documentElement).getPropertyValue("--osio-syntax-keyword")`.
- Normalize to `#RRGGBB` / `#RRGGBBAA`; Monaco rejects `rgba()` strings, and
  the CM theme carries three rgba fallbacks (`--osio-code-selection`,
  `--osio-code-active-line`, `--osio-code-bracket`) that must be converted.
  Promoting those three to real palette tokens in `global.css` is the cleaner
  fix and the CM file's own `ponytail:` note already asks for it.
- `defineTheme("osio", { base, inherit: true, rules, colors })`, then
  `setTheme`. **`base` must follow `data-theme`** (`vs` for light, `vs-dark`
  for dark) — note `osioEditorTheme` currently hardcodes `{ dark: true }` even
  under light palettes, which is a latent bug; do not reproduce it.
- Re-resolve and re-define on palette/theme change: a `MutationObserver` on
  `documentElement` watching the `data-theme` and `data-palette` attributes.
  Never hardcode a hex value anywhere in the editor code.

**Token mapping.** Port `osioHighlightStyle`'s 17 rules from Lezer tags to
Monaco token scopes: keyword, string, comment (italic), function
(`entity.name.function`), number, constant/literal, property, type
(`type.identifier`), tag, `attribute.name`, and `invalid` → `--osio-danger`.
Monarch emits different token names per language, so verify visually on a `.c`,
a `.ts` and a `.md` file, not just one.

**Chrome colors** go in the theme's `colors` map: `editor.background`,
`editor.foreground`, `editorLineNumber.foreground`, `editorGutter.background`,
`editorCursor.foreground` (= `--osio-accent`), `editor.selectionBackground`,
`editor.lineHighlightBackground`, `editorBracketMatch.background`/`.border`,
`editorWidget.background`/`.border`, `editorHoverWidget.*`,
`editorSuggestWidget.*`, and `editorError/Warning/InfoForeground`.

**Metrics parity** with the shipped editor: `fontSize: 13`, `lineHeight` 1.6,
the `--osio-font-mono` stack, `padding: { top: 10, bottom: 10 }` (CM used
`.cm-content { padding: 10px 0 }`), `tabSize: 4, insertSpaces: true` (CM used
`indentUnit.of("    ")`). The gutter's 1px right border in
`--osio-code-border` has no Monaco theme key — add a CSS rule on
`.monaco-editor .margin`.

**Feature posture — match what shipped, do not accept Monaco's defaults:**

- `minimap: { enabled: false }`. CodeMirror had no minimap; turning one on is
  an unrequested visual change. Make it a setting if it is wanted.
- `wordBasedSuggestions: "off"` — completion comes from LSP only. The CM base
  set deliberately excluded autocomplete, lint and the search panel ("colors
  and be able to write code, no intellisense", per the file's own comment);
  LSP is the sanctioned exception, Monaco's word-noise is not.
- `scrollBeyondLastLine: false`, `renderLineHighlight: "line"`, `folding: true`,
  bracket-pair colorization **off** (the palette owns bracket color).
- `automaticLayout: true` is **mandatory** — the IDE has dockable panels and a
  zen mode (`[data-zen="1"]` hides chrome); Monaco does not reflow on container
  resize without it, and the symptom is a half-painted editor.
- Respect `prefers-reduced-motion` (`cursorBlinking: "solid"`) and leave
  `accessibilitySupport: "auto"`.

**Lifecycle.** Dispose the editor *and* its models on unmount — React
StrictMode double-mounts in dev and leaked models are the classic Monaco memory
bug. Never recreate the editor just to change language.

**Everything outside the text surface is unchanged.** Explorer, Problems,
Terminal, Source Control, Run panel, tab strip, zen mode: you are replacing the
text surface only. Do not pull in VS Code workbench packages.

## House style (enforced by review, not by a linter)

- Source files carry a 42-school header block (see the top of `ideTasks.ts`).
  Keep it on files you create, and keep an existing one accurate when you
  change that file's behaviour.
- Comments explain **why** — the constraint, the bug, or the measurement that
  motivated the code — placed above the function or block. Read a file's header
  before editing it. The `CodeFileView` docblock and `ide-sandbox/README.md`
  set the bar.
- Conventional Commits. **Never add `Co-Authored-By` or any AI-attribution
  line** to a commit or a PR.

## Definition of done

- **A:** runner container healthy; a `.c` page runs from the Run button.
- **B:** `verify.sh` 16/16; the browser terminal opens a shell at `/workspace`;
  `gcc --version` answers inside it; `gcc -O2 main.c -o main && ./main` works;
  a `tasks.json` "build" task runs in the same PTY; the console no longer logs
  `fs-sync disconnected`; an edit in the editor mirrors into the sandbox and a
  change in the sandbox mirrors back.
- **C:** `pnpm typecheck`, `pnpm lint`, `pnpm test:canvas` and the
  `ideWorkspace` e2e spec all green; the editor renders correctly in **all 16
  palette × theme combinations** and follows a live palette switch; manual pass
  on the preserved behaviours — caret does not jump while typing, switching
  panes does not drop the last keystrokes, the sandbox-divergence banner still
  offers both resolutions, and the Problems panel populates from clangd on a
  `.c` file.

## Working rules

- Verify the current state yourself before acting — the facts above were
  measured at one point in time and the VM may have moved on.
- Report honestly: if `verify.sh` fails a condition, say which one and stop; do
  not paper over it.
- Ask before anything destructive beyond the approved prune, and before any
  change to the sandbox plane's security posture.
- Prefer the repo's own `make` targets and scripts over ad-hoc commands
  (`infrastructure/makes/*.mk` — e.g. `make secrets-ensure` for credentials,
  `make certs` for the local CA).
