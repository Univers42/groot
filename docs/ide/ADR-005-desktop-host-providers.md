# ADR-005 — Desktop host providers: a real folder and a local terminal behind the existing seams

Status: PROPOSED · Date: 2026-10-14 · Decides: how the desktop edition (Electron) edits a
real folder on the user's machine, and what must hold before a local terminal exists ·
Builds on [ADR-001](ADR-001-vfs.md) (mount table, `FsProvider`),
[ADR-002](ADR-002-terminal.md), [ADR-004](ADR-004-page-files.md) (the "real OS later" line) ·
Source: the S4 design and the 2026-10-14 risk ruling (devil). Where the design and the
ruling disagree, the ruling wins and this page follows the ruling. Falsifiers at end.

Nothing in this ADR is shipped. `apps/osionos/app/scripts/host-fs-ops.mjs` is not merged:
S4U1 is in progress and the file is not on the branch this page was written on. No Electron
test harness exists today. The only code change already made is C17 and C18 (below), and it
sits on an unmerged osionos branch. There is no runnable example in this page because no host
provider exists to run.

Every `file:line` below was checked against osionos `df57475` (2026-10-14); line numbers
drift with later commits.

## Problem

The desktop app (`apps/osionos-electron`) should open a workspace backed by a real folder
(Linux first, Windows and macOS behind the same contract) and later a local terminal, through
the same renderer contracts as the web build (`FsProvider`, mount table, terminal dock). Today a desktop edition never sets `VITE_OSIONOS_IDE_URL`, so sandbox health is
"disabled", `workspace://` falls back to the page-file provider, and the terminal shows
"sandbox unavailable".

The risk: an fs channel puts real files behind a renderer that runs an EOL Chromium (128,
Electron 32.3.3), mermaid in `loose` mode, an `allow-same-origin` iframe fed by unvalidated
marketplace URLs, and no CSP, while showing collaborative content.

## Decision

Overall ruling: **BLOCK** for S4 as a whole; S4U1 and S4U2 may start now with conditions.
The host-fs channel cannot ship until the renderer is hardened (C14, C17-C19) and
confinement covers `.` paths, self-inflicted races, protected paths and bind locations
(C2, C5, C21, C22).

Kept from the design: Electron only this cycle; confinement enforced in main, never only in
the renderer; the renderer passes a workspace id, never a root path; the root is chosen in a
main-side dialog; hardening lands before any fs channel exists.

### Findings that drove the conditions

- `assertRelPath` refuses only a `..` substring, a leading `/` and `\n\r\t\0`. It accepts
  `.`, `a//b`, `\\server\share`, `C:x`, `f:stream`, `CON`. In Node, a recursive delete of
  `.` resolves to the bound root and would wipe the folder (the sandbox survives only
  because `rm` refuses `.`). Read from source; not executed (no host node).
- The renderer can win a check/use race alone: with a repo that contains a symlink pointing
  outside the root, it sends a `read` concurrently with two `rename`s that swap a real
  directory for the one holding the link. Main awaits `realpath`, then `open`; the renames
  run in between. The same sequence with `write` reaches a shell startup file (code execution).
- Writes into `.git` (`core.fsmonitor`, `hooks/*`) run code the next time the user runs git
  there. A bound root that contains the app's user-data directory lets the renderer rewrite
  the root-binding file; a root of the home directory exposes shell startup files and ssh
  authorized keys.
- The sender check does not stop same-origin frames: the embed pane frames the marketplace
  launch URL with `allow-scripts allow-same-origin` and no scheme check, so an `app://`
  frame can call the parent's desktop API from the main frame.
- Mermaid `securityLevel: "loose"` allows `click ... call fn` callbacks; a CSP does not stop them.
- A naive CSP breaks the app (inline theme and titlebar scripts, WASM in the formula engine).
- The 512 KiB read cap is checked against the whole file even for ranged reads, so a larger
  host file is unreadable in any chunk while the provider advertises `streamingReads: true`.
  There is no EACCES/EPERM tag, so permission errors and confinement refusals surface as `Io`.
- Routing host watch events into the inbound pipeline ends in `createPagesBatch`
  (`inboundDrain.ts:170`): local `.env` files and keys would become pages pushed to the
  shared workspace, irreversibly.
- For a PTY the renderer is the whole security boundary (`useIdeTerminal.ts:66-70` writes
  renderer-chosen strings to stdin), so "login shell, no argv from the renderer" protects
  nothing.
- Two design claims were false: `READ_CAP_BYTES` and `FS_OP_SCRIPTS` are not exported, and
  `build-native.sh:33` copies only `bridge-api.mjs` and `bridge-graph.mjs`, so no edition
  would ship the new module without a packaging change.

### Units, as ruled

