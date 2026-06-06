// ===========================================================================
// bench.mjs — Playwright perf benchmark for the bundled (offline) osionos.
// Serves apps/osionos-desktop/build statically, loads it in headless Chromium,
// and reports: load timing, First/Largest Contentful Paint, total main-thread
// long-task time (jank), DOM node count, JS heap, and average frame interval
// during a scripted scroll. Chromium ≠ WebKitGTK, so this isolates APP-level
// (React/canvas) cost from the desktop renderer.
//
// Run (uses the playground image which bundles Playwright + Chromium):
//   docker run --rm -v "$PWD/apps/osionos-desktop":/d -w /d \
//     track-binocle/playground-simulation:local node bench.mjs
// ===========================================================================
import http from 'node:http';
import { readFileSync, existsSync, statSync } from 'node:fs';
import { extname, join, normalize } from 'node:path';
import { chromium } from 'playwright';

const ROOT = join(process.cwd(), 'build');
const MIME = { '.html':'text/html', '.js':'text/javascript', '.mjs':'text/javascript',
  '.css':'text/css', '.json':'application/json', '.svg':'image/svg+xml', '.woff2':'font/woff2',
  '.woff':'font/woff', '.png':'image/png', '.jpg':'image/jpeg', '.ico':'image/x-icon', '.map':'application/json' };

const server = http.createServer((req, res) => {
  let p = normalize(decodeURIComponent((req.url || '/').split('?')[0])).replace(/^(\.\.[/\\])+/, '');
  let file = join(ROOT, p);
  if (!existsSync(file) || statSync(file).isDirectory()) {
    const idx = join(ROOT, p, 'index.html');
    file = existsSync(idx) ? idx : join(ROOT, 'index.html'); // SPA fallback
  }
  try { res.writeHead(200, { 'content-type': MIME[extname(file)] || 'application/octet-stream' }); res.end(readFileSync(file)); }
  catch { res.writeHead(404); res.end('nf'); }
});

const port = 8791;
await new Promise((r) => server.listen(port, '127.0.0.1', r));
const url = `http://127.0.0.1:${port}/`;

const browser = await chromium.launch({ args: ['--no-sandbox', '--disable-dev-shm-usage'] });
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

await page.addInitScript(() => {
  window.__lt = 0; window.__ltc = 0;
  try { new PerformanceObserver((l) => { for (const e of l.getEntries()) { window.__lt += e.duration; window.__ltc++; } })
    .observe({ entryTypes: ['longtask'] }); } catch {}
});

const t0 = Date.now();
await page.goto(url, { waitUntil: 'load', timeout: 60000 });
await page.waitForTimeout(3500); // let the SPA mount + settle

const m = await page.evaluate(async () => {
  const nav = performance.getEntriesByType('navigation')[0] || {};
  const paints = performance.getEntriesByType('paint');
  const fcp = (paints.find((p) => p.name === 'first-contentful-paint') || {}).startTime || null;
  const lcpE = performance.getEntriesByType('largest-contentful-paint');
  const lcp = lcpE.length ? lcpE[lcpE.length - 1].startTime : null;
  // frame-interval probe over ~1s while scrolling
  const frames = await new Promise((resolve) => {
    const ts = []; let last = performance.now(); let n = 0;
    const sc = document.scrollingElement || document.documentElement;
    function step(now) { ts.push(now - last); last = now; if (sc) sc.scrollTop += 40;
      if (++n < 60) requestAnimationFrame(step); else resolve(ts); }
    requestAnimationFrame(step);
  });
  const avgFrame = frames.reduce((a, b) => a + b, 0) / frames.length;
  const slowFrames = frames.filter((f) => f > 18).length;
  return {
    domContentLoaded: Math.round(nav.domContentLoadedEventEnd || 0),
    loadEvent: Math.round(nav.loadEventEnd || 0),
    fcp: fcp && Math.round(fcp), lcp: lcp && Math.round(lcp),
    longTaskTotalMs: Math.round(window.__lt), longTaskCount: window.__ltc,
    domNodes: document.getElementsByTagName('*').length,
    jsHeapMB: performance.memory ? Math.round(performance.memory.usedJSHeapSize / 1048576) : null,
    avgFrameMs: Math.round(avgFrame * 10) / 10, slowFramesOf60: slowFrames,
  };
});

console.log('=== osionos bundled bench (Chromium) ===');
console.log(`  wall load:          ${Date.now() - t0} ms`);
console.log(`  DOMContentLoaded:   ${m.domContentLoaded} ms`);
console.log(`  load event:         ${m.loadEvent} ms`);
console.log(`  First Contentful:   ${m.fcp} ms`);
console.log(`  Largest Contentful: ${m.lcp} ms`);
console.log(`  long-task total:    ${m.longTaskTotalMs} ms over ${m.longTaskCount} tasks  (main-thread jank)`);
console.log(`  DOM nodes:          ${m.domNodes}`);
console.log(`  JS heap:            ${m.jsHeapMB} MB`);
console.log(`  scroll avg frame:   ${m.avgFrameMs} ms   slow frames(>18ms): ${m.slowFramesOf60}/60`);

await browser.close();
server.close();
