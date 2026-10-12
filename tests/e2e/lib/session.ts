import { readFileSync } from "node:fs";
import { request, type Browser, type BrowserContext, type Page } from "@playwright/test";
import { E2E_EMAIL, E2E_PASSWORD, GATEWAY_URL, OSIONOS_URL, TOKEN_FILE } from "./env";

// The local gateway accepts this placeholder only when TURNSTILE_BYPASS_LOCAL=true.
const TURNSTILE = "localhost-turnstile-token";

async function postJson(path: string, body: unknown, bearer?: string) {
  const api = await request.newContext();
  try {
    const res = await api.post(`${GATEWAY_URL}${path}`, {
      data: body,
      headers: bearer ? { authorization: `Bearer ${bearer}` } : {},
    });
    return { status: res.status(), body: (await res.json().catch(() => ({}))) as Record<string, unknown> };
  } finally {
    await api.dispose();
  }
}

export interface E2eUser {
  email: string;
  password: string;
  username: string;
}

const DEFAULT_USER: E2eUser = { email: E2E_EMAIL, password: E2E_PASSWORD, username: "e2e-smoke" };

// One login per user per worker. The gateway allows 8 logins a minute per IP (RATE_LIMITS.login in
// apps/opposite-osiris/scripts/auth-gateway.mjs) and the suite opened every DB test with a fresh
// demo login, so a full `make link-e2e` got 429 from the sixth demo login on (2026-10-12).
// Caveat: a token is reused for TOKEN_REUSE_MS; one revoked server-side inside that window
// (logout, password change) fails the next test that reuses it instead of logging in again.
const TOKEN_REUSE_MS = 10 * 60 * 1000;
const tokens = new Map<string, { token: string; at: number }>();

/** Logs an e2e user (default: the suite's one) in at the gateway, registering it on first use. */
export async function loginOrRegister(user: E2eUser = DEFAULT_USER): Promise<string> {
  const cached = tokens.get(user.email);
  if (cached && Date.now() - cached.at < TOKEN_REUSE_MS) return cached.token;
  const token = await freshLogin(user);
  tokens.set(user.email, { token, at: Date.now() });
  return token;
}

async function freshLogin(user: E2eUser): Promise<string> {
  const credentials = { email: user.email, password: user.password, turnstileToken: TURNSTILE };
  let login = await postJson("/api/auth/login", credentials);
  // Only an unknown account is registered. Any other refusal (a 429 rate limit, a 5xx) used to
  // fall through to register and surface as its 422 "already registered", hiding the real cause
  // (2026-10-12: five DB2 tests failed that way).
  if (login.status !== 200 && login.status !== 400 && login.status !== 401) {
    throw new Error(`login ${user.email}: HTTP ${login.status} ${String(login.body.message)}`);
  }
  if (login.status !== 200) {
    const profile = { username: user.username, confirmPassword: user.password };
    const reg = await postJson("/api/auth/register", { ...credentials, profile });
    if (reg.status !== 200) throw new Error(`register ${user.email}: HTTP ${reg.status} ${String(reg.body.message)}`);
    login = await postJson("/api/auth/login", credentials);
  }
  const token = login.body.access_token;
  if (login.status !== 200 || typeof token !== "string") {
    throw new Error(`login ${user.email}: HTTP ${login.status} ${String(login.body.message)}`);
  }
  return token;
}

/** The real signed handoff: a one-time `#bridge_token=` URL that osionos consumes itself. */
async function mintHandoff(gatewayToken?: string): Promise<string> {
  const token = gatewayToken ?? readFileSync(TOKEN_FILE, "utf8").trim();
  const res = await postJson("/api/auth/osionos-session", {}, token);
  const url = res.body.redirectUrl;
  if (res.status !== 200 || typeof url !== "string" || !url.startsWith(OSIONOS_URL)) {
    throw new Error(`osionos-session: HTTP ${res.status} ${String(res.body.message)}`);
  }
  return url;
}

export interface OpenOptions {
  /** A gateway token from loginOrRegister(user); default: the suite user's (global setup). */
  token?: string;
  /** Runs on the fresh context before the first navigation (routes, init scripts). */
  setup?: (context: BrowserContext) => Promise<unknown>;
}

/** Opens `path` on osionos in a fresh context that has consumed its own handoff. */
export async function openOsionos(browser: Browser, query = "", options: OpenOptions = {}): Promise<{ context: BrowserContext; page: Page }> {
  const context = await browser.newContext();
  await options.setup?.(context);
  const page = await context.newPage();
  const handoff = new URL(await mintHandoff(options.token));
  handoff.search = query;
  await page.goto(handoff.toString());
  return { context, page };
}
