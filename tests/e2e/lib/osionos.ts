import { expect, type Frame, type FrameLocator, type Page } from "@playwright/test";

/**
 * Resolves once the shell has stopped reflowing. A lazy pane chunk (DatabaseBlock) ships
 * a second Tailwind build whose :root redefines --font-sans/--spacing/--text-sm, so the
 * whole top bar shrinks when it lands; an open menubar then hover-switches to whatever
 * button slid under the cursor and unmounts the menu mid-click (T38). That chunk arrives
 * with the Home page, and Vite resolves a lazy import only after its CSS has loaded, so
 * the page's title on screen with no LoadingPane left means the reflow is done.
 * The title is the positive anchor: the outer LazyMainContent fallback is a bare spinner
 * with no status role, which a bare toHaveCount(0) would wave through. Not the pane's
 * "Title bar" region: the pane draws it before the lazy chunk lands. Not the breadcrumbs:
 * since the workbench title bar (osionos 924ffee1) only page tabs draw them, Home does not.
 * Caveat: a chunk that lazy-loads later (on scroll, on a timer) is not awaited, and a Home
 * set to the graph, database or workspace view draws no page title, so this times out there.
 */
async function waitForSettledShell(page: Page): Promise<void> {
  const shell = page.getByTestId("app-shell");
  await expect(shell.getByRole("main").getByRole("textbox", { name: "Page title" })).toBeVisible();
  await expect(shell.getByRole("status", { name: "Loading" })).toHaveCount(0);
}

/** osionos → View → Whiteboard. Returns the embed as a FrameLocator and as a Frame. */
export async function openWhiteboardTab(page: Page): Promise<{ board: FrameLocator; frame: Frame }> {
  await waitForSettledShell(page);
  await page.getByRole("navigation", { name: "Application menu" }).getByRole("button", { name: "View", exact: true }).click();
  await expect(page.getByRole("menuitem", { name: "Home", exact: true }), "the View menu did not open").toBeVisible();
  const entry = page.getByRole("menuitem", { name: "Whiteboard", exact: true });
  // The item is withheld when osio.whiteboard is off or VITE_WHITEBOARD_APP_URL is blank.
  await expect(entry, "View menu has no Whiteboard entry").toBeVisible({ timeout: 2_000 });
  await entry.click();
  const iframe = page.locator('iframe[title="Whiteboard"]');
  await expect(iframe).toBeVisible();
  const frame = await (await iframe.elementHandle())?.contentFrame();
  if (!frame) throw new Error("Whiteboard iframe has no content frame");
  return { board: page.frameLocator('iframe[title="Whiteboard"]'), frame };
}
