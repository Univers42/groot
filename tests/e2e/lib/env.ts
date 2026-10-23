// Every URL and name the suite depends on, overridable from the environment.
export const OSIONOS_URL = process.env.E2E_OSIONOS_URL ?? "https://localhost:3001";
export const WHITEBOARD_URL = process.env.E2E_WHITEBOARD_URL ?? "https://localhost:3007";
export const GATEWAY_URL = process.env.E2E_GATEWAY_URL ?? "https://localhost:8787";
export const MAIL_URL = process.env.E2E_MAIL_URL ?? "https://localhost:3002";
export const PRISMATICA_URL = process.env.E2E_PRISMATICA_URL ?? "https://localhost:4322";
export const CALENDAR_URL = process.env.E2E_CALENDAR_URL ?? "https://localhost:3003";
// osionos's bridge API (app.Dockerfile VITE_API_URL).
export const BRIDGE_URL = process.env.E2E_BRIDGE_URL ?? "https://localhost:4000";
// One stable user, reused across runs: the gateway rate-limits login to 8/min per IP,
// so a fresh account per run would trade a leftover for flakes.
export const E2E_EMAIL = process.env.E2E_EMAIL ?? "e2e-smoke@example.com";
export const E2E_PASSWORD = process.env.E2E_PASSWORD ?? "E2e-Smoke-Pass-2026!";
export const BOARD_PREFIX = "e2e-";
// A second user, for the checks that one user never sees another's data (GR2).
export const E2E_EMAIL_B = process.env.E2E_EMAIL_B ?? "e2e-smoke-b@example.com";
export const E2E_PASSWORD_B = process.env.E2E_PASSWORD_B ?? "E2e-Smoke-Pass-B-2026!";
export const TOKEN_FILE = "test-results/.e2e-access-token";
// The demo account owns the workspaces the live databases are mounted on; run.sh reads its
// per-machine password from ./.env.local. Empty = the specs that need it skip, saying so.
export const E2E_DEMO_EMAIL = process.env.E2E_DEMO_EMAIL ?? "";
export const E2E_DEMO_PASSWORD = process.env.E2E_DEMO_PASSWORD ?? "";
export const DEMO_SKIP_REASON = "E2E_DEMO_PASSWORD unset: run.sh reads DEMO_LOGIN_PASSWORD from ./.env.local (make link-frontends-up or make all mint it)";

// Mailpit's API as grobase publishes it (auth-api.yml: 127.0.0.1:${MAILPIT_UI_PORT:-8026}).
export const MAILPIT_URL = process.env.E2E_MAILPIT_URL ?? "http://127.0.0.1:8026";
// Kong through the edge (:8444), for GoTrue calls the gateway does not proxy (TOTP enrolment).
export const KONG_URL = process.env.E2E_KONG_URL ?? "https://localhost:8444";
// The public anon key Kong asks of every call; run.sh reads it from ./.env.local. Empty = the TOTP variant skips.
export const KONG_ANON_KEY = process.env.E2E_KONG_ANON_KEY ?? "";
// Set to seconds only on a stack started with that AUTH_RESET_TOKEN_TTL_SEC; empty = expired-link case skips.
export const SHORT_RESET_TTL_SEC = Number(process.env.E2E_SHORT_RESET_TTL_SEC ?? 0);
