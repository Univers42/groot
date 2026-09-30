import { request } from "@playwright/test";
import { CALENDAR_URL, MAIL_URL } from "../lib/env";
import { expect, test } from "../lib/fixtures";
import { openOsionos } from "../lib/session";

/** "" when the app answers; otherwise why not. The proxy answers 502 for a stopped app. */
async function unreachable(url: string): Promise<string> {
  const api = await request.newContext();
  try {
    const res = await api.get(url, { timeout: 5_000, maxRedirects: 0 });
    return res.status() < 500 ? "" : `${url} answered HTTP ${res.status()}`;
  } catch (error) {
    return `${url} unreachable: ${(error as Error).message.split("\n")[0]}`;
  } finally {
    await api.dispose();
  }
}

// DW10 — Mail and Calendar are opt-in (make mail-up / calendar-up): absent → SKIP, never pass.
for (const [app, url] of [["Mail", MAIL_URL], ["Calendar", CALENDAR_URL]] as const) {
  test(`DW10 ${app} embed pane is still visible and clickable 15 s after opening`, async ({ browser, consoleGuard }) => {
    const reason = await unreachable(url);
    if (reason) console.log(`[DW10 SKIP] ${app} is opt-in and not running: ${reason}`);
    test.skip(reason !== "", `${app} is opt-in and not running: ${reason}`);

    const { context, page } = await openOsionos(browser);
    consoleGuard.watch(page, "osionos");
    await page.getByRole("button", { name: "Collapse to rail" }).click();
    await page.getByRole("tab", { name: app, exact: true }).click();
    const pane = page.locator(`iframe[title="${app}"]`);
    await expect(pane).toBeVisible();

    await page.waitForTimeout(15_000);
    await expect(page.getByTestId("embed-unavailable")).toHaveCount(0);
    await expect(pane).toBeVisible();
    await page.frameLocator(`iframe[title="${app}"]`).locator("body").click();
    await expect(pane).toBeVisible();
    await context.close();
  });
}
