import { expect, test as base, type Page, type Response } from "@playwright/test";
import { BRIDGE_URL, CALENDAR_URL, GATEWAY_URL, KONG_URL, MAIL_URL, OSIONOS_URL, PRISMATICA_URL, WHITEBOARD_URL } from "../lib/env";
import { open } from "./store";

type App = { name: string; url: string; optIn?: boolean; api?: boolean };

const APPS: App[] = [
  { name: "website", url: PRISMATICA_URL },
  { name: "editor", url: OSIONOS_URL },
  { name: "whiteboard", url: WHITEBOARD_URL },
  { name: "mail", url: MAIL_URL, optIn: true },
  { name: "calendar", url: CALENDAR_URL, optIn: true },
  { name: "bridge", url: `${BRIDGE_URL}/api/auth/bridge/health`, api: true },
  { name: "auth gateway", url: `${GATEWAY_URL}/api/auth/health`, api: true },
  { name: "API docs", url: `${KONG_URL}/docs/`, api: true },
];

const test = base.extend<{ page: Page }>({
  page: async ({ browserName }, use) => {
    const browser = await open(browserName, true);
    await use(browser.context.pages()[0] ?? (await browser.context.newPage()));
    await browser.close();
  },
});

// plainRequests PAGE — every request or socket that leaves in clear. Starts before navigation, so
// a redirect through http:// or a mixed-content script is caught too.
function plainRequests(page: Page): string[] {
  const plain: string[] = [];
  page.on("request", (r) => {
    if (/^(http|ws):/.test(r.url())) plain.push(r.url());
  });
  page.on("websocket", (w) => {
    if (w.url().startsWith("ws:")) plain.push(w.url());
  });
  return plain;
}

async function reach(page: Page, app: App): Promise<Response> {
  let response: Response | null;
  try {
    response = await page.goto(app.url, { waitUntil: "domcontentloaded" });
  } catch (error) {
    if (app.optIn && /ECONNREFUSED|CONNECTION_REFUSED|NS_ERROR_CONNECTION_REFUSED/.test(String(error))) {
      test.skip(true, `${app.name} is opt-in and not running: make mail-up calendar-up`);
    }
    throw error;
  }
  expect(response, `${app.name} answered`).not.toBeNull();
  return response as Response;
}

for (const app of APPS) {
  test(`${app.name}: reachable over trusted HTTPS, nothing in plain text`, async ({ page }) => {
    const plain = plainRequests(page);
    const response = await reach(page, app);
    // A backend-less run answers 502 from the APIs through the edge: TLS is what this test proves.
    if (!app.api) expect(response.status(), `${app.name} status`).toBeLessThan(400);
    expect(new URL(page.url()).protocol).toBe("https:");
    await page.waitForLoadState("load");
    expect(plain, `${app.name} plain-text requests`).toEqual([]);
  });

  if (app.api) continue;

  test(`${app.name}: every link works and every control can be clicked`, async ({ page }) => {
    const plain = plainRequests(page);
    await reach(page, app);
    await page.waitForLoadState("load");
    const origin = new URL(app.url).origin;
    const links = await page.locator("a[href]").evaluateAll((anchors) => anchors.map((a) => (a as HTMLAnchorElement).href));
    const controls = page.locator("a:visible, button:visible, [role=button]:visible, input:visible, textarea:visible, select:visible");
    const count = await controls.count();
    for (let i = 0; i < Math.min(count, 60); i++) {
      await expect(controls.nth(i), `control ${i} of ${count} on ${app.name}`).toBeAttached();
      await controls.nth(i).scrollIntoViewIfNeeded();
      await controls.nth(i).click({ trial: true, timeout: 5_000 });
    }
    for (const href of [...new Set(links)].filter((l) => l.startsWith(origin) && !l.includes("#")).slice(0, 20)) {
      const response = await page.goto(href, { waitUntil: "domcontentloaded" });
      expect(response?.status(), href).toBeLessThan(400);
    }
    expect(plain, `${app.name} plain-text requests`).toEqual([]);
  });
}

// The negative that gives the rest its meaning: the same browser without the CA must refuse.
test("a browser without the local CA is refused", async ({ browserName }) => {
  const browser = await open(browserName, false);
  const page = browser.context.pages()[0] ?? (await browser.context.newPage());
  const failure = await page.goto(PRISMATICA_URL).then(
    () => "",
    (error) => String(error),
  );
  await browser.close();
  expect(failure).toMatch(/ERR_CERT_AUTHORITY_INVALID|SEC_ERROR_UNKNOWN_ISSUER/);
});
