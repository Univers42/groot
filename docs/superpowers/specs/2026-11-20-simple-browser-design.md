# Simple browser in the desktop app — design

Date: 2026-11-20 · Scope: osionos desktop (Electron 44, `apps/osionos-electron`) + osionos app
(`apps/osionos/app`) · Status: draft for approval, then devil ruling (security-sensitive).

## Why

The user works on specific web pages, mostly networking dashboards (routers, Tailscale admin, the
VM's services), alongside their pages. Today that means a second browser window and manual
splitting. They want what VS Code has: a browser tab inside the app, opened from the top search
bar, which can be detached into its own window so it can sit large on another screen.

## Goals

- A **browser tab** in the workspace grid: address bar, back, forward, reload/stop, open in the
  system browser, devtools. It splits, moves and closes like any other tab.
- **Open from the top search bar**: typing a URL or a bare host (`192.168.1.1`, `router.lan:8080`)
  offers "Open in browser" as the first result. Enter opens a browser tab.
- **Detach**: moves the live page into its own window (title bar, same toolbar). The page keeps
  its state: no reload, scroll and logins kept. **Re-attach** puts it back in a grid tab.
- **Any site loads**, including those that send `X-Frame-Options`/`frame-ancestors` (most router
  UIs do), and plain `http://` LAN pages.

## Non-goals

- Bookmarks, history UI, downloads manager, extensions, multiple tabs inside one browser tab (the
  grid already has tabs), and password manager. The system browser is one click away for those.
- Making the web build match the desktop. It gets a limited browser (below), never a native view.
- Sharing cookies with the system browser or with the app's own session.

## Anti-goals (failure even if it "works")

- A browsed page can reach the app: IPC, the preload bridge, the app's cookies/storage, or
  `app://osionos`.
- Loosening the guards the app already has for its own window (`will-navigate`,
  `will-attach-webview`, the CSP, `senderAllowed`).
- A native view that covers app menus, dialogs or the command palette.

## Approaches considered

1. **Main-process `WebContentsView` (picked).** Each browser tab is a `WebContentsView` owned by
   main, laid over a placeholder `<div>` in the pane whose bounds the renderer reports. Detach =
   `contentView.removeChildView` + `addChildView` on a new `BrowserWindow`: the same
   `webContents` moves, so the page is never reloaded. This is how VS Code's current integrated
   browser works. Every site loads; the page runs in its own process with no preload.
   Trade-off: a native view paints above DOM, so overlays must hide it (below).
2. **iframe (VS Code's classic Simple Browser).** Simplest; works in the web build too, where it
   is kept as the limited backend (see "Web build"). Rejected for the desktop:
   sites that refuse framing stay blank (the user's main case), there is no real history, and the
   app's CSP `frame-src` would have to open to every origin.
3. **`<webview>` tag.** Electron discourages it; `will-attach-webview` is denied on purpose
   (`main.js:100`). Rejected.

The user handed over the how ("exactly the same as vscode … from the local app"); approach 1 is
the agent's call.

## Design

### Main process — new `desktop-browser.js` (one concern, unit-tested like `desktop-pty.js`)

- **Edition gate:** enabled where the pty is (`HARDENED_EDITIONS`, FULL); elsewhere the IPC is not
  registered and the preload exposes no `browser` key, so the app falls back to the embed tab.
- **Session:** every browser view uses `session.fromPartition("persist:osionos-browser")` — one
  shared, persistent jar for all browser tabs (logins survive restarts), never the app's
  default session. `webPreferences`: `sandbox: true`, `contextIsolation: true`,
  `nodeIntegration: false`, **no `preload`**, `webSecurity: true`. Permission requests on that
  session (camera, mic, geolocation, notifications, …) are denied by default.
- **Registry:** `Map<viewId, { view, hostWindow }>`; `viewId` = `crypto.randomUUID()`. A view is
  destroyed (`webContents.close()`) when its tab closes or its detached window closes, and all are
  destroyed on app quit. No orphan views.
- **Guard carve-out:** the global `web-contents-created` handler keeps applying to every contents,
  but `will-navigate` / `will-frame-navigate` skip the app-page rule for contents in a
  `browserContents` `WeakSet`, where the rule is instead "`http:` / `https:` only" (no `file:`,
  `app:`, `data:`, `javascript:`, `chrome:`, `devtools:` main-frame navigations).
  `setWindowOpenHandler` on a browser view opens the URL **in the same view** (VS Code behavior)
  instead of a new window; `will-attach-webview` stays denied.
- **IPC (`browser:*`)**, all behind `senderAllowed(event, mainWindow.webContents)` (C12), plus the
  detached window's own toolbar contents: `create(url) → viewId`, `navigate(viewId, url)`,
  `back`, `forward`, `reload`, `stop`, `setBounds(viewId, rect)`, `setVisible(viewId, bool)`,
  `detach(viewId)`, `attach(viewId)`, `openExternal(viewId)`, `devtools(viewId)`,
  `destroy(viewId)`. Main → renderer events: `browser:state {viewId, url, title, canGoBack,
  canGoForward, loading, favicon}` and `browser:attached {viewId}`. Arguments are validated in
  main (viewId shape, URL parse, finite non-negative rect).
- **URL normalising** (`normalizeBrowserUrl`, pure, tested): `http(s)://…` kept; a bare host or
  host:port or IPv4 → `http://` for private/LAN addresses and `.lan`/`.local`/`.home.arpa`,
  `https://` otherwise; anything else → refused (not searched). Caveat line required (heuristic).

### Preload

`osionosDesktop.browser` (only when enabled): thin `ipcRenderer.invoke`/`on` wrappers, same shape
as `pty`. Nothing else is exposed; the browsed page has no preload at all.

### App (renderer)

- **Tab kind `"browser"`** in `layoutTree.ts` (`url` = last committed URL, `title` = page title).
  Persisted like other tabs: on restore the tab re-creates its view at the saved URL. A build
  without the desktop bridge renders the same tab with the web backend (below).
- **`BrowserPane`** (`widgets/browser-pane/`): toolbar (back, forward, reload/stop, address
  field, open external, detach, devtools) + a placeholder `div`. A `ResizeObserver` plus window
  resize/scroll report the placeholder rect (device-independent px) via `setBounds`, throttled to
  one per animation frame. Hidden tab, collapsed pane or unmounted → `setVisible(false)`.
- **Overlays:** a small `useNativeViewOcclusion` hook: while any app overlay is open (menus,
  dialogs, command palette, context menus), visible browser views are hidden and a static
  screenshot (`webContents.capturePage`) is shown in the placeholder so the pane doesn't flash
  empty. Hooked once at the shared overlay layer, not per menu.
- **Top search bar:** `search.ts` gains a result kind `"url"` produced by `normalizeBrowserUrl`'s
  renderer twin (same rules; one shared test table) — first in the list when the query parses
  as a URL/host, in both builds. Activating it opens a browser tab in the
  focused pane. A command "Open browser" opens a blank tab with the address field focused.
- **Detached window:** the tab in the grid shows "Detached — [Bring back]" while its view lives
  in the other window; closing the detached window re-attaches it (no data lost) unless the tab
  was closed meanwhile.

### Web build — limited browser (user's decision, 2026-11-20)

The user: "only from desktop app Electron … but we give the functionality to the browser even if
it's limited". Desktop is the real target; the web build gets the same tab, same toolbar and same
search-bar entry, backed by an iframe, with its limits shown rather than hidden.

- **Backend switch, one pane:** `BrowserPane` talks to a small `BrowserBackend` interface; the
  desktop backend is the IPC above, the web backend is an `<iframe>`. Toolbar, tab kind and
  persistence are shared.
- **iframe rules reuse the embed library** (`shared/lib/embed/`): `sandbox={THIRD_PARTY_SANDBOX}`,
  the URL passes `frameableEmbedUrl(url, appForbiddenOrigins())` (never the app's own origin), and
  nothing looser than an embed gets.
- **What it can't do, stated in the pane:** back/forward/reload act on the frame only where the
  browser allows it (a cross-origin frame hides its URL and history, so the address field shows
  the last URL the user typed); sites that refuse framing (`X-Frame-Options`, `frame-ancestors`)
  show "This site can't be shown inside osionos — Open in a new window"; an `https://` deployment
  can't frame `http://` pages (mixed content), so LAN `http://` pages work only from a local
  `http://127.0.0.1` osionos or the desktop app. Refusal is detected from the frame's load timing
  plus the bridge unfurl's frameability check (`scripts/bridge-unfurl-parse.mjs`) when reachable —
  Caveat required: a site that frames but renders blank is not detected.
- **Detach on the web** = `window.open(url, "_blank", "noopener")`: a normal browser window with
  the page reloaded (no state move). Devtools and "keep logins" are the browser's own.
- No CSP change: the app ships no `frame-src` restriction today (checked: `public/_headers`,
  `docker/services/node/nginx.conf` set only `frame-ancestors 'none'`).

## Edge cases to handle

- Keyboard focus inside the native view: app shortcuts (Ctrl+P, Ctrl+W, Ctrl+L) do not reach the
  renderer; main forwards them via `before-input-event` on browser contents (Ctrl+L focuses the
  address field).
- HiDPI / zoom: rects are CSS px; main multiplies by nothing (Electron view bounds are DIPs), but
  app zoom (`webFrame` zoom factor) must be applied — test at 125 %.
- Certificate errors (self-signed router UIs): Chromium's default interstitial is not available
  in a bare view; main handles `certificate-error` by **refusing** and the pane shows an error
  with "Open in system browser". Accepting a bad cert inside the app is out of scope (devil may
  rule otherwise).
- Crash of the browsed page (`render-process-gone`) → pane shows "Page crashed — Reload".

## Verification

- `apps/osionos-electron/test/desktop-browser.test.js` (node:test, like the others): URL rules,
  the navigation guard for browser contents vs app contents, IPC argument validation, registry
  lifecycle (create/detach/attach/destroy leaves zero views), edition gate.
- osionos canvas: `normalizeBrowserUrl` table, search result ordering, layout persistence of
  `"browser"` tabs, web backend picked without the bridge, web iframe never framing the app's
  own origin (sandbox string pinned to `THIRD_PARTY_SANDBOX`).
- Web Playwright: a frameable local test page loads in the tab; a page sending
  `X-Frame-Options: DENY` shows the "can't be shown" state with its working "Open in a new window".
- Desktop smoke (`test/smoke`): open `http://127.0.0.1:<port>` test page, navigate, back,
  detach, re-attach, confirm the page keeps a counter value (no reload), close → zero views.
- Security review (`security` agent) on the carve-out before merge.

## Calls made after the builder check (agent's calls, correctable)

- **Overlays:** there is no shared overlay layer (45 files call `createPortal`). The view hides
  only when a portal node **overlaps the placeholder rect**, found with one `MutationObserver` on
  `document.body` plus a rect test. Tooltips and toasts outside the rect don't count, so there is
  no flicker. Caveat required: a portal that paints over the rect without being a body child is
  missed.
- **Detached window:** loads a small static page shipped in `apps/osionos-electron`
  (`browser-window.html` with its own preload exposing only the controls for **its own** viewId),
  never the full app. Main trusts it through the registry (`hostWindow.webContents`), not through
  `senderAllowed`. Detached windows close and their views are destroyed when the main window
  closes.
- **Network:** the browser partition gets the same tailnet bypass as the default session
  (`applyTailnetBypass`), plus `<local>`. The VM's private CA is trusted only if the system
  store trusts it. Otherwise certificate errors are refused (devil to rule).
- **Live view cap:** a view is tied to `tabId`, so moving a tab between panes keeps the page.
  At most **6** live views. Past that, the least recently shown hidden view is destroyed and its
  URL reloads when the tab is shown again. Caveat: that tab loses its in-page state.

## Left to the builder

File split inside `widgets/browser-pane/`, toolbar styling with the existing UI library, the
throttling mechanism, and the exact screenshot-on-occlusion wiring.

## Ruled (devil, 2026-11-20)

PROCEED-WITH-CONDITIONS SB1–SB27 — `docs/adr/DRAFT-simple-browser-ruling.md`. The conditions are
acceptance criteria for the plan. Load-bearing: the browser stays off when Chromium runs with
`no-sandbox` (AppImage without the setuid helper; the installed .deb keeps it on), one http(s)
check before every `loadURL`, deny-all permission/device/download handlers on the browser
session, LAN proxy bypass without a tailnet, and a measured public→private fetch block.
Accepting bad certificates in the app is rejected.

## Was open for the devil

The `WeakSet` carve-out in the global navigation guard; the shared persistent partition; certificate
errors refused; same-view `window.open`; whether LAN `http://` defaulting is acceptable; the web
iframe's `allow-same-origin` (inherited from `THIRD_PARTY_SANDBOX`) for user-typed URLs.
