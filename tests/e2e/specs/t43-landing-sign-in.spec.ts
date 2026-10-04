import { PRISMATICA_URL } from "../lib/env";
import { expect, test } from "../lib/fixtures";

// T43 — 5333085 moved themeIcon into src/lib/theme-config.ts without importing it back, so
// the Layout script threw a ReferenceError before it bound the Sign in handler. `astro build`
// never typechecks, so only a browser sees it: zero console errors, and the form opens.
test("T43 landing loads with zero console errors and Sign in opens the form", async ({ page, consoleGuard }) => {
  consoleGuard.watch(page, "landing");
  await page.goto(PRISMATICA_URL);
  await page.getByRole("banner").getByRole("button", { name: "Sign in", exact: true }).click();
  const portal = page.getByRole("dialog", { name: "Prismatica workspace portal" });
  await expect(portal.getByRole("textbox", { name: "Email" }), "Sign in did not open the form").toBeVisible();
  await expect(portal.getByRole("textbox", { name: "Password" })).toBeVisible();
});
