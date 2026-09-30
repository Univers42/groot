import { expect, type Frame, type FrameLocator, type Page } from "@playwright/test";

/** osionos → View → Whiteboard. Returns the embed as a FrameLocator and as a Frame. */
export async function openWhiteboardTab(page: Page): Promise<{ board: FrameLocator; frame: Frame }> {
  await page.getByRole("navigation", { name: "Application menu" }).getByRole("button", { name: "View", exact: true }).click();
  await page.getByRole("menuitem", { name: "Whiteboard", exact: true }).click();
  const iframe = page.locator('iframe[title="Whiteboard"]');
  await expect(iframe).toBeVisible();
  const frame = await (await iframe.elementHandle())?.contentFrame();
  if (!frame) throw new Error("Whiteboard iframe has no content frame");
  return { board: page.frameLocator('iframe[title="Whiteboard"]'), frame };
}
