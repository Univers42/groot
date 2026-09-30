import { createAndOpenBoard, drawStroke, expectInk, REGION_A, regionInk, boardTitle } from "../lib/board";
import { expect, test } from "../lib/fixtures";
import { openWhiteboardTab } from "../lib/osionos";
import { openOsionos } from "../lib/session";

// DW9 — the DW8 flow, but the drawing side is the board embedded in osionos.
test("DW9 a board created and drawn on inside osionos reaches a second context", async ({ browser, consoleGuard }) => {
  const { context, page } = await openOsionos(browser);
  consoleGuard.watch(page, "osionos");
  const { board, frame } = await openWhiteboardTab(page);

  await createAndOpenBoard(board, boardTitle("dw9"));
  await expect(board.locator("canvas").first()).toBeVisible();
  await expect.poll(() => frame.url(), { message: "the embedded board never got its room" }).toMatch(/\/boards\/[^#]+#room=/);

  const other = await browser.newContext();
  const viewer = await other.newPage();
  consoleGuard.watch(viewer, "viewer");
  await viewer.goto(frame.url());
  await expect(viewer.getByRole("application", { name: "Board canvas" })).toBeVisible();

  expect(await regionInk(viewer, REGION_A), "viewer starts blank").toBeLessThan(0.005);
  await drawStroke(page, board, REGION_A);
  await expectInk(frame, REGION_A, "the stroke did not render in the embedded canvas");
  await expectInk(viewer, REGION_A, "the embedded stroke never reached the second context");

  await other.close();
  await context.close();
});
