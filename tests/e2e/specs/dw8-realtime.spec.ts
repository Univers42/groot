import { createAndOpenBoard, drawStroke, expectInk, REGION_A, REGION_B, regionInk, boardTitle } from "../lib/board";
import { WHITEBOARD_URL } from "../lib/env";
import { expect, test } from "../lib/fixtures";

// DW8 — two independent browsers on one board at :3007 see each other's strokes live.
test("DW8 a stroke in either context appears in the other within 5 s", async ({ browser, consoleGuard }) => {
  const a = await browser.newContext();
  const b = await browser.newContext();
  const pageA = await a.newPage();
  const pageB = await b.newPage();
  consoleGuard.watch(pageA, "A");
  consoleGuard.watch(pageB, "B");

  await pageA.goto(WHITEBOARD_URL);
  await createAndOpenBoard(pageA, boardTitle("dw8"));
  await expect(pageA).toHaveURL(/#room=/); // the share link is a capability URL
  await pageB.goto(pageA.url());
  await expect(pageB.getByRole("application", { name: "Board canvas" })).toBeVisible();

  expect(await regionInk(pageB, REGION_A), "B starts blank").toBeLessThan(0.005);
  await drawStroke(pageA, pageA, REGION_A);
  await expectInk(pageB, REGION_A, "A's stroke never reached B");

  expect(await regionInk(pageA, REGION_B), "A starts blank there").toBeLessThan(0.005);
  await drawStroke(pageB, pageB, REGION_B);
  await expectInk(pageA, REGION_B, "B's stroke never reached A");

  await a.close();
  await b.close();
});
