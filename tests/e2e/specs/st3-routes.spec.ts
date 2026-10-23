import AxeBuilder from "@axe-core/playwright";
import { readFileSync } from "node:fs";
import { expect, test } from "../lib/fixtures";

// ST3 — every public route (site-audit/routes.txt) in both themes at three widths: no console
// error, no serious or critical axe finding, and no sideways scroll on a phone.
// Caveat: /404 answers 404 by design, and Chromium logs that status as a console error, so that
// one message is ignored on that one route; any other error still fails it.

const routes = readFileSync(new URL("../site-audit/routes.txt", import.meta.url), "utf8")
  .split("\n")
  .map((line) => line.trim())
  .filter((line) => line !== "" && !line.startsWith("#"))
  .map((line) => line.split(/\s+/)[0] as string);

const OWN_404 = /^Failed to load resource: the server responded with a status of 404/;

for (const route of routes) {
  for (const colorScheme of ["light", "dark"] as const) {
    test(`ST3 ${route} (${colorScheme})`, async ({ browser, baseURL }) => {
      for (const width of [390, 768, 1440]) {
        const context = await browser.newContext({ viewport: { width, height: 900 }, colorScheme });
        const page = await context.newPage();
        const errors: string[] = [];
        page.on("console", (m) => {
          if (m.type() === "error" && !(route === "/404" && OWN_404.test(m.text()) && m.location().url === new URL(route, baseURL).href)) errors.push(m.text());
        });
        page.on("pageerror", (e) => errors.push(e.message));
        await page.goto(new URL(route, baseURL).href, { waitUntil: "load" });
        await page.waitForLoadState("networkidle", { timeout: 10_000 }).catch(() => undefined);

        const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
        expect(overflow, `${route} scrolls sideways at ${width}px`).toBeLessThanOrEqual(0);
        const axe = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"]).analyze();
        const severe = axe.violations.filter((v) => v.impact === "serious" || v.impact === "critical").map((v) => `${v.id} ×${v.nodes.length}`);
        expect(severe, `${route} axe at ${width}px`).toEqual([]);
        expect(errors, `${route} console at ${width}px`).toEqual([]);
        await context.close();
      }
    });
  }
}
