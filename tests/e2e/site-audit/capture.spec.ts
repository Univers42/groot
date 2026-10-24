import { expect, test, type Browser, type Page } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";
import { mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// One test per public route: at each width, a screenshot, the axe violations and the console
// errors, written under test-results/site-audit/<label>/ for scripts/site-audit.sh to keep.
// Each width is shot three times: as a first visit sees it (light), with prefers-reduced-motion,
// and in the dark colour scheme (with its own axe pass, since contrast differs per theme). The
// baseline site's scroll-driven reveals started at opacity 0 and a full-page screenshot never
// scrolls, so only the reduced capture showed what was below the fold.
// Caveat: a full-page screenshot taller than MAX_CAPTURE_PX is cut at that height (Chromium
// cannot raster an unbounded page); the record says so with `truncated: true`.

const LABEL = process.env.E2E_SITE_AUDIT_LABEL ?? "baseline";
const OUT = join("test-results", "site-audit", LABEL);
const WIDTHS = [390, 768, 1440] as const;
const MAX_CAPTURE_PX = 12_000;

const routes = readFileSync(new URL("./routes.txt", import.meta.url), "utf8")
  .split("\n")
  .map((line) => line.trim())
  .filter((line) => line !== "" && !line.startsWith("#"))
  .map((line) => line.split(/\s+/)[0] as string);

const slugOf = (route: string): string =>
  route === "/" ? "home" : route.replace(/^\/|\/$/g, "").replace(/\//g, "-");

interface WidthRecord {
  status: number | null;
  screenshot: string;
  reducedScreenshot: string;
  darkScreenshot: string;
  truncated: boolean;
  pageHeight: number;
  // Document wider than the viewport, in px: content a phone user has to scroll sideways to see.
  overflowPx: number;
  consoleErrors: string[];
  axe: AxeFinding[];
  axeDark: AxeFinding[];
}

type AxeFinding = { id: string; impact: string | null; nodes: number; help: string };
const AXE_TAGS = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"];

// Settle the page, then shoot it full-height (or cut at MAX_CAPTURE_PX). Returns the page height.
async function settleAndShoot(page: Page, width: number, path: string): Promise<number> {
  await page.waitForLoadState("networkidle", { timeout: 15_000 }).catch(() => undefined);
  await page.evaluate(() => document.fonts.ready);
  const height = await page.evaluate(() => document.documentElement.scrollHeight);
  await page.screenshot({
    path,
    type: "jpeg",
    quality: 70,
    animations: "disabled",
    ...(height > MAX_CAPTURE_PX ? { clip: { x: 0, y: 0, width, height: MAX_CAPTURE_PX } } : { fullPage: true }),
  });
  return height;
}

async function axeFindings(page: Page): Promise<AxeFinding[]> {
  const result = await new AxeBuilder({ page }).withTags(AXE_TAGS).analyze();
  return result.violations.map((v) => ({ id: v.id, impact: v.impact ?? null, nodes: v.nodes.length, help: v.help }));
}

// One more shot of the route in a variant context (reduced motion, or the dark scheme); returns
// the axe findings of that variant when asked to.
async function shootVariant(
  browser: Browser,
  target: { url: string; width: number; path: string },
  variant: { reducedMotion?: "reduce"; colorScheme?: "dark" },
  withAxe = false,
): Promise<AxeFinding[]> {
  const context = await browser.newContext({ viewport: { width: target.width, height: 900 }, ...variant });
  const page = await context.newPage();
  await page.goto(target.url, { waitUntil: "load" });
  await settleAndShoot(page, target.width, target.path);
  const findings = withAxe ? await axeFindings(page) : [];
  await context.close();
  return findings;
}

async function measure(browser: Browser, url: string, width: number, shot: string): Promise<WidthRecord> {
  const context = await browser.newContext({ viewport: { width, height: 900 } });
  const page = await context.newPage();
  const consoleErrors: string[] = [];
  page.on("console", (msg) => {
    if (msg.type() === "error") consoleErrors.push(msg.text());
  });
  page.on("pageerror", (err) => consoleErrors.push(`pageerror: ${err.message}`));
  const response = await page.goto(url, { waitUntil: "load" });
  const pageHeight = await settleAndShoot(page, width, shot);
  const truncated = pageHeight > MAX_CAPTURE_PX;
  const overflowPx = (await page.evaluate(() => document.documentElement.scrollWidth)) - width;
  const axe = await axeFindings(page);
  await context.close();
  const reducedScreenshot = shot.replace(/\.jpg$/, "-reduced.jpg");
  const darkScreenshot = shot.replace(/\.jpg$/, "-dark.jpg");
  await shootVariant(browser, { url, width, path: reducedScreenshot }, { reducedMotion: "reduce" });
  const axeDark = await shootVariant(browser, { url, width, path: darkScreenshot }, { colorScheme: "dark" }, true);
  return {
    status: response?.status() ?? null,
    screenshot: shot,
    reducedScreenshot,
    darkScreenshot,
    truncated,
    pageHeight,
    overflowPx,
    consoleErrors,
    axe,
    axeDark,
  };
}

for (const route of routes) {
  test(`site-audit ${route}`, async ({ browser, baseURL }) => {
    const slug = slugOf(route);
    mkdirSync(join(OUT, "screenshots"), { recursive: true });
    mkdirSync(join(OUT, "pages"), { recursive: true });
    const record: Record<string, WidthRecord> = {};
    for (const width of WIDTHS) {
      const shot = join(OUT, "screenshots", `${slug}-${width}.jpg`);
      record[width] = await measure(browser, new URL(route, baseURL).href, width, shot);
      expect(record[width].status, `${route} at ${width}px answered`).not.toBeNull();
      expect(statSync(shot).size, `${shot} written`).toBeGreaterThan(0);
      expect(statSync(record[width].reducedScreenshot).size, "reduced-motion shot written").toBeGreaterThan(0);
      expect(statSync(record[width].darkScreenshot).size, "dark shot written").toBeGreaterThan(0);
    }
    writeFileSync(join(OUT, "pages", `${slug}.json`), `${JSON.stringify({ route, widths: record }, null, 2)}\n`);
  });
}
