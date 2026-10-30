// C15 Electron smoke: drives the REAL main process (Playwright _electron) under xvfb.
// stdin = demo password (never argv/env/disk). Output: one `PASS|FAIL|SKIP <check> — <evidence>` line per
// check, then `csp-violations=<n>`. Selectors are copied from apps/osionos/app/tests (browser/core/app.mjs).
// Ponytail: every selector/timeout below is a heuristic — a renamed label or a slow cold start reads as FAIL
// (over-reporting); a check whose selector matches the wrong element could PASS wrongly (rare, see README).
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";

// ESM ignores NODE_PATH; the deps live in the cache volume, not next to this file.
const { _electron } = createRequire("/cache/")("playwright-core");

const EMAIL = process.env.DEMO_LOGIN_EMAIL ?? "";
const PASSWORD = readFileSync(0, "utf8").trim();
const MARKER = `smoke-${Date.now().toString(36)}`;
const SLOW = 30_000; // cold app + live bridge round-trips; raise if a CI box is slower
let failures = 0;
const csp = new Map();
const consoleErrors = [];

const say = (verdict, check, evidence) => console.log(`${verdict} ${check} — ${evidence}`);
async function check(name, fn) {
  try { say("PASS", name, (await fn()) ?? "ok"); }
  catch (e) { if (!e?.skip) failures++;
    say(e?.skip ? "SKIP" : "FAIL", name, String(e?.message ?? e).split("\n")[0].slice(0, 300)); return false; }
  return true;
}
const shot = (page, name) => page.screenshot({ path: `/out/${name}.png` }).catch(() => {});

async function launch() {
  const app = await _electron.launch({
    executablePath: "/cache/node_modules/electron/dist/electron",
    args: ["/app"],
    env: { ...process.env, ELECTRON_ENABLE_LOGGING: "1" },
  });
  // Binding + init script live on the context: they survive the reloads the checks do, so no violation is lost.
  await app.context().exposeBinding("__cspReport", (_src, v) => csp.set(v, (csp.get(v) ?? 0) + 1));
  await app.context().addInitScript(() =>
    document.addEventListener("securitypolicyviolation", (e) =>
      globalThis.__cspReport(`${e.violatedDirective} ${e.blockedURI}`)));
  const page = await app.firstWindow();
  page.on("console", (m) => { if (m.type() === "error") consoleErrors.push(m.text().slice(0, 200)); });
  await page.waitForLoadState("domcontentloaded");
  await page.reload({ waitUntil: "domcontentloaded" });
  return { app, page };
}

// A synthetic event proves the listener+binding path works, so "csp-violations=0" is not just a dead counter.
async function cspCounterSelfTest(page) {
  await page.evaluate(() => document.dispatchEvent(new SecurityPolicyViolationEvent("securitypolicyviolation",
    { violatedDirective: "selftest", blockedURI: "selftest:" })));
  await page.waitForTimeout(200);
  if (!csp.delete("selftest selftest:")) throw new Error("synthetic violation not received");
  return "synthetic violation reached the counter";
}

async function windowOpenIsNull(page) {
  const r = await page.evaluate(() => [window.open("about:blank"), window.open("data:text/html,x")].map((w) => w === null));
  if (!r.every(Boolean)) throw new Error(`window.open returned non-null: ${JSON.stringify(r)}`);
  return "about:blank=null data:=null";
}

async function cspHeader(page) {
  const names = await page.evaluate(async () => {
    const r = await fetch("app://osionos/index.html");
    return ["content-security-policy-report-only", "content-security-policy"].filter((h) => r.headers.has(h));
  });
  if (!names.length) throw new Error("no CSP header on app://osionos/index.html");
  return `header=${names.join("+")}`;
}

// C16: the full edition must run with webSecurity on; read it from the live window, not from main.js.
async function webSecurityOn(app) {
  const on = await app.evaluate(({ BrowserWindow }) =>
    BrowserWindow.getAllWindows()[0].webContents.getLastWebPreferences().webSecurity);
  if (on !== true) throw new Error(`webSecurity=${on} (C16: the full edition runs with it on)`);
  return "webPreferences.webSecurity=true";
}

async function titlebarMaximize(app, page) {
  const isMax = () => app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].isMaximized());
  const before = await isMax();
  await page.locator("#osio-titlebar .tb-max").click();
  await page.waitForTimeout(500); // the WM acknowledges maximize asynchronously
  const after = await isMax();
  if (before === after) throw new Error(`isMaximized stayed ${before}`);
  await page.locator("#osio-titlebar .tb-max").click();
  await page.waitForTimeout(500);
  return `isMaximized ${before} -> ${after} -> ${await isMax()}`;
}

