import { request, type Browser, type BrowserContext, type Page } from "@playwright/test";
import { GATEWAY_URL, OSIONOS_URL } from "../lib/env";

// The Arlet demo users, logged in at the gateway and handed into osionos the way a visitor is.
// Login only: unlike lib/session.ts's loginOrRegister, a refused login never registers, because
// these accounts live on the shared baas and are created by scripts/demo/seed-baas.sh alone.

const TURNSTILE = "localhost-turnstile-token";

export const ARLET = {
  ines: { email: "ines.caradec@arlet.example.com", password: process.env.E2E_ARLET_INES_PASSWORD ?? "" },
  jules: { email: "jules.marchand@arlet.example.com", password: process.env.E2E_ARLET_JULES_PASSWORD ?? "" },
} as const;

async function post(path: string, body: unknown, bearer?: string): Promise<{ status: number; body: Record<string, unknown> }> {
  const api = await request.newContext();
  try {
    const res = await api.post(`${GATEWAY_URL}${path}`, { data: body, headers: bearer ? { authorization: `Bearer ${bearer}` } : {} });
    return { status: res.status(), body: (await res.json().catch(() => ({}))) as Record<string, unknown> };
  } finally {
    await api.dispose();
  }
}

/** osionos opened as an Arlet user, through the gateway login and the signed handoff. */
export async function openAs(browser: Browser, who: keyof typeof ARLET, options: { colorScheme?: "light" | "dark"; viewport?: { width: number; height: number } } = {}): Promise<{ context: BrowserContext; page: Page }> {
  const user = ARLET[who];
  if (!user.password) throw new Error(`E2E_ARLET_${who.toUpperCase()}_PASSWORD is unset: run scripts/media/capture.sh`);
  const login = await post("/api/auth/login", { email: user.email, password: user.password, turnstileToken: TURNSTILE });
  const token = login.body.access_token;
  if (login.status !== 200 || typeof token !== "string") throw new Error(`login ${user.email}: HTTP ${login.status} ${String(login.body.message ?? "")}`);
  const handoff = await post("/api/auth/osionos-session", {}, token);
  const url = handoff.body.redirectUrl;
  if (handoff.status !== 200 || typeof url !== "string" || !url.startsWith(OSIONOS_URL)) throw new Error(`osionos-session ${user.email}: HTTP ${handoff.status}`);
  const context = await browser.newContext({ colorScheme: options.colorScheme ?? "light", viewport: options.viewport ?? { width: 1440, height: 900 }, deviceScaleFactor: 2 });
  const page = await context.newPage();
  await page.goto(url);
  return { context, page };
}
