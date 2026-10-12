import { expect, type Browser, type BrowserContext, type Page } from "@playwright/test";
import { BRIDGE_URL, E2E_DEMO_EMAIL, E2E_DEMO_PASSWORD } from "./env";
import { loginOrRegister, openOsionos } from "./session";

// The osionos bridge as the logged-in page sees it: its app-session JWT (osionos_v1.…) and
// the calls it makes with it. Calls run inside the page, so they carry the page's origin and
// cross the same TLS, CORS and gateway path the app does.

export interface OsionosSession {
  jwt: string;
  workspaceId: string;
  userId: string;
}

export interface BridgeResponse {
  status: number;
  json: Record<string, unknown>;
}

/** The osionos session once the handoff has landed: its bridge JWT, active workspace and user. */
export async function osionosSession(page: Page): Promise<OsionosSession> {
  const read = () =>
    page.evaluate(() => {
      const store = (globalThis as unknown as { __playgroundUserStore?: { getState(): Record<string, () => unknown> } }).__playgroundUserStore;
      const state = store?.getState();
      const jwt = state?.activePageJwt?.() as string | null | undefined;
      const ws = state?.activeWorkspace?.() as { _id?: string } | undefined;
      if (!jwt || !ws?._id) return null;
      const encoded = (jwt.split(".")[1] ?? "").replace(/-/g, "+").replace(/_/g, "/");
      const payload = JSON.parse(atob(encoded)) as { sub?: string };
      return { jwt, workspaceId: ws._id, userId: String(payload.sub ?? "") };
    });
  await expect.poll(read, { message: "the osionos session never landed", timeout: 30_000 }).not.toBeNull();
  return (await read()) as OsionosSession;
}

/** One bridge call with the session's JWT; the status is the caller's to judge. */
export async function bridgeCall(page: Page, s: OsionosSession, method: string, path: string, body?: unknown): Promise<BridgeResponse> {
  return page.evaluate(
    async ({ url, method, jwt, body }) => {
      const r = await fetch(url, {
        method,
        headers: { authorization: `Bearer ${jwt}`, "content-type": "application/json" },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      const text = await r.text();
      let json: unknown = {};
      try { json = text ? JSON.parse(text) : {}; } catch { json = { raw: text.slice(0, 300) }; }
      return { status: r.status, json: (Array.isArray(json) ? { items: json } : json) as Record<string, unknown> };
    },
    { url: `${BRIDGE_URL}${path}`, method, jwt: s.jwt, body },
  );
}

export interface Mount {
  dbId: string;
  name: string;
  engine: string;
}

/** The databases mounted on the caller's workspaces (GET /api/databases). */
export async function listMounts(page: Page, s: OsionosSession): Promise<Mount[]> {
  const body = await bridge(page, s, "GET", "/api/databases");
  return (body.databases ?? []) as Mount[];
}

/** One mount by its registered name; fails naming the ones that are there. */
export function mountNamed(mounts: readonly Mount[], name: string): Mount {
  const found = mounts.find((m) => m.name === name);
  if (!found) throw new Error(`mount ${name} is not listed (listed: ${mounts.map((m) => m.name).join(", ")})`);
  return found;
}

/** POST /api/databases/:dbId/tables/:table — one row op; returns the rows it answered with. */
export async function rowOp(page: Page, s: OsionosSession, dbId: string, table: string, body: Record<string, unknown>): Promise<Record<string, unknown>[]> {
  const res = await bridge(page, s, "POST", `/api/databases/${dbId}/tables/${encodeURIComponent(table)}`, body);
  return (res.rows ?? []) as Record<string, unknown>[];
}

/** GET status only, sent from Node with the page's session: for a probe whose 404 is an
 *  expected answer, which the page itself would log as a console error. */
export async function bridgeStatus(page: Page, s: OsionosSession, path: string): Promise<number> {
  const res = await page.request.get(`${BRIDGE_URL}${path}`, { headers: { authorization: `Bearer ${s.jwt}` } });
  return res.status();
}

/** A bridge call that must succeed (2xx); returns its JSON. */
export async function bridge(page: Page, s: OsionosSession, method: string, path: string, body?: unknown): Promise<Record<string, unknown>> {
  const res = await bridgeCall(page, s, method, path, body);
  expect(res.status, `${method} ${path} → ${JSON.stringify(res.json).slice(0, 200)}`).toBeLessThan(300);
  return res.json;
}

/** osionos opened as the demo account (login, signed handoff), with its bridge session. */
export async function openAsDemo(browser: Browser, query = ""): Promise<{ context: BrowserContext; page: Page; session: OsionosSession }> {
  const token = await loginOrRegister({ email: E2E_DEMO_EMAIL, password: E2E_DEMO_PASSWORD, username: "demo" });
  const { context, page } = await openOsionos(browser, query, { token });
  return { context, page, session: await osionosSession(page) };
}
