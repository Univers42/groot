import { expect, test } from "../lib/fixtures";

// ST1 — the two-click path of PLAN §1: the tour opens in place (click 1) and its call to action
// opens sign-up (click 2). Header navigation lands on the sections it names. Without JavaScript
// the tour button is a link to /tour, which carries the same chapters.
test.describe("ST1 two-click path", () => {
  test("header links land on their sections", async ({ page, consoleGuard }) => {
    consoleGuard.watch(page, "home");
    await page.goto("/");
    const nav = page.getByRole("banner").getByRole("navigation", { name: "Main" });
    for (const [label, id] of [["Product", "product"], ["Run locally", "run"]] as const) {
      await nav.getByRole("link", { name: label }).click();
      await expect(page).toHaveURL(new RegExp(`#${id}$`));
      await expect(page.locator(`#${id}`)).toBeInViewport();
    }
    await expect(nav.getByRole("link", { name: "Docs" })).toHaveAttribute("href", "/docs/");
  });

  test("the tour opens in place, and its call to action opens sign-up", async ({ page, consoleGuard }) => {
    consoleGuard.watch(page, "home");
    await page.goto("/");
    await page.getByRole("link", { name: "Watch the 75-second tour" }).click();
    const tour = page.getByRole("dialog", { name: /One week at Arlet/ });
    await expect(tour).toBeVisible();
    await expect(page).toHaveURL(/\/$/);
    await expect(tour.getByRole("list", { name: "Chapters" }).getByRole("listitem")).toHaveCount(6);

    const video = tour.locator("video");
    if ((await video.count()) > 0) {
      const cues = await video.evaluate(async (element: HTMLVideoElement) => {
        const track = element.textTracks[0];
        if (!track) return 0;
        track.mode = "showing";
        for (let i = 0; i < 50 && !track.cues?.length; i++) await new Promise((r) => setTimeout(r, 100));
        return track.cues?.length ?? 0;
      });
      expect(cues, "the captions track has cues").toBeGreaterThan(0);
    } else {
      await expect(tour.getByText(/recording is made from the demo account/)).toBeVisible();
    }

    await tour.getByRole("button", { name: "Create your workspace" }).click();
    await expect(tour).toBeHidden();
    const portal = page.getByRole("dialog", { name: "Prismatica workspace portal" });
    await expect(portal.getByRole("textbox", { name: "Email" })).toBeVisible();
    await expect(portal.locator("#portal-confirm-password")).toBeVisible();
  });

  test("Escape closes the tour and focus returns to the button that opened it", async ({ page }) => {
    await page.goto("/");
    const opener = page.getByRole("link", { name: "Watch the 75-second tour" });
    await opener.click();
    await page.keyboard.press("Escape");
    await expect(page.getByRole("dialog", { name: /One week at Arlet/ })).toBeHidden();
    await expect(opener).toBeFocused();
  });

  test("without JavaScript the tour is a page with the same chapters", async ({ browser }) => {
    const context = await browser.newContext({ javaScriptEnabled: false });
    const page = await context.newPage();
    await page.goto("/");
    await page.getByRole("link", { name: "Watch the 75-second tour" }).click();
    await expect(page).toHaveURL(/\/tour\/$/);
    await expect(page.getByRole("heading", { level: 1 })).toHaveText(/One week at Arlet/);
    await expect(page.getByRole("list", { name: "Chapters" }).getByRole("listitem")).toHaveCount(6);
    await context.close();
  });
});
