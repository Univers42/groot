import { expect, test, type Page } from "@playwright/test";
import { ARLET, openAs } from "./arlet";

// The Phase 4 product captures (groot docs/redesign/PLAN.md §6.1), shot from the Arlet demo on
// the linked backend at 1440×900 @2x. Masters land in test-results/media-masters/<id>.png;
// scripts/media/capture.sh turns them into the site's sizes. Only the shots whose data osionos
// can show today are here: S2–S7 and S10 read the demo's mounted databases, which the bridge
// cannot list over the Funnel until ADR 0004's deploy lands (docs/redesign/DECISIONS.md D-044).

const PAGES = JSON.parse(process.env.E2E_ARLET_PAGES ?? "{}") as Record<string, string>;
const master = (id: string) => `test-results/media-masters/${id}.png`;

async function inWorkspace(page: Page, name: string): Promise<void> {
  const switcher = page.getByRole("complementary", { name: "Sidebar" }).getByRole("button", { name: /^◈ / }).first();
  await expect(switcher).toBeVisible({ timeout: 45_000 });
  await page.getByRole("button", { name: "Dismiss invitation" }).click({ timeout: 5_000 }).catch(() => undefined);
  await switcher.click();
  await page.getByRole("button", { name: `A ${name}` }).click();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("complementary", { name: "Sidebar" }).getByRole("button", { name: `◈ ${name}` })).toBeVisible();
}

async function openPage(page: Page, title: string): Promise<void> {
  const search = page.getByRole("combobox", { name: "Search pages or run a command" });
  await search.click();
  await search.fill(title);
  await page.getByRole("option", { name: new RegExp(title) }).first().click();
  await expect(page.locator('textarea[aria-label="Page title"]:visible').first()).toHaveValue(title, { timeout: 20_000 });
  await search.fill("");
  await page.keyboard.press("Escape");
}

/** The pane settles (lazy chunks, relation chips) before the shot; then the pointer leaves it. */
async function shoot(page: Page, id: string): Promise<void> {
  await expect(page.getByRole("status", { name: "Loading" })).toHaveCount(0);
  await page.mouse.move(1430, 890);
  await page.waitForTimeout(1500);
  await page.screenshot({ path: master(id), animations: "disabled", caret: "hide" });
}

test.describe("Arlet captures", () => {
  test.skip(!ARLET.ines.password, "run through scripts/media/capture.sh");

  test("S1 home dashboard", async ({ browser }) => {
    const { context, page } = await openAs(browser, "ines");
    await inWorkspace(page, "Arlet — Operations");
    await page.getByRole("treeitem", { name: "🏠 Arlet — Operations" }).click();
    await expect(page.locator('textarea[aria-label="Page title"]:visible').first()).toHaveValue("Arlet — Operations");
    await shoot(page, "S1");
    await context.close();
  });

  test("S8 academy note", async ({ browser }) => {
    const { context, page } = await openAs(browser, "ines");
    await inWorkspace(page, "Arlet — Operations");
    await openPage(page, "The cost of a second source");
    await shoot(page, "S8");
    await context.close();
  });

  test("S9 graph centred on the supplier switch", async ({ browser }) => {
    const id = PAGES["decision-supplier-switch"];
    test.skip(!id, "E2E_ARLET_PAGES has no decision-supplier-switch");
    const { context, page } = await openAs(browser, "ines");
    await inWorkspace(page, "Arlet — Operations");
    await page.getByRole("tablist", { name: "Activity bar" }).getByRole("tab", { name: "Home", exact: true }).click();
    await page.getByRole("menuitem", { name: "Second Brain" }).click();
    const view = page.locator('[data-testid="graph-studio-view"]');
    await expect(view).toHaveAttribute("data-graph-state", "ready", { timeout: 60_000 });
    const focused = await view.locator("graph-studio").evaluate(
      (el, nodeId) => (el as unknown as { focusNode(id: string): Promise<boolean> }).focusNode(nodeId),
      `osionos:osionos_pages:${id}`,
    );
    expect(focused, "the supplier-switch decision is a node").toBe(true);
    await page.waitForTimeout(3000);
    await shoot(page, "S9");
    await context.close();
  });

  test("S11 Jules's view", async ({ browser }) => {
    const { context, page } = await openAs(browser, "jules");
    await inWorkspace(page, "Arlet — Finance review");
    await page.getByRole("treeitem", { name: /Q4 supplier review/ }).click();
    await expect(page.locator('textarea[aria-label="Page title"]:visible').first()).toHaveValue("Q4 supplier review");
    await shoot(page, "S11");
    await context.close();
  });
});
