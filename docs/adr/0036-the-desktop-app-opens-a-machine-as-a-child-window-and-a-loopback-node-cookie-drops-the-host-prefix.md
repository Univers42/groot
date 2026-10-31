# 0036. The desktop app opens a machine as a child window, and a loopback node cookie drops the `__Host-` prefix

- Status: accepted (devil: PROCEED-WITH-CONDITIONS, 2026-10-31; amends C6 of the osionos verdict `docs/ide/vscode-backend/devil-verdict-2026-10-30.md`)
- Date: 2026-10-31
- Deciders: devil (ruling), owner (lives with it)

## Context

- `/machine` opens this machine's IDE page (osionos-node, `http://127.0.0.1:4100`) as its own window, then hands it a session through `window.opener`. A frame across sites never gets its cookie (C0-F1, ADR-0034).
- The desktop app sent every `window.open` to the system browser and denied it (`apps/osionos-electron/main.js`, `setWindowOpenHandler`). The IDE then had no opener, so `/machine` could not work there.
- Electron 32.2.7 (Chromium 128) stores no `__Host-` cookie on `http://127.0.0.1`. Measured in the C23 run: 0 cookies after a 204 session mint, then 401 on every request. A `document.cookie` probe stored `Secure`, `SameSite=Strict` and plain cookies, but not the `__Host-` one. The newer headless Chromium the browser tests use accepts it, so they could not see this.

## Decision

- **Electron.** `isMachineWindowUrl` (`desktop-guards.js`) matches `http://127.0.0.1:<port>/?node=…&folder=…` only.
  - Such a `window.open` opens a child `BrowserWindow`. Only a window with an opener may stay on that URL.
  - Every other URL keeps the old rule: http(s) goes to the system browser, the rest is denied.
  - The child inherits the preload, but `win:*` is accepted from the main window only (C12), so it cannot drive the app window.
- **osionos-node.** `--app-origin` repeats: one node serves the web app and `app://osionos`. The IDE page pins the first origin that sends it a session.
- **Cookie.** When the configured IDE origin is plain http on a 127.0.0.0/8 literal, the node cookie is `osio-node-<id>`, with `Secure; HttpOnly; SameSite=Strict; Path=/`, no `Domain`.
  - Every other origin keeps `__Host-osio-node-<id>`.
  - Each origin reads only its own name.
  - Every value under that name is verified, so a duplicate set from another local port cannot shadow the real one.

## Alternatives considered

- **Open the IDE in the system browser**: there is no opener, so no session handoff. That would need a second carrier (a code in the URL), which C5 forbids.
- **Keep `__Host-` and wait for a newer Electron**: the desktop app stays broken. The prefix adds nothing on an IP literal: no subdomains, and cookies ignore ports. The MAC is what protects the value.
- **Proxy the node through `app://osionos/__baas`-style `protocol.handle`**: it carries no WebSocket upgrade (F13).

## Consequences

- Measured on 2026-10-31 with `apps/osionos-electron/test/smoke/machine-smoke.mjs`: 9/9 checks, exit 0, with the emailed step-up. The editor connected, a save and a terminal probe reached the laptop's disk, there was no token in storage or the HAR (C5), and `app://osionos` was refused by the node (C7).
- The laptop's osionos-node service runs with `--app-origin https://baas.tail10f2ea.ts.net:8443 --app-origin app://osionos`.
- A non-loopback http node (RFC 1918, tailnet) in the desktop app is not supported until ruled on.
- Caveat: the cookie mode assumes Chromium keeps storing unprefixed Secure cookies on http loopback, measured on Electron 32.2.7 only. A browser that refuses them fails closed with a 401.
