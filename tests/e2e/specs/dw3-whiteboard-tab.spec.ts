import { boardTitle } from "../lib/board";
import { expect, test } from "../lib/fixtures";
import { openWhiteboardTab } from "../lib/osionos";
import { openOsionos } from "../lib/session";

// DW3 — the Whiteboard tab still shows a usable board list after the 8 s embed grace
// timer has fired (EmbedAppView LOAD_GRACE_MS); it once replaced a working pane.
test("DW3 Whiteboard tab shows the board list and gates + New Board on a title", async ({ browser, consoleGuard }) => {
  const { context, page } = await openOsionos(browser);
  consoleGuard.watch(page, "osionos");
  const { board } = await openWhiteboardTab(page);
  await expect(board.getByRole("heading", { name: "Your Boards" })).toBeVisible();

  await page.waitForTimeout(10_500); // deliberately past the 8 s grace timer
  await expect(page.getByTestId("embed-unavailable")).toHaveCount(0);
  await expect(board.getByRole("heading", { name: "Your Boards" })).toBeVisible();

  const create = board.getByRole("button", { name: "+ New Board" });
  await expect(create).toBeDisabled();
  await board.getByRole("textbox", { name: "New board title…" }).fill(boardTitle("dw3"));
  await expect(create).toBeEnabled();
  await context.close();
});
