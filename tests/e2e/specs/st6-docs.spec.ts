import { expect, test } from "../lib/fixtures";

// ST6 — the docs as one static page per doc (scripts/vault-page.mjs): links are real URLs that
// work without JavaScript, an old single-page link (/docs/#path) still lands on its doc, search
// reaches a page, and the arrow keys scroll instead of leaving the page.
test.describe("ST6 docs pages", () => {
  test("a link from the old single-page vault lands on that doc's page", async ({ page, consoleGuard }) => {
    consoleGuard.watch(page, "legacy");
    await page.goto("/docs/#guides/getting-started");
    await expect(page).toHaveURL(/\/docs\/guides\/getting-started\/$/);
    await expect(page.locator("article[data-doc]")).toHaveAttribute("data-doc", "guides/getting-started");
  });

  test("the tree and in-doc links are real pages, also without JavaScript", async ({ browser }) => {
    const context = await browser.newContext({ javaScriptEnabled: false });
    const page = await context.newPage();
    await page.goto("/docs/");
    await page.getByRole("navigation", { name: "Documents" }).getByRole("link", { name: "Getting started" }).first().click();
    await expect(page).toHaveURL(/\/docs\/guides\/getting-started\/$/);
    await expect(page.getByRole("navigation", { name: "Documents" }).locator('[aria-current="page"]')).toHaveAttribute("data-nav", "guides/getting-started");
    await page.goto("/docs/");
    // force: Playwright's stability check never settles on a JS-disabled page here, though the
    // link's box is fixed after 250 ms with JS off and on (measured 2026-10-15); the click is real.
    await page.locator('article a[href="/docs/reference/markengine/"]').first().click({ force: true });
    await expect(page).toHaveURL(/\/docs\/reference\/markengine\/$/);
    await context.close();
  });

  test("search jumps to a doc", async ({ page, consoleGuard }) => {
    consoleGuard.watch(page, "search");
    await page.goto("/docs/");
    await page.keyboard.press("/");
    await page.getByRole("textbox", { name: "Search the docs" }).fill("getting started");
    await page.keyboard.press("Enter");
    await expect(page).toHaveURL(/\/docs\/guides\/getting-started\/(#.*)?$/);
  });

  test("the arrow keys scroll the page and do not change it", async ({ page, consoleGuard }) => {
    consoleGuard.watch(page, "arrows");
    await page.goto("/docs/graph/performance-tuning/");
    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("ArrowDown");
    await expect(page).toHaveURL(/\/docs\/graph\/performance-tuning\/$/);
  });

  test("every page is small: the doc, not the whole vault", async ({ request }) => {
    for (const path of ["/docs/", "/docs/graph/performance-tuning/"]) {
      const body = await (await request.get(path)).text();
      expect(body.length, path).toBeLessThan(150_000);
      expect(body.match(/<article\b/g), path).toHaveLength(1);
    }
  });
});
