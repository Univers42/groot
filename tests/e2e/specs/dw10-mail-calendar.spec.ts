import { request, type Locator, type Page } from "@playwright/test";
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

/** Collapses the sidebar to the activity rail. Waits for either state first: right after
 *  the handoff neither is rendered yet, and an instant check would decide on nothing. */
async function toRail(page: Page): Promise<void> {
  const collapse = page.getByRole("button", { name: "Collapse to rail" });
  const rail = page.getByRole("tablist", { name: "Activity bar" });
  await expect(collapse.or(rail).first()).toBeVisible();
  if (await collapse.isVisible()) await collapse.click();
  await expect(rail).toBeVisible();
}

/** Rail → Marketplace → the app's listing (a dialog: Install / Open / Uninstall). Picking a
 *  panel from the rail expands the sidebar into it, so "open" is its search box, not the tab. */
async function openListing(page: Page, app: string): Promise<Locator> {
  const search = page.getByPlaceholder("Search apps in Marketplace");
  const rail = page.getByRole("tablist", { name: "Activity bar" });
  await expect(search.or(rail).or(page.getByRole("button", { name: "Collapse to rail" })).first()).toBeVisible();
  if (!(await search.isVisible())) {
    await toRail(page);
    await rail.getByRole("tab", { name: "Marketplace", exact: true }).click();
    await expect(search, "the Marketplace panel did not open").toBeVisible();
  }
  await page.getByRole("button", { name: new RegExp(`^${app} `) }).first().click();
  const listing = page.getByRole("dialog");
  await expect(listing, `${app} listing did not open`).toBeVisible();
  return listing;
}

async function closeListing(page: Page, listing: Locator): Promise<void> {
  await page.keyboard.press("Escape");
  await expect(listing).toBeHidden();
}

// DW10 — Mail and Calendar are opt-in (make mail-up / calendar-up): absent → SKIP, never pass.
// They are Marketplace apps: a user reaches them only after installing one, which adds a
// rail entry (ActivityRail.tsx:110) and an "osionos apps" sidebar row (OsionosAppsSection.tsx);
// the static RAIL_APP_ITEMS in railItems.ts are never rendered.
// Each run installs, checks, and uninstalls, so the install path is exercised every time.
for (const [app, url] of [["Mail", MAIL_URL], ["Calendar", CALENDAR_URL]] as const) {
  test(`DW10 ${app} embed pane is still visible and clickable 15 s after opening`, async ({ browser, consoleGuard }) => {
    const reason = await unreachable(url);
    if (reason) console.log(`[DW10 SKIP] ${app} is opt-in and not running: ${reason}`);
    test.skip(reason !== "", `${app} is opt-in and not running: ${reason}`);

    const { context, page } = await openOsionos(browser);
    consoleGuard.watch(page, "osionos");
    const railEntry = page.getByRole("tablist", { name: "Activity bar" }).getByRole("tab", { name: app, exact: true });
    const listing = await openListing(page, app);
    const uninstall = listing.getByRole("button", { name: "Uninstall", exact: true });
    if (await uninstall.isVisible()) {
      console.log(`[DW10] ${app} was already installed (a previous teardown failed); uninstalling first`);
      await uninstall.click();
    }
    await listing.getByRole("button", { name: "Install", exact: true }).click();
    try {
      await closeListing(page, listing);
      await toRail(page);
      await expect(railEntry, `installing ${app} added no rail entry`).toBeVisible();
      await railEntry.click();
      const pane = page.locator(`iframe[title="${app}"]`);
      await expect(pane).toBeVisible();

      await page.waitForTimeout(15_000); // deliberately past the 8 s grace timer
      await expect(page.getByTestId("embed-unavailable")).toHaveCount(0);
      await expect(pane).toBeVisible();
      await page.frameLocator(`iframe[title="${app}"]`).locator("body").click();
      await expect(pane).toBeVisible();
    } finally {
      const again = await openListing(page, app);
      await again.getByRole("button", { name: "Uninstall", exact: true }).click();
      await expect(again.getByRole("button", { name: "Install", exact: true }), `${app} did not uninstall`).toBeVisible();
      await closeListing(page, again);
      await context.close();
    }
  });
}
