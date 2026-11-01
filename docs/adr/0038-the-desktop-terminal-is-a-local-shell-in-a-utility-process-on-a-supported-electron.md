# 0038. The desktop terminal is a local shell in a utility process, on a supported Electron

- Status: accepted (devil: PROCEED-WITH-CONDITIONS, 2026-10-31; osionos `docs/ide/vscode-backend/devil-verdict-2026-10-31-desktop-local-terminal.md`)
- Date: 2026-10-31
- Deciders: owner (the UX rule), devil (ruling)

## Context

- The owner's rule (2026-10-31): like VS Code, opening the terminal panel gives a shell on this computer — no second window, no emailed code, no pairing, no cookie in the desktop app.
- ADR 0036 opened the machine as a child window after a step-up; that stays for the web app, not the desktop.
- The desktop app already runs as the person on their machine, so a token or a step-up protects nothing there. The boundary is the renderer: what script can run on `app://osionos`.
- Electron was 32 (13 majors behind 45, the latest on 2026-10-31).

## Decision

- **Shell:** `node-pty` 1.1.0 (N-API, pinned, MIT) spawns the account's shell (`/etc/passwd`, then `$SHELL`; bare on Linux like Ptyxis, `-l` on macOS) in `$HOME`, inside a `utilityProcess` (`pty-host.js`), started on the first terminal.
- **Broker:** the main process (`desktop-pty.js`) registers `pty:*` only in the FULL edition (C2), re-checks the sender with `senderAllowed` on every call, binds each pty to the page that made it, caps 8 per window, and kills a page's shells on reload, renderer crash and close (C5, C6).
- **Preload:** exposes `osionosDesktop.pty` only to a window started with `--osionos-pty` (the FULL main window) and only on `app://osionos` (C5).
- **Flow control:** output pauses past 100k unacknowledged chars, resumes under 5k (C7). The shell's env drops `ELECTRON_*`, `NODE_OPTIONS` and an AppImage's paths (C8).
- **Electron 44.8.0**, pinned exactly, lockfile committed, builds use `npm ci` (C1). The renderer carries keystrokes and resize only; tasks, the run bus and the debugger stay off the local shell (C3, osionos).

## Supply chain (C9)

- `node-pty@1.1.0`, Microsoft, MIT; one dependency, `node-addon-api@^7.1.0`. Its install script (`node scripts/prebuild.js || node-gyp rebuild`) is approved in `allowScripts`; Linux has no prebuild, so it compiles.
- `pty.node` built 2026-10-31 in `electronuserland/builder:latest`: sha256 `b9d2d6d8d52a28450d66103254908463531b52d454b3b546ddae939a27a0f7f8`.
- Removal path: drop the dependency, `pty-host.js`, the `pty:*` handlers and the preload's `pty`; the panel falls back to the web behavior.

## Consequences

- One stored XSS on `app://osionos` would now type into a shell. What holds it: the enforced CSP (FULL), embeds on other origins, no command from page content reaching the shell (C3), a supported Chromium.
- LOCAL and NATIVE editions have no local terminal until their CSP is enforced.
- Proof: `test/desktop-pty.test.js` (15 tests) and `sh test/smoke/run-smoke.sh pty` (12 checks, C1–C8, green on 2026-10-31 with Electron 44.8.0). The signed-in C15 smoke on 44.8.0 still owes a run (it needs the account password).

## Amendment 1 — the panel is VS Code's own terminal (2026-11-01)

- **Why:** the owner asked for VS Code's terminal, not the app's xterm. The app runs plain `monaco-editor`, which clashes with `monaco-vscode-api`, so VS Code's terminal runs in its own page: osionos `src/terminal-client`, built by `vite.terminal.config.ts` into `terminal/` of the renderer (`app.Dockerfile`).
- **A1:** the panel hands a `MessagePort` to the iframe it rendered; the page never reads `window.parent`. A frame of the page that got no port draws nothing.
- **A2:** the shell serves `/terminal/*` with `frame-ancestors 'self'` (`pagePolicy`), and the page starts only as a direct child of the top window.
- **A3:** the page loads no task, debug, extension, gallery, remote-agent, scm or search service, and its workspace is untrusted.
- **A4:** `isAllowedSubframeUrl` admits exactly `app://osionos/terminal/index.html` (an optional query, no fragment, no `..`, no other host).
- **A5:** `frame-src`'s only `app:` source is `app://osionos/terminal/`.
- **A6, measured:** `sh test/smoke/run-smoke.sh terminal` gives 5/5 on Electron 44.8.0: the handoff, typing round-trip, no-port refusal, nested refusal, and 0 CSP console lines. First shell output arrives 0.83–1.05 s after the frame is added (4 runs, xvfb, no GPU). The smoke plays the panel's side of the port because the dock sits behind sign-in; osionos `terminal-port.test.ts` pins that protocol.

## Amended by 0039 (2026-11-01)

The terminal page moves to `app://terminal/` with a direct port per pty, and A2, A4, A5 and C5 (for port traffic) change. See [0039](0039-the-desktop-terminal-runs-on-its-own-origin-with-a-direct-port-to-the-pty-host.md).
