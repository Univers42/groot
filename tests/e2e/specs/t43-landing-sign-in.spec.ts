import { PRISMATICA_URL } from "../lib/env";
import { expect, test } from "../lib/fixtures";

// T41: the landing probes /api/auth/refresh with no session and logs the 401. Only that.
const T41_REFRESH_401 = /^Failed to load resource: the server responded with a status of 401 \(Unauthorized\) @ https?:\/\/[^/]+\/api\/auth\/refresh$/;

// T43 — 5333085 moved themeIcon into src/lib/theme-config.ts without importing it back, so
// the Layout script threw a ReferenceError before it bound the Sign in handler. `astro build`
// never typechecks, so only a browser sees it: no uncaught error, and the form opens.
test("T43 landing loads with no uncaught error and Sign in opens the form", async ({ page, consoleGuard }) => {
  consoleGuard.watch(page, "landing", T41_REFRESH_401);
  await page.goto(PRISMATICA_URL);
  await page.getByRole("banner").getByRole("button", { name: "Sign in", exact: true }).click();
  const portal = page.getByRole("dialog", { name: "Prismatica workspace portal" });
  await expect(portal.getByRole("textbox", { name: "Email" }), "Sign in did not open the form").toBeVisible();
  await expect(portal.getByRole("textbox", { name: "Password" })).toBeVisible();
});
