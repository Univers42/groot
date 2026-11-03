# 0039. The desktop terminal runs on its own origin, with a direct port to the pty host

- Status: accepted with conditions (devil: PROCEED-WITH-CONDITIONS, 2026-11-01; osionos `docs/ide/vscode-backend/devil-verdict-2026-10-31-desktop-local-terminal.md`, Amendment 2). T1–T11 are open
- Date: 2026-11-01
- Deciders: owner (VS Code's terminal at about 20 ms per keystroke), devil (ruling); the builder carries T1–T11
- Amends: [0038](0038-the-desktop-terminal-is-a-local-shell-in-a-utility-process-on-a-supported-electron.md) A2, A4, A5 and C5 (for port traffic)

## Context

- The terminal page and the app share one renderer thread. Measured on Electron 44.8.0 (xvfb, no GPU) with `sh test/smoke/run-smoke.sh terminal`: frame → panel is p50 10.4–12.2 ms and p95 17.7–20.8 ms, and echo → frame is p50 14.6 ms. Main, the host and the shell together take p50 1.5–1.9 ms.
- Spike `spike-port` (same container): a frame on another `app:` host runs in its own renderer (pid 138 vs 73). Frame → shell → frame over a direct port has a p95 of 0.9 ms with the app idle and with it busy. The relay that mirrors today's path has a busy p95 of 11.0 ms.
- Today the app world already holds `pty.create`, `write`, `resize`, `ack` and `onData` (`apps/osionos-electron/preload.js:28-36`).
- The host's one handler dispatches `create` and trusts `message.id` (`desktop-pty.js:73-81`).
- The `app:` handler ignores the host. It relays `/__baas/` before any host check, falls back to the app's `index.html`, and contains paths with a bare prefix (`main.js:274-307`).
- The smoke runs with the sandbox off: `chrome-sandbox` is not setuid in `/cache` (`test/smoke/pty-entry.sh:9-12`, `main.js:56-64`).
- VS Code's terminal answers OSC 52 clipboard reads with no setting to gate them (osionos `build/terminal/assets`, `importAddon("clipboard")` with `readText`). The shell sets no permission handler.
- main reloads on Ctrl+R and F5 for keys typed in the framed terminal (`main.js:241-252`). Electron 44.8.0 has `webContents.focusedFrame`.
- Unknown when this was written: whether `MessagePortMain` emits `close` in the utility process on a frame crash, whether the frame's renderer is sandboxed on the .deb, whether Playwright sees an out-of-process frame's console, and key-to-pixel on a GPU.

## Decision

- The terminal page is served at `app://terminal/index.html`, an out-of-process iframe with no preload. Its responses carry a policy narrower than the renderer's (`frame-src 'none'`, `connect-src 'self'`, no `https:`) and `frame-ancestors app://osionos`. `app://osionos/terminal/*` returns 404.
- For each pty, main creates a `MessageChannelMain`. One end goes to the pty host, bound to that pty. The other goes to the creating window. The preload reposts it to its own window, and the panel forwards it to its frame inside the `created` reply on the control port. Keystrokes, resizes and acks go frame → host; output goes host → frame.
- The host validates port traffic in a handler separate from main's. Port `close` kills the pty, and the pty's exit closes the port. main keeps the broker role: the sender check, the cap of 8, ownership, and kill on reload, crash and close.
- `pty:write`, `pty:resize`, `pty:ack` and `pty:data` are removed. One path carries keystrokes.
- The page renders VS Code's panel part (`views`, `view-common` and `layout` service overrides, 37.6.1, MIT, rung 6). The removal path is to drop them and attach the bare terminal instance again.
- OSC 52 clipboard reads are refused (`.out-of-scope/desktop-terminal-osc52-clipboard-read.md`).

## Alternatives considered

- **Keep the same-origin frame and the relay (ADR 0038 A1)**: its frame → panel p95 is 17.7–20.8 ms on its own, which already spends the owner's 20 ms budget.
- **Relay through main, with the frame in its own process**: in the spike the relay's busy p95 is 11.0 ms against 0.9 ms. It also keeps main on the flood path (ADR 0038's failure 4).
- **Hand the port across with `contextBridge`**: the Electron docs list no MessagePort among the types it carries (training memory, not checked in 44.8.0). The spike's `window.postMessage` with a source check works.
- **A preload in the terminal frame (`nodeIntegrationInSubFrames`), with `pty` taken off the app world**: this would make the frame a real security boundary, because a script on `app://osionos` would no longer reach a shell. The cost is that the preload loads into every third-party embed frame, and invisible-overlay clickjacking of the frame remains. It is not needed here, because this plan widens nothing over today. It is worth its own ruling.
- **The app's own xterm in the app's thread**: refused by the owner, who wants VS Code's terminal design and features.

## Consequences

- The keystroke path no longer crosses the app's thread or main. The app world loses the ability to type into a shell it has already handed off, but it keeps `create`, so ADR 0038's "one stored XSS reaches a shell" is unchanged.
- The pty host now takes untrusted input straight from a renderer. Its port handler is a security boundary and is tested as one (T2).
- One more renderer process per window. Its RSS is recorded (T11).
- The builder owes T1–T11 from the verdict's Amendment 2. The status becomes "accepted" when they are green and shown. Key-to-pixel on a GPU stays SKIP until it is measured on the installed .deb.
- To reverse: restore `app://osionos/terminal/`, the IPC write path and A4/A5 as ADR 0038 states them. That is one release.
