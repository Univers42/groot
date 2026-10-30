# Electron smoke (C15)

Drives the real `main.js` with Playwright `_electron` inside a container (xvfb + openbox, no docker
socket, `--network host`). The demo password goes host -> fifo -> container stdin only.

    sh apps/osionos-electron/test/smoke/run-smoke.sh full     # runs
    sh apps/osionos-electron/test/smoke/run-smoke.sh local    # prints SKIP (reason inline)
    sh apps/osionos-electron/test/smoke/run-smoke.sh native   # prints SKIP (reason inline)

First run builds `renderer/` (`build.sh --renderer-only`), the image, and installs electron 32.2.7 +
playwright-core 1.49.1 into the `osionos-electron-smoke-cache` volume. Screenshots land in
`$SMOKE_OUT` (default `/tmp/osionos-electron-smoke-out`). Exit 1 if any check FAILs.

## Output
- `PASS|FAIL|SKIP <check> — <evidence>`: SKIP means the check did not run, never a pass.
- `csp-violations=<n>` + up to 10 distinct `violatedDirective blockedURI` lines: the C14 gate
  (enforce the CSP only when this is 0 across a full run). `csp-counter-selftest` proves the counter is live.
- `console-errors=<n>`: renderer `console.error` count, informational.
- `web-security`: `webPreferences.webSecurity` read from the live window (C16: on in the full edition).

## Does NOT check
- Minimize/maximize are read from `BrowserWindow` under openbox, not on a real desktop WM.
- `database-view` proves the Databases panel loads its catalog, not that a table opens or edits.
- `chat-send` proves the user turn renders (stub connector), not a real assistant reply.
- BaaS: unset `OSIONOS_BAAS_URL` means the grobase `build.sh` baked (`OSIONOS_DESKTOP_BAAS_URL`),
  else 127.0.0.1:8000, where nothing may listen; `app://osionos/__baas/*` calls are then offline
  unless you set it to a live Kong. Another account: `DEMO_LOGIN_EMAIL` plus `SMOKE_ENV_FILE`,
  a file holding its `DEMO_LOGIN_PASSWORD`.
- Local and native editions (SKIP). Windows/macOS.
- Writes: it creates one page titled `smoke-<id>` in the demo account; nothing deletes it.

Ponytail: selectors are copied from `apps/osionos/app/tests`; a renamed label reads FAIL (noisy, safe).
The 30 s waits are for a cold app + live bridge; a slow host reads FAIL, never a false PASS.
