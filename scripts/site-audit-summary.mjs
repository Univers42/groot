// site-audit-summary.mjs <dir> — print the Markdown tables for one labelled site audit
// (scripts/site-audit.sh): Lighthouse per route and form factor, then the capture evidence.
// Reads only what site-audit.sh wrote; a missing half prints a line saying so, never a zero.
//   site-audit-summary.mjs --prune <lighthouse/FORM>  keep each route's representative run only,
//                                                     as gzipped JSON, and rewrite the manifest
import { existsSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { basename, join, relative } from "node:path";
import { gunzipSync, gzipSync } from "node:zlib";

if (process.argv[2] === "--prune") {
  const formDir = process.argv[3];
  const manifestPath = join(formDir, "manifest.json");
  const kept = [];
  for (const entry of JSON.parse(readFileSync(manifestPath, "utf8"))) {
    const json = join(formDir, basename(entry.jsonPath));
    const html = join(formDir, basename(entry.htmlPath));
    if (entry.isRepresentativeRun) {
      writeFileSync(`${json}.gz`, gzipSync(readFileSync(json), { level: 9 }));
      kept.push({ ...entry, jsonPath: `${basename(entry.jsonPath)}.gz`, htmlPath: null });
    }
    rmSync(json, { force: true });
    rmSync(html, { force: true });
  }
  writeFileSync(manifestPath, `${JSON.stringify(kept, null, 2)}\n`);
  process.exit(0);
}

const dir = process.argv[2];
if (!dir) {
  console.error("usage: site-audit-summary.mjs <docs/redesign/LABEL> | --prune <lighthouse/FORM>");
  process.exit(2);
}

const readLhr = (formDir, jsonPath) => {
  const path = join(formDir, basename(jsonPath));
  const raw = readFileSync(path);
  return JSON.parse((path.endsWith(".gz") ? gunzipSync(raw) : raw).toString("utf8"));
};

const kb = (bytes) => (bytes == null ? "–" : (bytes / 1024).toFixed(0));
const score = (s) => (s == null ? "–" : Math.round(s * 100));
const routeOf = (url) => new URL(url).pathname;

function weights(lhr) {
  const items = lhr.audits["resource-summary"]?.details?.items ?? [];
  const by = Object.fromEntries(items.map((i) => [i.resourceType, i.transferSize]));
  return { js: by.script, css: by.stylesheet, img: by.image, font: by.font, total: by.total };
}

function lighthouseTable(form) {
  const manifest = join(dir, "lighthouse", form, "manifest.json");
  if (!existsSync(manifest)) return `_No ${form} Lighthouse run in ${relative(process.cwd(), dir)}._\n`;
  const rows = JSON.parse(readFileSync(manifest, "utf8"))
    .filter((entry) => entry.isRepresentativeRun)
    .map((entry) => {
      const lhr = readLhr(join(dir, "lighthouse", form), entry.jsonPath);
      const a = lhr.audits;
      const w = weights(lhr);
      const cat = lhr.categories;
      return [
        routeOf(entry.url),
        score(cat.performance?.score),
        score(cat.accessibility?.score),
        score(cat["best-practices"]?.score),
        score(cat.seo?.score),
        a["largest-contentful-paint"]?.numericValue != null ? (a["largest-contentful-paint"].numericValue / 1000).toFixed(2) : "–",
        a["cumulative-layout-shift"]?.numericValue?.toFixed(3) ?? "–",
        a["total-blocking-time"]?.numericValue != null ? Math.round(a["total-blocking-time"].numericValue) : "–",
        kb(w.js), kb(w.css), kb(w.img), kb(w.font), kb(w.total),
        a["errors-in-console"]?.details?.items?.length ?? "–",
      ];
    });
  const head = "| Route | Perf | A11y | BP | SEO | LCP s | CLS | TBT ms | JS KB | CSS KB | Img KB | Font KB | Total KB | Console errors |";
  const rule = `|${"---|".repeat(14)}`;
  return [head, rule, ...rows.map((r) => `| ${r.join(" | ")} |`)].join("\n") + "\n";
}

function captureTable() {
  const pages = join(dir, "pages");
  if (!existsSync(pages)) return "_No capture run._\n";
  const rows = readdirSync(pages).filter((f) => f.endsWith(".json")).sort().map((f) => {
    const rec = JSON.parse(readFileSync(join(pages, f), "utf8"));
    const widths = Object.values(rec.widths);
    const axe = new Map();
    for (const w of widths) for (const v of w.axe) axe.set(v.id, v);
    const severe = [...axe.values()].filter((v) => v.impact === "serious" || v.impact === "critical");
    const errors = new Set(widths.flatMap((w) => w.consoleErrors));
    const statuses = [...new Set(widths.map((w) => w.status))].join("/");
    const truncated = widths.some((w) => w.truncated) ? " (cut)" : "";
    const overflow = Object.entries(rec.widths)
      .filter(([, w]) => (w.overflowPx ?? 0) > 0)
      .map(([px, w]) => `+${w.overflowPx} @${px}`)
      .join(", ") || "–";
    return [rec.route, statuses, axe.size, severe.length, severe.map((v) => v.id).join(", ") || "–", errors.size, overflow, `${Math.max(...widths.map((w) => w.pageHeight))}${truncated}`];
  });
  const head = "| Route | HTTP | Axe rules violated | Serious/critical | Which | Distinct console errors | Horizontal overflow | Max height px |";
  return [head, `|${"---|".repeat(8)}`, ...rows.map((r) => `| ${r.join(" | ")} |`)].join("\n") + "\n";
}

process.stdout.write(
  [
    "<!-- generated by scripts/site-audit-summary.mjs; re-run scripts/site-audit.sh <label> summary -->",
    "### Lighthouse — mobile (default throttling)", "", lighthouseTable("mobile"),
    "### Lighthouse — desktop preset", "", lighthouseTable("desktop"),
    "### Capture — axe (WCAG 2.2 AA tags) and console, across 390/768/1440 px", "", captureTable(),
  ].join("\n"),
);
