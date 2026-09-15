# Secrets Management — mail and calendar (Google OAuth apps)

> The Google OAuth client secret never leaves the server-side Node bridge: no browser bundle, no version control, no Docker image layer ever receives it.

## What it is (the concept)

**Secrets management** is the discipline of ensuring that credentials — API keys, OAuth client secrets, tokens — are accessible only to the process that legitimately needs them, for the minimum necessary scope and duration. A **confidential OAuth client** is one whose `client_secret` must remain server-side; exposing it publicly lets anyone impersonate the registered application and perform token exchanges on its behalf. **Environment variable injection** is the standard runtime mechanism: the secret is supplied to the process at startup and never written into source code, build artefacts, or container images.

## What it defends against

See [Credential Theft via Secrets Exposure](../../attack/secrets-management.md).

In this context the threat is an attacker extracting `GOOGLE_CLIENT_SECRET` from the shipped JavaScript bundle or from a committed `.env` file, then using it to mint or refresh Google OAuth tokens on behalf of the registered app — silently reading users' Gmail or Google Calendar data. Because the React/Vite frontends are served as static assets, any secret embedded at build time becomes world-readable in the browser DevTools network tab.

## How mail-calendar implements it

**Control 1 — Client secret confined to the Node bridge process.**

Both apps split into two processes: a Vite-built React frontend and a standalone Node HTTP bridge (`bridge/server.mjs`). The bridge is the only process that ever holds `GOOGLE_CLIENT_SECRET`.

- [`apps/mail/bridge/server.mjs` lines 43-44](../../../../apps/mail/bridge/server.mjs) — reads credentials at startup:
  ```js
  const googleClientId     = process.env.GOOGLE_CLIENT_ID     || vaultCredentials.googleClientId     || '';
  const googleClientSecret = process.env.GOOGLE_CLIENT_SECRET || vaultCredentials.googleClientSecret || '';
  ```
  The secret is then used exclusively in `exchangeToken()` (line 272) and the `finishGmailAuth` handler (lines 806-812), which POST to `https://oauth2.googleapis.com/token` — a server-to-Google call.

- [`apps/calendar/bridge/server.mjs` lines 43-44](../../../../apps/calendar/bridge/server.mjs) — identical pattern; `client_secret` appears in the token exchange handler at lines 649-655 and nowhere else.

- [`apps/mail/src/App.tsx` line 122](../../../../apps/mail/src/App.tsx) — the React frontend receives only the bridge URL:
  ```ts
  endpoint: (import.meta.env.VITE_MAIL_BRIDGE_URL as string | undefined) || 'http://localhost:4100',
  ```
  A grep of `apps/mail/src/` and `apps/calendar/src/` for `GOOGLE_CLIENT_SECRET` or `client_secret` returns zero matches, confirming the secret never enters the browser bundle.

- [`apps/calendar/.env.example` lines 32-43](../../../../apps/calendar/.env.example) — the example file labels `VITE_*` keys explicitly as _"Browser-exposed configuration. Never put private secrets in this key"_. `GOOGLE_CLIENT_SECRET` carries no `VITE_` prefix, so Vite's static-analysis inlining ignores it at build time by design.

**Control 2 — Secrets excluded from git history and Docker build context.**

- [`apps/calendar/.gitignore` lines 3-9](../../../../apps/calendar/.gitignore) — ignores `.env`, `.env.*`, `.env*local`, `.vault/`, and `.calendar-bridge-*.json` (only `.env.example` is tracked). The mail app carries an equivalent `.gitignore`.

- [`apps/mail/.dockerignore` lines 9-11](../../../../apps/mail/.dockerignore) — excludes `.env` and `.env.*` from the Docker build context (keeping only `!.env.example`), so `COPY . .` in the Dockerfile never bakes live credentials into an image layer.

- On-disk `.env.local` files for both apps are owned by the developer account with mode `0600` (`-rw-------`), confirmed by `ls -la apps/mail/.env.local apps/calendar/.env.local`. No group or world read.

## How we know it is applied

Three independent structural proofs confirm the control is live, not aspirational:

1. **Vite's prefix filter is enforced at the build tool level.** Vite only statically inlines env vars whose name starts with `VITE_`. Because `GOOGLE_CLIENT_SECRET` has no such prefix, it is mechanically excluded from every bundle — no source-code discipline required.

2. **Grep returns zero browser-side references.** Running `grep -r "GOOGLE_CLIENT_SECRET\|client_secret" apps/mail/src/ apps/calendar/src/` produces no output, confirming the secret is referenced exclusively inside the two `bridge/server.mjs` files.

3. **Git and Docker controls are filesystem-enforced.** `git ls-files apps/mail apps/calendar` returns no `.env*` files other than `.env.example`; the `.dockerignore` rules are read by the Docker build daemon before `COPY` executes, making image-layer leakage structurally impossible.

## Reference

The [OWASP Secrets Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html) defines the authoritative control categories: never hard-code secrets, use environment-based injection, exclude secrets from source control and build artefacts, and restrict file-system permissions. This implementation follows all four categories: `GOOGLE_CLIENT_SECRET` is injected at container startup via `process.env`, absent from git, absent from Docker images, and readable only by the owning process user (`0600`).

## Residual risk / assumptions

- **Runtime environment trust.** The control assumes the host environment (Docker daemon, OS, CI runner) is not itself compromised. If an attacker can read `/proc/<pid>/environ` of the bridge process, they can extract the secret regardless of these controls.
- **Vault path.** Both bridges optionally load credentials from a Vault path (`CALENDAR_BRIDGE_VAULT_OAUTH_PATH`, `MAIL_BRIDGE_VAULT_ENABLED`). The security of that path depends on the Vault AppRole credentials (`VAULT_ROLE_ID`, `VAULT_SECRET_ID`) and their rotation policy — outside the scope of these two apps.
- **Stored token files.** After a successful OAuth exchange, Google access/refresh tokens are persisted to `.mail-bridge-state.json` / `.calendar-bridge-state.json` on disk. These files are gitignored but are not encrypted at rest; physical or privileged access to the bridge host exposes live tokens.
- **No secret rotation automation.** `GOOGLE_CLIENT_SECRET` rotation (e.g., after a suspected leak) requires a manual credential update in vault42 and a bridge container restart; there is no automated rotation or short-lived credential mechanism for the Google OAuth client itself.
