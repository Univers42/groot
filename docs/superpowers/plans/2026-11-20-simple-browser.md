# Simple browser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A browser tab in the osionos workspace grid, opened from the top search bar, that can be detached into its own window — a native `WebContentsView` in the desktop app, a limited iframe in the web build.

**Architecture:** Main process owns every browser view (`WebContentsView` in `persist:osionos-browser`, no preload, sandboxed) through a registry; the renderer reports a placeholder rect over IPC and the view is laid over it. One http(s) gate in main runs before every `loadURL`. The renderer's `BrowserPane` talks to a `BrowserBackend` interface: desktop = IPC, web = sandboxed iframe from the embed library.

**Tech Stack:** Electron 44.8.0 (CommonJS, `node --test`), React 19 + TypeScript (osionos app, node:test canvas runner, Playwright e2e), Playwright `_electron` smoke.

**Spec:** `docs/superpowers/specs/2026-11-20-simple-browser-design.md` · **Ruling (acceptance criteria):** `docs/adr/DRAFT-simple-browser-ruling.md`, conditions SB1–SB27 (full text: the devil's ruling of 2026-11-20, quoted per task below).

## Global Constraints

- Two repos, two worktrees, branch `feat/simple-browser` in both:
  - groot (Electron): `/mnt/storage/dlesieur/wt/groot-browser` from `origin/develop`; code in `apps/osionos-electron/`.
  - osionos app: `/mnt/storage/dlesieur/wt/osionos-browser` from osionos `develop` (after the Task 10 gallery fix lands).
- Files < 300 lines, functions ≤ 25 lines, no `any`, no `as unknown as`, no lint suppression. New osionos files start with the 42 header copied from `src/data/templates/catalogue/tplId.ts`.
- Every heuristic carries a `Caveat:` line (URL normalising, overlap test, refusal detection, eviction, SB14 filter).
- No new dependency in either repo.
- `main.js` is 265 lines: it gets only `require`s and one-line install calls; logic lives in new modules.
- Electron unit tests: `timeout 300 docker run --rm -v "$PWD":/w -w /w mirror.gcr.io/library/node:22-bookworm-slim node --test test/*.test.js` (from `apps/osionos-electron`).
- osionos gates (W = worktree): `W=$PWD T=900 bash /mnt/storage/dlesieur/scratch/integ/osionos.sh test-canvas` → `# fail 0`; same with `quality` → rc 0; `bash /mnt/storage/dlesieur/scratch/tpl/vite-build.sh $PWD 4096` → `build rc=0`, `check rc=0`; e2e `timeout 1900 bash /mnt/storage/dlesieur/scratch/tpl/fn-run.sh <tag> $PWD <specs…>` → `e2e rc=0`.
- Commits: Conventional, no `Co-Authored-By`, no "Generated with". No push, no merge, no release without the user's go; never push osionos develop while its CI runs.
- Copy fixed by the spec: "Open in browser", "Open browser", "Detached — Bring back", "This site can't be shown inside osionos — Open in a new window", "Page crashed — Reload", "Open in system browser", "Clear browser data".

## Review Focus

1. **A view painting over app UI after layout changes** (pane resize, split, tab switch, sidebar collapse, app zoom 125 %): the view must track the placeholder exactly or hide. Pinned by Task 7's bounds test and Task 11's zoom smoke.
2. **A browser tab restored at boot whose URL now fails the gate** (old layout JSON, hand-edited localStorage): renders the error state, makes 0 `loadURL` calls. Pinned in Task 3 (registry refuses) and Task 7 (pane shows error).
3. **Closing the tab while its view is detached**: the detached window closes and the view is destroyed; registry empty. Pinned in Task 3 and Task 6.
4. **Typing in the search bar something that is both a page title and a host** (`notes`, `router`): pages stay listed; the URL row is first only when the query has a dot, a port, a scheme or is an IP/`localhost` (single-label hosts map to `http://` only when typed with a scheme or port). Pinned in Task 8.
5. **The 7th browser tab**: the least recently shown hidden view is evicted, its tab reloads its URL when shown again, the visible ones never are. Pinned in Task 3.

---

## Part A — Electron (`apps/osionos-electron`, groot worktree)

### Task 1: URL gate, normaliser, LAN bypass rules

**Files:**
- Create: `apps/osionos-electron/desktop-browser-url.js`
- Test: `apps/osionos-electron/test/desktop-browser-url.test.js`

**Interfaces:**
- Produces: `isBrowsableUrl(raw: string): boolean`; `normalizeBrowserUrl(input: string): string | null`; `browserBypassRules(): string`; `isPrivateHost(host: string): boolean`.

- [ ] **Step 1: Write the failing tests** (SB3, SB16, SB26)
  - `isBrowsableUrl` false for each of: `javascript:alert(1)`, `file:///etc/passwd`, `app://osionos/index.html`, `data:text/html,x`, `chrome://gpu`, `devtools://devtools/x`, `view-source:http://a`, `http://u:p@h`, `"http://a/" + "x".repeat(2048)`, `""`; true for `http://192.168.1.1/`, `https://example.com/a?b`.
  - `normalizeBrowserUrl` table → `http://` for `192.168.1.1`, `10.0.0.2:8080`, `172.16.0.1`, `127.0.0.1:4100`, `localhost:3000`, `169.254.1.1`, `100.64.0.1`, `[::1]:8080`, `[fd00::1]`, `[fe80::1]`, `router.lan`, `nas.local`, `x.home.arpa`, `router` (single label); → `https://` for `example.com`, `vm.tail1234.ts.net`, `8.8.8.8`; kept as typed: `http://example.com`, `https://192.168.1.1`; → `null` for `hello world`, `javascript:x`, `ftp://a`, `""`.
  - `browserBypassRules()` contains each of `<local>`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `127.0.0.0/8`, `[::1]`, `*.lan`, `*.local`, `*.home.arpa`.
- [ ] **Step 2: Run** the Electron test command → FAIL (`Cannot find module '../desktop-browser-url'`).
- [ ] **Step 3: Implement.** Use `URL` and `node:net` `isIP` only. `normalizeBrowserUrl` returns a value that already passes `isBrowsableUrl`. Header `Caveat:` — host classification is by literal and suffix: a public name that resolves to a LAN address gets `https://`, a LAN name without a LAN suffix gets `https://`; the user can type the scheme. A failed `https://` never falls back to `http://`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(desktop): browser URL gate and LAN normaliser`.

### Task 2: Browser session hardening

**Files:**
- Create: `apps/osionos-electron/desktop-browser-session.js`
- Test: `apps/osionos-electron/test/desktop-browser-session.test.js`

**Interfaces:**
- Consumes: `browserBypassRules()` (Task 1); `applyTailnetBypass(ses, url)` (`desktop-proxy.js`).
- Produces: `BROWSER_PARTITION = "persist:osionos-browser"`; `browserWebPreferences(ses): object`; `hardenBrowserSession(ses, { baasTarget, onDownloadBlocked(url) }): Promise<void>`; `clearBrowserData(ses): Promise<void>`.

- [ ] **Step 1: Write the failing tests** with a fake session object recording every call:
  - SB7: `browserWebPreferences(fake)` deep-equals `{ session: fake, sandbox: true, contextIsolation: true, nodeIntegration: false, nodeIntegrationInSubFrames: false, webviewTag: false, webSecurity: true }` and has no `preload` key.
  - SB8: after `hardenBrowserSession`, the recorded permission request handler calls back `false` for `media`, `geolocation`, `notifications`, `clipboard-read`; the check handler returns `false`; the device permission handler returns `false`; `select-hid-device`, `select-serial-port`, `select-usb-device` listeners call back with `""`/prevent; `setDisplayMediaRequestHandler` callback gets no source.
  - SB9: a `will-download` event calls `item.cancel()` and `onDownloadBlocked(item.getURL())`.
  - SB16: `setProxy` is called with `proxyBypassRules` containing `browserBypassRules()` when `applyTailnetBypass` would return null.
  - SB17: the fake records no `setCertificateVerifyProc` call; no `certificate-error` listener is registered by this module.
  - SB6: no `protocol.handle` call on the fake session.
  - SB15: `clearBrowserData` calls `clearStorageData()`, `clearCache()`, `clearAuthCache()` on the given session only (a second fake standing for `defaultSession` records 0 calls).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** Electron APIs named above, nothing else. Merge the tailnet rules with `browserBypassRules()` into one `setProxy({ mode: "system", proxyBypassRules })` call (reuse `proxyRulesFrom`/`tailnetBypassRules` from `desktop-proxy.js` rather than re-deriving).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(desktop): deny-all browser session in its own partition`.

### Task 3: Browser registry and edition gate

**Files:**
- Create: `apps/osionos-electron/desktop-browser.js`
- Test: `apps/osionos-electron/test/desktop-browser.test.js`

**Interfaces:**
- Consumes: `isBrowsableUrl` (Task 1).
- Produces:
  - `browserEnabledFor({ edition, sandboxed }): boolean` — `ptyEnabledFor(edition) && sandboxed`.
  - `isViewId(v): boolean` (UUID v4 shape); `isValidRect(r): boolean` (finite, 0 ≤ each ≤ 16384, integer-rounded later).
  - `createBrowserRegistry({ createView, randomId, send, limit = 6 })` → `{ create(url, host), navigate(id, url), act(id, "back"|"forward"|"reload"|"stop"), setBounds(id, rect, zoom), setVisible(id, visible), moveTo(id, host), get(id), destroy(id), destroyAll(), size() }`.
  - `createView(id)` (injected) returns `{ webContents, setBounds, setVisible, attachTo(host), detachFrom(host) }`.
  - `send(host, channel, payload)` (injected) — the only way state leaves main.
  - `BrowserState = { viewId, url, title, canGoBack, canGoForward, loading, favicon?, error?: { kind: "certificate"|"crash"|"load"|"download", code: string } }`.

- [ ] **Step 1: Write the failing tests:**
  - SB1: `browserEnabledFor({edition:"full", sandboxed:true})` true; `full`+`sandboxed:false`, `local`, `native`, `undefined` false.
  - SB3: `create(bad)` / `navigate(id, bad)` for each Task 1 bad URL → returns `null`/`false` and the fake `webContents.loadURL` recorded 0 calls; the view's `setWindowOpenHandler` handler, called with `{url:"javascript:x"}`, returns `{action:"deny"}` and loads nothing; with `{url:"http://127.0.0.1:4100/?node=x"}` returns `deny` and loads it in the same view (SB5).
  - SB5: `setWindowOpenHandler` is installed before the first `loadURL` (recorded call order).
  - SB11: a `page-title-updated` with a 400-char title sends `title.length === 300`; favicon `javascript:x` or `http://a/f.ico` is omitted, `https://a/f.ico` and `data:image/png;base64,AA` kept; `send` is called with the entry's current host only.
  - SB12: create 3, `destroy` each → `size() === 0` and each fake `webContents.close` called once; `destroyAll()` after `moveTo` closes detached hosts too.
  - Limit: with 6 views, 1 visible and 5 hidden, `create` a 7th → the least recently visible hidden one is destroyed and `send(host, "browser:evicted", { viewId })` fires; a visible one is never evicted.
  - Zoom: `setBounds(id, {x:10,y:20,width:100,height:50}, 1.25)` → view bounds `{x:13,y:25,width:125,height:63}` (rounded).
  - Error mapping: `certificate-error` → state `error.kind === "certificate"` with the Chromium code, and the event is **not** `preventDefault`ed (SB17); `render-process-gone` → `crash`; `did-fail-load` on the main frame (not `-3` aborted) → `load`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** `Map<viewId, { view, host, lastShown, visible }>`. Header `Caveat:` — eviction drops in-page state of the evicted tab; it reloads its last committed URL when shown.
- [ ] **Step 4: Run** → PASS. `wc -l desktop-browser.js` < 300 (split state wiring into `desktop-browser-state.js` if not).
- [ ] **Step 5: Commit** `feat(desktop): browser view registry with an http(s) gate on every load`.

### Task 4: Guard carve-out and focused-window fixes

**Files:**
- Modify: `apps/osionos-electron/desktop-guards.js` (navigation rule export), `apps/osionos-electron/main.js:57-65` (capture `SANDBOXED`), `main.js:89-110` (handler), `main.js:248-251` (shortcut)
- Test: `apps/osionos-electron/test/desktop-guards.test.js` (add cases; existing cases unchanged)

**Interfaces:**
- Produces: `browserContents: WeakSet<WebContents>` (exported from `desktop-browser.js`, registry adds each view's contents at create); `navigationAllowed(url, { isBrowser, isMainFrame }): boolean` in `desktop-guards.js`.

- [ ] **Step 1: Write the failing tests** (SB4): for `isBrowser:true` main frame, `navigationAllowed` true for `http(s)` only and false for `app://osionos/index.html`, the machine page URL, `file:`, `data:`; subframe false for `app:`, `file:`, `chrome:`, `devtools:`. For `isBrowser:false` every existing guard test case returns what it returns today (run the old suite unchanged).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** In `web-contents-created`: if `browserContents.has(contents)` use the browser rule for `will-navigate`/`will-frame-navigate` and never call `shell.openExternal`; leave `will-attach-webview` deny as is. `const SANDBOXED = !app.commandLine.hasSwitch("no-sandbox")` captured after the lines 57-65 decision. Ctrl/Cmd+Shift+R loads into `mainWindow` only (SB13).
- [ ] **Step 4: Run** → PASS, and the full Electron suite stays green.
- [ ] **Step 5: Commit** `fix(desktop): browser contents get their own navigation rule; reload targets the main window`.

### Task 5: IPC, preload and main wiring

**Files:**
- Create: `apps/osionos-electron/desktop-browser-ipc.js`
- Modify: `apps/osionos-electron/preload.js`, `apps/osionos-electron/main.js` (requires + `installBrowser(...)` call guarded by `browserEnabledFor({ edition: EDITION, sandboxed: SANDBOXED })`), `package.json` `build.files`, `electron-builder.native.json` `files`
- Test: `apps/osionos-electron/test/desktop-browser-ipc.test.js`, `test/packaged-files.test.js` (passes once files are listed)

**Interfaces:**
- Consumes: registry (Task 3), session (Task 2), `senderAllowed` (main.js).
- Produces: `installBrowserIpc({ ipcMain, registry, isMainSender(event), detachedOwner(event) → viewId|null, actions })`. Channels (invoke): `browser:create(url)`, `browser:navigate(id,url)`, `browser:back|forward|reload|stop|openExternal|devtools|destroy|detach|attach(id)`, `browser:setBounds(id,rect)`, `browser:setVisible(id,bool)`, `browser:capture(id) → Uint8Array|null`, `browser:clearData()`. Events to the host: `browser:state`, `browser:attached {viewId}`, `browser:evicted {viewId}`, `browser:shortcut {viewId, key: "p"|"w"|"l"}`.
- Preload `osionosDesktop.browser` (only when argv has `--osionos-browser` and origin is `app://osionos`): one method per invoke channel plus `onState(cb)`, `onAttached(cb)`, `onEvicted(cb)`, `onShortcut(cb)` each returning an unsubscribe function.

- [ ] **Step 1: Write the failing tests** (SB10 hostile-argument table): from a non-main sender every channel rejects; from a detached toolbar sender, only calls naming its own `viewId` pass; `viewId` values `"x"`, `""`, `null`, an unknown UUID, `{}` reject; rects with `NaN`, `-1`, `16385`, `Infinity`, missing keys reject; `navigate` with a Task 1 bad URL rejects without `loadURL`; a detached sender passes only when it is `entry.hostWindow.webContents`, the frame is its main frame and the frame URL is exactly `app://browser-window/index.html` (a subframe or `app://browser-window/index.html?x` rejects). `before-quit` calls `registry.destroyAll()`. SB1: with `browserEnabledFor` false, `install` is not called and preload exposes no `browser` key (test the preload's exported pure `desktopApi(argv, origin)` if one exists, else extract it).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** `openExternal` passes the view's committed URL through `isBrowsableUrl` before `shell.openExternal`. `devtools` opens detached devtools for the view only. `before-input-event` on browser contents: Ctrl/Cmd+P/W/L → `preventDefault` + `browser:shortcut`. `capture` returns `capturePage().toPNG()`. `will-download` → state `error.kind: "download"`.
- [ ] **Step 4: Run** the Electron suite → PASS (including `packaged-files.test.js`).
- [ ] **Step 5: Commit** `feat(desktop): browser IPC behind the main-window and own-view sender checks`.

### Task 6: Detached browser window

**Files:**
- Create: `apps/osionos-electron/desktop-browser-window.js`, `apps/osionos-electron/browser-window/index.html`, `browser-window/toolbar.js`, `apps/osionos-electron/browser-window-preload.js`
- Modify: `apps/osionos-electron/desktop-app-protocol.js` (host `browser-window` → `browser-window/` dir, like `terminal`), `main.js` (close detached windows on main close), both builder file lists
- Test: `test/desktop-app-protocol.test.js` (new host cases), `test/desktop-browser-window.test.js`

**Interfaces:**
- Consumes: registry `moveTo(id, host)` (Task 3), IPC detached sender rule (Task 5).
- Produces: `openDetachedWindow({ BrowserWindow, viewId, registry, preloadPath, onClosed })`; preload exposes `browserWindow` with the Task 5 methods bound to its own `viewId` (read from `--osionos-browser-view=<uuid>` argv) and nothing else.

- [ ] **Step 1: Write the failing tests:** SB18 — `resolveAppRequest("app://browser-window/index.html")` returns the file with policy `browser-window` and CSP header starting `default-src 'none'`; `app://browser-window/../main.js` → `NOT_FOUND`; the preload's API keys are exactly the per-view controls (no `minimize`, no `pty`); `packaged-files.test.js` asserts both builder lists contain `desktop-browser*.js`, `browser-window-preload.js` and `browser-window/**/*`. SB19 — closing the detached window calls `registry.moveTo(id, mainHost)` and sends `browser:attached`; closing it after the tab was destroyed closes cleanly with the view destroyed; main window close closes every detached window (fake `BrowserWindow`s).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** Toolbar page: back, forward, reload/stop, address field, "Open in system browser", "Bring back"; title from `browser:state`. No inline script (CSP); `toolbar.js` loaded by `<script src>`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(desktop): detach a browser tab into its own window`.

## Part B — osionos app (osionos worktree)

### Task 7: Tab kind "browser" and BrowserPane on the desktop backend

**Files:**
- Modify: `src/widgets/workspace-grid/model/layoutTree.ts:14` (TabKind `"browser"`), `layoutPersist.ts` (factory `browserTab(url)`), `layoutSync.ts:20` (`tabToActivePage` null for `"browser"`), `src/widgets/page-renderer/ui/PaneContent.tsx` (extract the embed branch into `ExternalContent.tsx` first — the file is 299 lines — then route `"browser"`), `lazyViews.tsx` (`LazyBrowserPane`), `src/widgets/top-bar/model/desktop.ts` (`desktopBrowser()` getter)
- Create: `src/widgets/browser-pane/model/browserBackend.ts`, `model/desktopBackend.ts`, `model/useBrowserBounds.ts`, `model/openBrowserTab.ts`, `ui/BrowserPane.tsx`, `ui/BrowserToolbar.tsx`, `ui/BrowserErrorState.tsx`
- Test: `tests/canvas/browser-tab.test.ts`, `tests/canvas/browser-pane.test.ts`

**Interfaces:**
- Produces:
  ```ts
  interface BrowserBackend {
    readonly kind: "desktop" | "web";
    open(url: string): Promise<void>;
    navigate(url: string): Promise<void>;
    back(): void; forward(): void; reload(): void; stop(): void;
    setBounds(rect: DOMRectReadOnly | null): void; // null = hidden
    detach(): void; openExternal(): void; devtools?(): void;
    capture?(): Promise<Blob | null>; // desktop only (Task 10)
    subscribe(listener: (state: BrowserViewState) => void): () => void;
    dispose(): void;
  }
  type BrowserViewState = { url: string; title: string; canGoBack: boolean; canGoForward: boolean; loading: boolean; detached: boolean; error?: { kind: "certificate"|"crash"|"load"|"download"|"refused"; code: string } };
  function pickBackend(): BrowserBackend | null; // desktop when desktopBrowser() exists; null → the pane shows "Open in a new window" until Task 9 returns the web backend
  function openBrowserTab(url?: string): void; // layout.openTab(browserTab(url), layout.activePaneId)
  ```
- Consumes: Task 5 preload API.

- [ ] **Step 1: Write the failing tests:** a restored tab whose saved `url` is `javascript:x` renders the load-error state and the fake API records 0 `create` calls; SB22 `tabToActivePage({kind:"browser",…})` → `null`; a browser tab round-trips through layout persistence with `url` and no `data:image` anywhere in the JSON (SB20); the pane statically renders the toolbar with an address field whose value is the committed URL in ASCII (`http://xn--bcher-kva.example/` for `bücher.example`) and never the title (SB23); error kinds render "Open in system browser", crash renders "Page crashed — Reload"; detached renders "Detached — Bring back"; with a fake desktop API: `create` is called only when the pane is visible (SB12 lazy restore), unmount calls `destroy`, a hidden tab calls `setVisible(false)`, `browser:evicted` then re-show calls `create` again with the last URL, `browser:shortcut` `l` focuses the address field; `openBrowserTab()` with no URL opens a blank tab with the address field focused; the address field submits the raw input to `navigate` (main normalises, SB26).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** `useBrowserBounds`: `ResizeObserver` + window `resize`/`scroll` → one `setBounds` per animation frame with the placeholder's `getBoundingClientRect()`; main applies the zoom factor (Task 3). Toolbar from the existing UI library, token classes only. Every element keyboard-reachable with visible labels.
- [ ] **Step 4: Run** `test-canvas`, `quality` → PASS; `vite-build.sh` → `build rc=0`, `check rc=0` (browser-pane stays out of the boot chunk: no static import outside `lazyViews.tsx`).
- [ ] **Step 5: Commit** `feat(browser): browser tab with a native view on the desktop`.

### Task 8: URL twin, search result, "Open browser" command

**Files:**
- Create: `src/shared/lib/browser/browserUrl.ts`
- Modify: `src/widgets/top-bar/model/search.ts` (`PaletteResult.kind` gains `"url"`), `src/widgets/top-bar/ui/TopBarSearch.tsx:46`, `src/widgets/top-bar/model/commands.ts`
- Test: `tests/canvas/browser-url.test.ts`, `tests/canvas/top-bar-url-result.test.ts`

**Interfaces:**
- Produces: `normalizeBrowserUrl(input: string): string | null` (same table as Task 1, copied verbatim into the test); `urlResult(query: string, open: (url: string) => void): PaletteResult | null` — offers a row only when the trimmed query has a scheme, a `.`, a `:port`, or is an IP literal or `localhost`, then uses `normalizeBrowserUrl`.
- Consumes (Task 7): `openBrowserTab(url?: string)`.

- [ ] **Step 1: Write the failing tests:** the Task 1 table; `urlResult("192.168.1.1", f)` → `{ kind:"url", title:"Open in browser", subtitle:"http://192.168.1.1/" }`; `urlResult("notes", f)` → `null`; results for `router.lan:8080` start with the `url` row and still contain the page matches; `>` command mode never yields a url row; the command list contains "Open browser", and "Clear browser data" only when `desktopBrowser()` exists (SB15, calls `clearData`).
- [ ] **Step 2: Run** `test-canvas` → FAIL.
- [ ] **Step 3: Implement.** File-level `Caveat:` (same as Task 1) plus: the renderer copy only orders results; main re-checks every URL (SB26).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(top-bar): open a URL in a browser tab from search`.

### Task 9: Web iframe backend

**Files:**
- Create: `src/widgets/browser-pane/model/webBackend.ts`, `ui/BrowserFrame.tsx`
- Test: `tests/canvas/browser-web-backend.test.ts`, `tests/e2e/functional/browserTab.spec.mjs`

**Interfaces:**
- Consumes: `THIRD_PARTY_SANDBOX`, `GENERIC_ALLOW`, `frameableEmbedUrl`, `appForbiddenOrigins` (`src/shared/lib/embed/`), `createEmbedResolver` (unfurl frameability).
- Produces: `createWebBackend(deps: { resolveEmbed, now, open: typeof window.open }): BrowserBackend`.

- [ ] **Step 1: Write the failing tests:** SB24 — the rendered iframe has `sandbox` === `THIRD_PARTY_SANDBOX`, `allow` === `GENERIC_ALLOW`, and `src` === `frameableEmbedUrl(url, appForbiddenOrigins())`; the app's own origin renders the refused state, no iframe. SB25 — for `http://192.168.1.1`, `http://localhost:3000`, `http://router.lan` the fake `resolveEmbed` is called 0 times. Address field label reads "Opened: <url>" (SB23 web). `detach()` calls `open(url, "_blank", "noopener")`. `frameable: false` from the unfurl → "This site can't be shown inside osionos — Open in a new window". e2e: a static frameable page served by the test server loads in the tab; a route answering `X-Frame-Options: DENY` shows the refused state and its button opens a popup.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** Refusal = unfurl `frameable === false`, or no `load` event within 8 s. `Caveat:` — a site that frames but renders blank is not detected; a slow site past 8 s shows the refused state while still loading (the frame stays mounted, so it appears if it loads).
- [ ] **Step 4: Run** canvas, quality, build, and `fn-run.sh sbweb $PWD tests/e2e/functional/browserTab.spec.mjs` → PASS.
- [ ] **Step 5: Commit** `feat(browser): limited browser tab in the web build`.

### Task 10: Native-view occlusion

**Files:**
- Create: `src/widgets/browser-pane/model/useNativeViewOcclusion.ts`, `model/overlapsRect.ts`
- Modify: `ui/BrowserPane.tsx` (desktop backend only)
- Test: `tests/canvas/browser-occlusion.test.ts`

**Interfaces:**
- Produces: `overlapsRect(a: DOMRectReadOnly, b: DOMRectReadOnly): boolean`; `useNativeViewOcclusion(placeholder: RefObject<HTMLElement>, backend: BrowserBackend): { snapshotUrl: string | null }`.

- [ ] **Step 1: Write the failing tests:** `overlapsRect` edge-touching = false, 1 px overlap = true; with a fake body child added over the rect, the hook calls `setBounds(null)` and `capture`, sets an object URL; on removal it restores bounds and calls `URL.revokeObjectURL` with that URL (SB20); a toast outside the rect changes nothing.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** One `MutationObserver` on `document.body` (`childList`), rect test on added portal roots. `Caveat:` — a portal that paints over the rect without being a direct body child is missed.
- [ ] **Step 4: Run** canvas + quality → PASS.
- [ ] **Step 5: Commit** `feat(browser): hide the native view under app overlays`.

## Part C — Proof and release gates

### Task 11: Desktop smoke

**Files:**
- Create: `apps/osionos-electron/test/smoke/browser-smoke.mjs`, `test/smoke/browser-fixtures/` (counter page, `X-Frame-Options: DENY` page, permission probe page, self-signed TLS server script)
- Modify: `test/smoke/run-smoke.sh` (a `browser` mode), `test/smoke/README.md` (one section: what it checks and does NOT check)

- [ ] **Step 1: Write the smoke checks** (each prints `PASS|FAIL|SKIP <check> — <evidence>`):
  - open `http://127.0.0.1:<port>/counter.html`, click ×3, detach, re-attach → counter text `3` (SB19); close tab → registry size 0 via a test-only `--osionos-browser-debug` IPC, absent in release builds (SB12).
  - `window.open` from the page leaves `BrowserWindow.getAllWindows().length` unchanged (SB5).
  - page frames and fetches `app://terminal/index.html` and `app://osionos/__baas/x` → errors only (SB6).
  - camera, microphone, notifications, geolocation → denied (SB8).
  - self-signed server → `ERR_CERT_AUTHORITY_INVALID` state with "Open in system browser" (SB17).
  - with a detached window focused, Ctrl+Shift+R leaves it on `app://browser-window/index.html` (SB13).
  - command palette open over the view → screenshot pixels at the rect centre match the palette, not the page (SB21).
  - app zoom 125 % → view bounds = placeholder rect × 1.25 ± 1 px.
  - SB14: launch with `--ip-address-space-overrides=127.0.0.1:<port>=public`, page fetches `http://127.0.0.1:<other>/` and `http://192.168.x.y/` → blocked. If not blocked: add the private-literal `webRequest` filter in `desktop-browser-session.js` (with its `Caveat:` — a DNS name resolving to a private IP is missed) plus its unit test, and re-run.
- [ ] **Step 2: Run** `sh apps/osionos-electron/test/smoke/run-smoke.sh browser` under `timeout 1200` → every check PASS (SKIP counts as not done).
- [ ] **Step 3: Commit** `test(desktop): browser smoke covers detach state, guards and permissions`.

### Task 12: Release check, security review, .deb run

- [ ] **Step 1: SB2.** In `apps/osionos-electron/release.sh`, fail when the Electron major in `package.json` < (latest major from `npm view electron version`) − 2, with an offline escape `ELECTRON_LATEST=<n>`; unit-test the comparison function in `test/desktop-editions.test.js`. Commit `chore(desktop): release fails on an Electron major older than latest-2`.
- [ ] **Step 2: SB27.** Dispatch the `security` agent on the diff of Tasks 1–6 (guard carve-out, IPC sender checks, detached window, session). Every finding rated High or Critical is fixed (new task per finding, TDD) before Step 3.
- [ ] **Step 3: SB27.** Build the .deb in docker (`build.sh`), install on this machine (setuid `/opt/osionos/chrome-sandbox`), run the Task 11 smoke against the installed binary → all PASS. Paste the output in the PR.
- [ ] **Step 4:** Draft ADR → numbered ADR with the measured answers to the four unknowns (LNA in the partition, `will-frame-navigate` on `loadURL`, reparent keeps state, NSS CA read).
- [ ] **Step 5:** Ask the user for the go: merge osionos `feat/simple-browser` to develop, groot pin bump, desktop release.
