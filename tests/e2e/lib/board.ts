import { expect, type Frame, type FrameLocator, type Locator, type Page } from "@playwright/test";
import { BOARD_PREFIX } from "./env";

export type Region = { left: number; top: number; right: number; bottom: number };

export function boardTitle(spec: string): string {
  return `${BOARD_PREFIX}${spec}-${Date.now().toString(36)}`;
}

/** Types a title on the board list, creates the board and opens it. */
export async function createAndOpenBoard(root: Page | FrameLocator, title: string): Promise<void> {
  await root.getByRole("textbox", { name: "New board title…" }).fill(title);
  await root.getByRole("button", { name: "+ New Board" }).click();
  await root.getByRole("link", { name: new RegExp(title) }).click();
  await expect(root.getByRole("application", { name: "Board canvas" })).toBeVisible();
}

/** The canvas's on-screen box, in main-page coordinates (so iframes work too). */
export async function canvasBox(canvas: Locator) {
  await expect(canvas).toBeVisible();
  const box = await canvas.boundingBox();
  if (!box) throw new Error("board canvas has no layout box");
  return box;
}

/** A freehand stroke with the Draw tool, across the middle of `region` (canvas-relative). */
export async function drawStroke(page: Page, board: Page | FrameLocator, region: Region): Promise<void> {
  await board.getByRole("button", { name: /^Draw \(/ }).click();
  const box = await canvasBox(board.locator("canvas").first());
  const y = box.y + (region.top + region.bottom) / 2;
  await page.mouse.move(box.x + region.left + 10, y);
  await page.mouse.down();
  for (let x = region.left + 10; x <= region.right - 10; x += 10) {
    await page.mouse.move(box.x + x, y + ((x / 10) % 2 === 0 ? -8 : 8));
  }
  await page.mouse.up();
}

/**
 * Fraction of `region` (canvas-relative CSS px) that differs from the canvas corner.
 * Adapted from apps/drawnosaurus/e2e/probes.ts `regionInk`, which the runner can't import.
 * Caveat: the corner is the background reference, so anything the app paints in the
 * top-left pixel (a vignette, a grid line) shifts every reading; the threshold of 12 per
 * channel also hides a stroke drawn in a colour within 12 of the background.
 */
export function regionInk(target: Page | Frame, region: Region): Promise<number> {
  return target.evaluate((area) => {
    const canvas = document.querySelector("canvas");
    const ctx = canvas?.getContext("2d");
    if (!canvas || !ctx) throw new Error("no 2d board canvas");
    const box = canvas.getBoundingClientRect();
    const sx = canvas.width / box.width;
    const sy = canvas.height / box.height;
    const w = Math.round((area.right - area.left) * sx);
    const h = Math.round((area.bottom - area.top) * sy);
    const corner = ctx.getImageData(0, 0, 1, 1).data;
    const { data } = ctx.getImageData(Math.round(area.left * sx), Math.round(area.top * sy), w, h);
    let ink = 0;
    for (let i = 0; i < data.length; i += 4) {
      if ([0, 1, 2].some((c) => Math.abs(data[i + c]! - corner[c]!) > 12)) ink += 1;
    }
    return ink / (w * h);
  }, region);
}

/** Two regions well inside any canvas this suite opens (≥ 1100×750). */
export const REGION_A: Region = { left: 300, top: 250, right: 500, bottom: 330 };
export const REGION_B: Region = { left: 600, top: 450, right: 800, bottom: 530 };

/** Waits until `region` shows ink on `target` within the realtime budget. */
export async function expectInk(target: Page | Frame, region: Region, message: string): Promise<void> {
  await expect.poll(() => regionInk(target, region), { message, timeout: 5_000, intervals: [100, 250] }).toBeGreaterThan(0.005);
}
