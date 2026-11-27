# DRAFT. The desktop browser tab is a sandboxed WebContentsView in its own partition, loads only http(s) through one main-process gate, and runs only where the Chromium sandbox is on

- Status: proposed (draft, unnumbered). devil: PROCEED-WITH-CONDITIONS SB1–SB27. Certificate refusal: PROCEED. Accepting invalid certificates in-app: out of scope (below).
- Date: 2026-11-20
- Deciders: devil (ruling); osionos-electron + osionos builder (lives with it)
- Design: `docs/superpowers/specs/2026-11-20-simple-browser-design.md`

## Context

- The app's main window carries a preload with `win:*` and, in FULL, the local shell (`pty`) bridge (`apps/osionos-electron/preload.js:246,280-285`, `main.js:129-146`). A browsed page that reaches IPC reaches a shell on the user's machine.
- One global `web-contents-created` handler guards every contents. It allows main-frame navigation to `app://osionos` (`isAppPageUrl`) and to the machine page, opens `MACHINE_WINDOW` child windows from `window.open`, and sends other http(s) to `shell.openExternal` (`main.js:89-110`). Subframes may load `app://terminal/index.html`, `data:application/pdf`, about:blank and any http(s) (`desktop-guards.js:94,102-108`).
- The FULL edition is also shipped as an AppImage (`package.json:13,32`). When the setuid `chrome-sandbox` helper is missing or not setuid root, the process adds `no-sandbox` for **every** renderer (`main.js:57-65`). `webPreferences.sandbox: true` does not restore the OS sandbox then.
- Electron is 44.8.0 (`package.json:22`); ADR 0038:12 records 45 as latest on 2026-10-31.
- The repo has no permission, download or certificate handler (`rg 'setPermission|will-download|certificate|setCertificateVerifyProc' apps/osionos-electron/*.js` → 0 hits). Electron approves permission requests when no handler is set (Electron security checklist, item "Handle session permission requests from remote content").
- `protocol.handle("app", …)` is called on the module, i.e. the default session only (`main.js:231`).
- `applyTailnetBypass` returns null when the data center is not on a tailnet (`desktop-proxy.js:59-61`), so a session left to it keeps the system proxy (Tor on the user's laptop, `desktop-proxy.js:5`) for 192.168.x/10.x traffic. `<local>` does not cover RFC 1918 literals.
- `globalShortcut` Ctrl/Cmd+Shift+R loads `app://osionos/index.html` into the **focused** window (`main.js:248-251`), which would be a detached browser window.
- `tabToActivePage` returns null only for a fixed list of kinds (`layoutSync.ts:20`); any other kind becomes an `ActivePage` and enters recents (`pageStore.helpers.ts:134-140`).
- Layout, including tab URLs, is per (user, workspace) localStorage only (`layoutPersist.ts:219,235`); no server sync found.
- The web iframe policy is `THIRD_PARTY_SANDBOX` including `allow-same-origin` (`embedPolicy.ts:34-35`); its stated defence is the app refusing to be framed (`embedPolicy.ts:21-31`; `docker/services/node/nginx.conf:22-23`, `public/_headers:4,7`, `vercel.json:16`).
- The bridge unfurler refuses private ranges (`scripts/bridge-unfurl-addr.mjs:16-17`), so LAN URLs get no frameability answer from it.
- Unknown when this was written: whether Electron 44 enforces Local Network Access in a custom partition with a deny-all permission handler; whether `will-frame-navigate` fires for `loadURL` in 44; whether reparenting a `WebContentsView` keeps page state in 44; whether Electron on Linux reads the NSS store (`~/.pki/nssdb`) for a private CA. Each is a condition below, not an assumption.

## Decision

A browser tab in FULL is a `WebContentsView` in `persist:osionos-browser`, no preload, sandboxed, enabled only when the Chromium sandbox is active. Main is the only gate that loads a URL into it; the global guard keeps its rules for every other contents and swaps to "http(s) only" for contents in the browser `WeakSet`. `window.open` from a browsed page loads in the same view, never a window. Certificate errors are refused. The web build gets the same tab over the existing embed iframe policy, nothing looser.

## Alternatives considered

- **iframe in the desktop**: blank on `X-Frame-Options` sites (the user's main case) and needs `frame-src` opened to every origin in the enforced CSP (`desktop-guards.js:185,195`).
- **`<webview>`**: denied on purpose (`main.js:100`); reopening it loosens a guard the anti-goals keep.
- **Partition keyed by session identity instead of a WeakSet**: a wrong session choice would loosen the guard; a missed WeakSet add over-restricts. WeakSet fails closed; it stays, with SB7 asserting the session too.
- **Accept a bad certificate per host (fingerprint pin)**: puts router/Tailscale cookies of a persistent jar behind a click-through; needs its own ruling.

## Consequences

Conditions SB1–SB27 (in the session's ruling) are the acceptance criteria. Highlights:

- SB1: browser off when `no-sandbox` is on (AppImage, non-setuid helper). Deb with setuid helper and Windows keep it.
- SB3–SB6: one `isBrowsableUrl` gate before every `loadURL`; carve-out never admits `app:`; machine window unreachable; `app://` unresolvable in the partition.
- SB8, SB14, SB16: deny-all permissions; public→private requests proved blocked; LAN never through the system proxy.
- SB13: the global reload shortcut targets the main window only.
- SB17: no accept path for invalid certificates.

Out of scope: accepting an invalid certificate inside the app. The fact that would change this: a measured case where the user's router or VM certificate cannot be trusted through the OS store (NSS on Linux) **and** a per-host leaf-fingerprint pin limited to private addresses is designed and ruled separately.

Reverse it by removing the edition gate; the partition directory (`userData/Partitions/osionos-browser`) is then deleted by the clear-data command (SB15).
