import { expect, test } from "../lib/fixtures";
import type { Page } from "@playwright/test";

// ST2 — motion is optional (PLAN §3): with prefers-reduced-motion nothing animates, before or after
// a scroll, and nothing waits for motion or JavaScript to become visible. With motion allowed,
// every animation is finite: the convergence plays once and never loops.

async function scrollThrough(page: Page): Promise<void> {
  const height = await page.evaluate(() => document.documentElement.scrollHeight);
  for (let y = 0; y <= height; y += 600) {
    await page.evaluate((top) => window.scrollTo(0, top), y);
    await page.waitForTimeout(50);
  }
}

// Elements in <main> that occupy space but paint nothing: the "blank below the fold" defect.
async function invisibleContent(page: Page): Promise<string[]> {
  return page.evaluate(() =>
    [...document.querySelectorAll("main *")]
      .filter((element) => {
        const box = element.getBoundingClientRect();
        if (box.width === 0 || box.height === 0) return false;
        const style = getComputedStyle(element);
        return style.visibility === "hidden" || Number(style.opacity) === 0;
      })
      .map((element) => `${element.tagName.toLowerCase()}.${element.className}`),
  );
}

test.describe("ST2 reduced motion", () => {
  test.use({ reducedMotion: "reduce" });

  test("no animation runs, before or after a scroll, and nothing is invisible", async ({ page, consoleGuard }) => {
    consoleGuard.watch(page, "home");
    await page.goto("/");
    expect(await page.evaluate(() => document.getAnimations().length)).toBe(0);
    await scrollThrough(page);
    expect(await page.evaluate(() => document.getAnimations().length)).toBe(0);
    expect(await invisibleContent(page)).toEqual([]);
  });
});

test("with motion allowed, every animation is finite", async ({ page }) => {
  await page.goto("/");
  await scrollThrough(page);
  const infinite = await page.evaluate(() =>
    document.getAnimations().filter((a) => a.effect?.getComputedTiming().iterations === Infinity).length,
  );
  expect(infinite).toBe(0);
});

test("without JavaScript every view is visible, under its own heading", async ({ browser }) => {
  const context = await browser.newContext({ javaScriptEnabled: false });
  const page = await context.newPage();
  await page.goto("/");
  const views = page.locator("#views");
  for (const name of ["Table", "Board", "Calendar", "Chart"]) {
    await expect(views.getByRole("heading", { level: 3, name })).toBeVisible();
  }
  await expect(views.getByRole("tablist")).toBeHidden();
  await expect(page.getByRole("banner").getByRole("button", { name: "Sign in" })).toBeHidden();
  expect(await invisibleContent(page)).toEqual([]);
  await context.close();
});
