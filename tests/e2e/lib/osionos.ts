import { expect, type Frame, type FrameLocator, type Page } from "@playwright/test";

/** osionos → View → Whiteboard. Returns the embed as a FrameLocator and as a Frame. */
export async function openWhiteboardTab(page: Page): Promise<{ board: FrameLocator; frame: Frame }> {
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