| Unit | What | Verdict | Conditions | Status |
|---|---|---|---|---|
| S4U1 | Pure Node host-fs transport, twin of the sandbox fs-op scripts | PROCEED-WITH-CONDITIONS | C1-C10 | in progress |
| S4U2 | Electron hardening | PROCEED-WITH-CONDITIONS | C11-C18 | only C17, C18 done (web app, unmerged) |
| S4U3 | fs IPC into Electron main, root binding, watch | BLOCK until C19-C28 | C19-C28 | not started |
| S4U4 | Renderer wiring | split: seams PROCEED-WITH-CONDITIONS; third backend waits for S4U3 | C29-C31 | not started |
| S4U5 | Local PTY | BLOCK | own ruling | not started |

#### S4U1 — host-fs transport (C1-C10)

Proven by the conformance suite gaining a `host(node)` target plus a new confinement test file.

- **C1** `host(node)` TARGETS entry passes the existing corpus unchanged (`npm run test:canvas`).
- **C2** Segments `""`, `.`, `..` and any mutation targeting the root refused; tests delete
  `.` and `""` recursively and check the root is intact.
- **C3** Containment is `real === rootReal || real.startsWith(rootReal + path.sep)`, both sides
  from `realpath`; a symlink to a sibling `<root>-evil` is refused.
- **C4** Symlink-escape tests for read, list, stat, write, mkdir, rename (source and destination),
  delete; deleting an escaping link removes only the link.
- **C5** All ops on one root run on one serialized promise chain; the rename-swap race is
  run at least 200 iterations with zero outside reads or writes; external-process races get a
  `Ponytail:` marker.
- **C6** Random temp name opened `"wx"`, `O_NOFOLLOW` on the final component, mode preserved,
  no `*.vfstmp*` left on failure.
