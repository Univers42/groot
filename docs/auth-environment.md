# Authentication environment and production transition

Last updated: 2026-05-10

`opposite-osiris` is currently an Astro/Vite frontend. The auth client is implemented in a React-compatible hook-style module at `opposite-osiris/src/hooks/useAuth.ts`, but it has no React runtime dependency so the existing Astro build stays lightweight.

## Development variables

The Docker bootstrap writes these local development values to `apps/opposite-osiris/.env.local`:

```dotenv
PUBLIC_AUTH_GATEWAY_URL=/api/auth
PUBLIC_PORTAL_URL=http://localhost:3001
PUBLIC_TURNSTILE_SITE_KEY=1x00000000000000000000AA
TURNSTILE_SECRET_KEY=1x0000000000000000000000000000000AA
TURNSTILE_BYPASS_LOCAL=true
PUBLIC_SITE_URL=http://localhost:4322
```

The public site key is safe for browser code. The Turnstile secret must only be read by the auth gateway or production backend. Generate the ignored file with Dockerized Node from the repository root:

```sh
docker run --rm -v "$PWD":/workspace -w /workspace node:22-alpine node infrastructure/baas/scripts/bootstrap-env.mjs
```

## Local runtime

The local runtime is HTTP on Docker-owned localhost ports:

```dotenv
PUBLIC_SITE_URL=http://localhost:4322
ASTRO_DEV_PORT=4322
PUBLIC_AUTH_GATEWAY_URL=/api/auth
```

Start the services from the repository root:

```sh
docker compose up -d --build
```

## Production variables

For a live domain:

1. Create a Cloudflare Turnstile widget for the production hostname.
2. Replace `PUBLIC_TURNSTILE_SITE_KEY` with the live site key.
3. Store `TURNSTILE_SECRET_KEY` in the production secret manager, not in source control.
4. Set `TURNSTILE_BYPASS_LOCAL=false`.
5. Set `PUBLIC_AUTH_GATEWAY_URL` to the HTTPS auth gateway origin or a same-origin reverse proxy path.
6. Set `PUBLIC_PORTAL_URL` to the HTTPS portal sign-in URL.
7. Ensure the gateway can reach Kong/GoTrue through `PUBLIC_BAAS_URL` and has a service role key for audit logging.

## Auth gateway responsibilities

`scripts/auth-gateway.mjs` is the reference backend boundary for secure auth:

- verifies Cloudflare Turnstile server-side before registration, login, and recovery
- applies per-IP rate limiting and sends `Retry-After` for client exponential backoff
- validates email with an RFC 5322-compatible regex
- enforces registration passwords with at least 12 characters, uppercase, lowercase, number, and symbol
- proxies registration/login/recovery to GoTrue
- stores refresh tokens in `HttpOnly`, `Secure`, `SameSite=Lax` cookies
- rotates refresh tokens through `/api/auth/refresh`
- exposes reserved MFA hooks for TOTP and WebAuthn
- writes security audit events through `auth_record_audit_event`

Run locally through Docker Compose:

```sh
docker compose up -d --build auth-gateway opposite-osiris
```

Astro dev inside Docker proxies `/api/auth` to `http://auth-gateway:8787`.

## Session model

The browser receives short-lived access tokens only. Refresh tokens are handled by the gateway as `HttpOnly` cookies to reduce XSS exposure. CSRF risk is reduced by `SameSite=Lax`; production deployments should add origin checks and CSRF tokens if cross-site auth flows are introduced.

## MFA hooks

The gateway returns `501` for reserved MFA endpoints until a provider is enabled:

- `/api/auth/mfa/totp/enroll`
- `/api/auth/mfa/totp/verify`
- `/api/auth/mfa/webauthn/options`

Recommended future wiring:

- TOTP: store encrypted TOTP secrets in a private table and verify with a backend-only library.
- WebAuthn: store credential IDs/public keys and challenge state server-side; require HTTPS and user verification.

## Email verification protection

Production GoTrue must run with `GOTRUE_MAILER_AUTOCONFIRM=false`. Registration returns a neutral success state instructing the user to check email, and the UI does not grant a full session until the user confirms their address and signs in.

The local Docker stack sets autoconfirm on so Playwright and local development can create an account and immediately verify the website to osionos bridge flow.

## Audit retention

`models/auth-security-migration.sql` creates `auth_audit_events`. Retain these records for 13 months unless a legal hold applies, then purge or anonymise IP/user-agent data.