async function titlebarMinimize(app, page) {
  await page.locator("#osio-titlebar .tb-min").click();
  const min = () => app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].isMinimized());
  await page.waitForTimeout(1000); // the WM acknowledges iconify asynchronously
  const now = await min();
  await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].restore());
  if (!now) throw new Error("isMinimized stayed false");
  return "isMinimized false -> true, restored";
}

async function login(page) {
  if (!EMAIL || !PASSWORD) throw new Error("DEMO_LOGIN_EMAIL / stdin password missing");
  const email = page.getByRole("textbox", { name: "Email" });
  await email.waitFor({ timeout: SLOW });
  await email.fill(EMAIL);
  await page.getByLabel("Password", { exact: true }).fill(PASSWORD);
  await page.getByLabel(/Keep me signed in/).check(); // a reload must keep the session, as a desktop user expects
  // "Log in" before the portal redesign, "Sign in" after: a desktop built from either pin passes.
  await page.getByRole("button", { name: /^(log in|sign in)$/i }).last().click();
  await page.getByRole("button", { name: /New page/i }).first().or(page.locator('button[title="Add to Private"]').first())
    .waitFor({ timeout: 45_000 });
  return "workspace shell rendered";
}

async function pageSaveAndReload(page) {
  const newPage = page.getByRole("button", { name: /New page/i }).first();
  const addPrivate = page.locator('button[title="Add to Private"], button[title="Add file"]').first();
  if (await newPage.isVisible().catch(() => false)) await newPage.click();
  else await addPrivate.evaluate((n) => n.click());
  const title = page.getByRole("textbox", { name: "Page title" });
  await title.waitFor({ timeout: SLOW });
  await title.fill(MARKER);
  await page.waitForTimeout(3000); // debounced cache write (titleTyping.spec waits 2s)
  await page.reload({ waitUntil: "domcontentloaded" });
  await page.getByRole("treeitem").filter({ hasText: MARKER }).first().waitFor({ timeout: SLOW });
  return `page "${MARKER}" present after reload`;
}

async function databaseView(page) {
  const rail = page.locator('[aria-label="Databases"]').first();
  await rail.waitFor({ timeout: SLOW });
  await rail.click();
  await page.getByLabel("Search databases and tables").waitFor({ timeout: SLOW });
  if (await page.getByText(/aren.t configured/i).count()) throw new Error("Databases panel says: not configured (offline build)");
  if (await page.getByText(/Couldn.t load your databases/i).count()) throw new Error("Databases panel: registry load error");
  return "Databases panel rendered with catalog";
}

async function chatSend(page) {
  const tab = page.getByRole("tab", { name: /^Conversations/ });
  await tab.click({ timeout: SLOW });
  await page.locator('[data-sidebar-panel="conversations"]').getByRole("button", { name: "New AI chat" }).click();
  const composer = page.getByPlaceholder("Do anything with AI…");
  await composer.fill(`hello ${MARKER}`);
  await composer.press("Enter");
  // First send with no connector triggers guided onboarding (chatShell.spec.mjs); the stub connector needs no secret.
  await page.getByRole("button", { name: "Yes, connect" }).click({ timeout: SLOW });
  await page.getByRole("dialog").getByRole("button", { name: "Connect", exact: true }).first().click();
  await page.locator('[data-role="user"]').filter({ hasText: MARKER }).first().waitFor({ timeout: SLOW });
  return "user message rendered in chat-thread";
}

const { app, page } = await launch();
await check("csp-counter-selftest", () => cspCounterSelfTest(page));
await check("window.open-null", () => windowOpenIsNull(page));
await check("csp-header", () => cspHeader(page));
await check("web-security", () => webSecurityOn(app));
await check("titlebar-maximize", () => titlebarMaximize(app, page));
await check("titlebar-minimize", () => titlebarMinimize(app, page));
const loggedIn = await check("login", () => login(page));
await shot(page, "after-login");
for (const [name, fn] of [["page-save-reload", pageSaveAndReload], ["database-view", databaseView], ["chat-send", chatSend]]) {
  if (!loggedIn) { say("SKIP", name, "login failed"); continue; }
  if (!(await check(name, () => fn(page)))) await shot(page, `${name}-fail`);
}
const total = [...csp.values()].reduce((a, b) => a + b, 0);
console.log(`csp-violations=${total}`);
for (const [pair, n] of [...csp].slice(0, 10)) console.log(`  csp ${pair} x${n}`);
console.log(`console-errors=${consoleErrors.length}`);
for (const m of new Set(consoleErrors)) console.log(`  console ${m}`);
await app.close().catch(() => {});
process.exitCode = failures ? 1 : 0;
