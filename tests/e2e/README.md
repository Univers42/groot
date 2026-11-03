# e2e smoke — the defense path, in a browser

Playwright 1.63.0 in its official image (`Dockerfile`), against the **running** stack.

    make e2e     # preflight → the specs in specs/

- **DW10** installs Mail/Calendar from the Marketplace, opens each from its rail entry, checks the pane at 15 s, uninstalls — SKIP when those opt-in apps are down.
- Every spec fails on any console error (one Playwright-caused sandbox message excepted, see `lib/fixtures.ts`). No retries.
- HTTPS: the grobase CA is mounted and imported into Chromium's NSS store and `NODE_EXTRA_CA_CERTS`; errors are never ignored.
- Login is the real signed handoff: gateway login → `/api/auth/osionos-session` → `#bridge_token=`.
- Leaves: the user `e2e-smoke@example.com` (reused every run, override with `E2E_EMAIL`/`E2E_PASSWORD`).
- Env overrides: `E2E_OSIONOS_URL`, `E2E_GATEWAY_URL`, `E2E_MAIL_URL`, `E2E_CALENDAR_URL`.
