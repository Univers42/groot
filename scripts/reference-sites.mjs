// reference-sites.mjs <out.json> <shots-dir> <url>... — measure product sites known for craft, for
// PLAN.md §4 (principles only). Per site and width: the h1, what fills the first viewport, how many
// call-to-action controls compete there, the web fonts, the bytes by resource type, and how many
// animations run with and without prefers-reduced-motion. Screenshots are third-party assets: they go
// to <shots-dir> (git-ignored) for a human to look at and are never committed.
//   scripts/tools.sh node scripts/reference-sites.mjs docs/redesign/references.json \
//     tests/e2e/test-results/reference-sites https://linear.app ...
// Caveat: "CTA" is any link or button in the first viewport with an opaque background, so a styled
// tab or a pill tag counts as one (over-count) and a text-link CTA does not (under-count). Bytes are
// the CDP encodedDataLength of the first 8 s after load; lazy media fetched later is not counted.
import { createRequire } from "node:module";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const require = createRequire("/usr/local/lib/node_modules/@playwright/mcp/");
const { chromium } = require("playwright-core");

const [out, shots, ...urls] = process.argv.slice(2);
if (!out || !shots || urls.length === 0) {
  console.error("usage: reference-sites.mjs <out.json> <shots-dir> <url>...");
  process.exit(2);
}
mkdirSync(shots, { recursive: true });

const WIDTHS = [{ width: 1440, height: 900 }, { width: 390, height: 844 }];

function firstViewport() {
  const vw = innerWidth;
  const vh = innerHeight;
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    const w = Math.max(0, Math.min(r.right, vw) - Math.max(r.left, 0));
    const h = Math.max(0, Math.min(r.bottom, vh) - Math.max(r.top, 0));
    return (w * h) / (vw * vh);
  };
  const media = [...document.querySelectorAll("img,video,canvas,svg,picture,iframe")]
    .map((el) => ({ tag: el.tagName.toLowerCase(), share: visible(el), alt: el.getAttribute("alt") ?? "" }))
    .filter((m) => m.share > 0.04)
    .sort((a, b) => b.share - a.share)
    .slice(0, 4)
    .map((m) => ({ ...m, share: Math.round(m.share * 100) }));
  const ctas = [...document.querySelectorAll("a,button")].filter((el) => {
    const r = el.getBoundingClientRect();
    if (r.bottom <= 0 || r.top >= vh || r.width === 0) return false;
    const bg = getComputedStyle(el).backgroundColor;
    return bg !== "rgba(0, 0, 0, 0)" && bg !== "transparent";
  }).map((el) => el.textContent.trim().replace(/\s+/g, " ").slice(0, 40));
  const h1 = document.querySelector("h1")?.textContent.trim().replace(/\s+/g, " ") ?? null;
  const fonts = [...new Set([...document.fonts].filter((f) => f.status === "loaded").map((f) => f.family.replace(/"/g, "")))];
  return { h1, h1Count: document.querySelectorAll("h1").length, media, ctas, fonts, animations: document.getAnimations().length };
}

async function visit(browser, url, viewport, reducedMotion) {
  const context = await browser.newContext({ viewport, reducedMotion, ignoreHTTPSErrors: false });
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  await cdp.send("Network.enable");
  const types = new Map();
  const bytes = {};
  cdp.on("Network.responseReceived", (e) => types.set(e.requestId, e.type));
  cdp.on("Network.loadingFinished", (e) => {
    const type = (types.get(e.requestId) ?? "Other").toLowerCase();
    bytes[type] = (bytes[type] ?? 0) + e.encodedDataLength;
  });
  await page.goto(url, { waitUntil: "load", timeout: 45_000 });
  await page.waitForTimeout(8_000);
  const seen = await page.evaluate(firstViewport);
  const scrolledAnimations = await page.evaluate(async () => {
    for (let y = 0; y < document.body.scrollHeight; y += innerHeight / 2) {
      scrollTo(0, y);
      await new Promise((r) => setTimeout(r, 120));
    }
    return document.getAnimations().length;
  });
  const kb = Object.fromEntries(Object.entries(bytes).map(([k, v]) => [k, Math.round(v / 1024)]));
  const height = await page.evaluate(() => document.documentElement.scrollHeight);
  if (!reducedMotion || reducedMotion === "no-preference") {
    const host = new URL(url).hostname.replace(/^www\./, "");
    await page.evaluate(() => scrollTo(0, 0));
    await page.screenshot({ path: join(shots, `${host}-${viewport.width}.jpg`), type: "jpeg", quality: 70 });
  }
  await context.close();
  return { ...seen, scrolledAnimations, kb, height };
}

const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, args: ["--no-sandbox"] });
const report = [];
for (const url of urls) {
  const entry = { url, measuredAt: new Date().toISOString().slice(0, 10), widths: {} };
  for (const viewport of WIDTHS) {
    try {
      const normal = await visit(browser, url, viewport, "no-preference");
      const reduced = await visit(browser, url, viewport, "reduce");
      entry.widths[viewport.width] = { ...normal, reducedAnimations: reduced.animations, reducedScrolledAnimations: reduced.scrolledAnimations };
    } catch (err) {
      entry.widths[viewport.width] = { error: String(err.message).split("\n")[0] };
    }
    console.error(`[reference-sites] ${url} @${viewport.width}`);
  }
  report.push(entry);
}
await browser.close();
writeFileSync(out, `${JSON.stringify(report, null, 2)}\n`);