- **C7** Recursive delete never follows links or crosses `st_dev`; `removeTree` injectable.
- **C8** Win32 per-segment rules (`:`, `\`, trailing dot/space, reserved device names),
  unit-tested through an injected platform.
- **C9** Ranged reads capped on the requested range (or `streamingReads:false`); EACCES/EPERM
  and confinement map to PermissionDenied, EUNSUP to Unsupported; output never has the root path.
- **C10** New exports from `ide-sandbox-spec.mjs` are additive; `sandbox(sh)` stays green.

#### S4U2 — Electron hardening (C11-C18)

Files: `apps/osionos-electron/{main.js,preload.js,build.sh,build-native.sh}`.

- **C11** Guards via `app.on("web-contents-created")`: window-open denies all (http(s) goes to
  `shell.openExternal`), `will-attach-webview` prevented, navigation outside `app://osionos/` refused.
- **C12** `senderAllowed(event)`: main window, non-null main frame, origin `app://osionos`,
  path `/` or `/index.html`; `win:*` registered once; node:test covers the rejections.
- **C13** `/__baas/` responses get `nosniff`, `CSP: sandbox; default-src 'none'`; non-JSON
  becomes `application/octet-stream`.
- **C14** CSP on every `app://` response: no `unsafe-inline`/`unsafe-eval`, inline scripts by
  sha256 computed in main at startup, `'wasm-unsafe-eval'`, restricted `frame-src`,
  `object-src 'none'`, `base-uri 'none'`; Report-Only first, enforced after a clean C15 run.
- **C15** Automated Electron smoke (Playwright `_electron` under xvfb) for full, local and
  native editions: titlebar, login, page load/save, database view, chat send, CSP header,
  `window.open` returns null. An edition that cannot run reports SKIP and does not get
  `webSecurity:true`.
- **C16** `webSecurity:true`, `sandbox:true` explicit; chrome-sandbox probe linux-only; fix
  the contradictory `main.js` comments.
- **C17** Mermaid `securityLevel: "strict"`. Done 2026-10-14 in the web app on an unmerged
  osionos branch; the merge is not done.
- **C18** `launchUrl` accepts only http: and https:. Done 2026-10-14 on the same unmerged
  branch; the merge is not done.

#### S4U3 — fs IPC into main (blocked; C19-C28 lift it)

- **C19** Electron on a supported major; `apps/osionos-electron/package-lock.json` committed.
- **C20** Linux only; win32/darwin "unavailable" until C2-C8 pass on real hosts.
- **C21** Bind validator refuses filesystem/drive roots, the home directory and ancestors,
  anything equal to/inside/containing the user-data dir, resources and app dirs (realpath).
- **C22** Writes, renames, deletes, mkdirs resolving into `.git` refused (case-insensitive on
  win32/darwin); reads allowed.
- **C23** Delete via `shell.trashItem`, no unlink fallback.
- **C24** `osio:fs` and `osio:fs-root` registered once with `handle`; each runs `senderAllowed`
  then `validateFsRequest` (op allowlist, 4096-byte paths, safe integers, strict booleans,
  capped base64); spy test proves rejection precedes any fs call; no `*Sync` calls in handlers.
- **C25** Root-binding file written 0600 and atomically; constant dialog strings; one dialog at a time.
- **C26** Watch: handle `'error'` (ENOSPC degrades to watch "none"); emitted paths relative and
  re-validated against C2, temp files excluded; symlinked dirs not followed; binding a
  50k-directory tree blocks main at most 100 ms (measured, artifact cited) or watch moves to
  a utilityProcess.
- **C27** Both modules in `files` of `package.json` and `electron-builder.native.json` and copied
  by `build.sh` and `build-native.sh`; C15 asserts the API is present where enabled.
- **C28** S4U2 merged with C11-C18 green before any `osio:fs*` code lands in `main.js`.

#### S4U4 — renderer wiring (split)

- **C29** Host events never reach `useIdeFsSync` or `inboundDrain`; a test asserts no call.
  Ingesting local files into pages needs its own ruling.
- **C30** Without `window.osionosDesktop`, `createBackends` behaves exactly as today; canvas and
  e2e stay green; `subscribeWorkspaceMounts` fires on bind and unbind.
- **C31** Caps derived from the platform; no `PtyTransport` seam added to `useIdeTerminal.ts`.

#### S4U5 — local PTY (blocked)

To lift: S4U3 shipped and clean for a release; C14, C17, C18, C19 enforced; a workspace-trust
prompt in main; node-pty supply-chain accounting; its own ruling.

The design's gate D6 (Chromium sandbox on, or opt-in) is not a mitigation for page-level
script; do not count it.

## Interfaces

Existing, quoted from the ruling (not re-read here):

- `FsOpTransport = (op, params) => Promise<{exitCode, output}>` in
  `apps/osionos/app/src/features/ide/vfs/sandboxFsOps.ts` (lines 18-29). Parsing and the
  `VFSERR:*` taxonomy are client-side there; `TAG_TO_CODE` is at lines 31-40.
- `createSandboxProvider(scheme, transport, events?)` in
  `apps/osionos/app/src/features/ide/vfs/sandboxProvider.ts` (line 33) builds a full
  `FsProvider` over any transport.
- The wire format is the sh snippets `FS_OP_SCRIPTS` in
  `apps/osionos/app/scripts/ide-sandbox-spec.mjs` (about lines 189-215); `assertRelPath` at
  line 173; `READ_CAP_BYTES` (512 KiB) is a plain `const` at line 183.
- Conformance corpus: `apps/osionos/app/tests/canvas/vfs-conformance.test.ts`; a new target is
  one TARGETS entry.

New, **not merged**:

- `createHostFsTransport(rootDir, options)` in `apps/osionos/app/scripts/host-fs-ops.mjs`.
  Returns an `FsOpTransport`-compatible function emitting the `FS_OP_SCRIPTS` wire format
  with `node:fs`. Planned `options`: injected platform (C8), injectable `removeTree` (C7).
  The design named it `createHostFsOps(rootRealPath)`; the signature S4U1 merges is final.
- Later: channels `osio:fs`, `osio:fs-root`, `osio:fs-event` (S4U3) and a third backend in
  `createBackends` (`workspaceMounts.ts:91-117`, S4U4).

## Consequences

- S4U1 ships nowhere: a pure module with tests.
- S4U2 changes every desktop edition and is useful without S4; its risk is regression
  (mixed content on the local app origin, CSP vs inline scripts), hence C15 per edition.
- Until S4U3 merges, the desktop edition has no host folder and no local terminal.
- Windows and macOS stay "unavailable" for host fs (C20); host-folder edits do not reach pages (C29).

## Not verified

Nothing was run against Electron at runtime (the ruling's list: `webSecurity:true` per edition,
CSP `'self'` on `app://`, recursive `fs.watch` in Electron 32, `/__baas/` content types,
Windows junction behaviour, the Electron 32 EOL date, `_electron` in the test container).

## What would falsify this decision

- A confinement test (C2-C5) that can be bypassed, or the C5 race producing even one outside
  read or write in 200 iterations: the single-queue design is insufficient and host fs
  needs a descriptor-based approach (open relative to a root handle) or a separate process.
- The C26 measurement of binding a 50k-directory tree over 100 ms in main: watch moves to a
  utilityProcess, or is dropped.
- C15 showing a CSP violation or a broken edition that cannot be fixed without
  `unsafe-inline`: the hardening plan, and therefore S4U3, needs rework.
- A page-level script path found after C14/C17/C18 that still reaches the desktop API:
  S4U3 stays blocked.
- The `host(node)` target needing changes to the shared corpus to pass (C1 says unchanged):
  the wire-format reuse is wrong; the seam needs a typed transport.
- Electron cannot move to a supported major (C19): host fs does not ship on this stack.
