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
