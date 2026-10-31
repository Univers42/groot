// C23 desktop run: the REAL main.js (Playwright _electron, xvfb) opens this machine's folder through
// /machine, the emailed step-up and a child window, and the IDE edits, saves and runs a terminal.
// stdin = the account password. The step-up code is read from /out/code.txt (the owner pastes it).
// Caveat: selectors and the 3 s terminal pause are heuristics; a slow host reads FAIL, never PASS.
import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";

const { _electron } = createRequire("/cache/")("playwright-core");
const EMAIL = process.env.DEMO_LOGIN_EMAIL ?? "";
const PASSWORD = readFileSync(0, "utf8").trim();
const FOLDER = process.env.MACHINE_FOLDER;
const NODE_ORIGIN = "http://127.0.0.1:4100";
let failures = 0;
const errors = [];
const say = (verdict, name, evidence) => console.log(`${verdict} ${name} — ${evidence}`);
async function check(name, fn) {
  try { say("PASS", name, (await fn()) ?? "ok"); return true; }
  catch (e) { failures++; say("FAIL", name, String(e?.message ?? e).split("\n")[0].slice(0, 300)); return false; }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const shot = (page, name) => page.screenshot({ path: `/out/${name}.png` }).catch(() => {});

const app = await _electron.launch({
  executablePath: "/cache/node_modules/electron/dist/electron", args: ["/app"],
  env: { ...process.env, ELECTRON_ENABLE_LOGGING: "1" }, recordHar: { path: "/out/machine.har", content: "omit" },
});
const page = await app.firstWindow();
page.on("console", (m) => { if (m.type() === "error") errors.push(`app: ${m.text().slice(0, 200)}`); });
let ide = null;

try {
  await check("login", async () => {
    const email = page.getByRole("textbox", { name: "Email" });
    await email.waitFor({ timeout: 45_000 });
    await email.fill(EMAIL);
    await page.getByLabel("Password", { exact: true }).fill(PASSWORD);
    await page.getByLabel(/Keep me signed in/).check(); // /machine is a new load; the session must survive it
    await page.getByRole("button", { name: /^(log in|sign in)$/i }).last().click();
    await page.getByRole("button", { name: /New page/i }).first().or(page.locator('button[title="Add to Private"]').first()).waitFor({ timeout: 45_000 });
    return "workspace shell rendered";
  });

  await check("machine-view", async () => {
    await page.evaluate((folder) => { location.href = `app://osionos/machine?node=laptop&folder=${encodeURIComponent(folder)}`; }, FOLDER);
    await page.getByRole("button", { name: /open in a new window/i }).waitFor({ timeout: 30_000 }).catch(async (e) => {
      await shot(page, "machine-view-fail");
      const body = await page.locator("body").innerText().catch(() => "?");
      throw new Error(`${e.message.split("\n")[0]} url=${page.url()} body=${body.replace(/\s+/g, " ").slice(0, 200)}`);
    });
    return page.url().replace(/folder=[^&]+/, "folder=…");
  });

  await check("step-up-and-window", async () => {
    const opened = app.waitForEvent("window", { timeout: 20 * 60_000 });
    await page.getByRole("button", { name: /open in a new window/i }).click();
    const emailMe = page.getByRole("button", { name: /email me a code/i });
    if (await emailMe.waitFor({ timeout: 15_000 }).then(() => true, () => false)) {
      await emailMe.click();
      console.log("CODE SENT — waiting for /out/code.txt");
      const end = Date.now() + 25 * 60_000;
      while (!(existsSync("/out/code.txt") && /^\d{6}$/.test(readFileSync("/out/code.txt", "utf8").trim()))) {
        if (Date.now() > end) throw new Error("no code within 25 minutes");
        await sleep(1000);
      }
      await page.locator('input[autocomplete="one-time-code"]').fill(readFileSync("/out/code.txt", "utf8").trim());
      await page.getByRole("button", { name: /^confirm$/i }).click();
      await sleep(3000);
      if ((await app.windows()).length < 2) await page.getByRole("button", { name: /open in a new window|show the window/i }).click().catch(() => {});
    }
    ide = await opened;
    ide.on("console", (m) => { if (m.type() === "error") errors.push(`ide: ${m.text().slice(0, 200)}`); });
    return `child window ${new URL(ide.url()).origin}`;
  });

  // Resource GETs and the WebSocket: "connected" is set after the remote authority's socket opens.
  await check("ide-connected", async () => {
    await ide.locator('#status[data-state="connected"]').waitFor({ timeout: 90_000 });
    return "status connected";
  });

  await check("edit-and-save", async () => {
    await ide.locator("#quick-open").click();
    await ide.keyboard.type("hello.py");
    await sleep(1500);
    await ide.keyboard.press("Enter");
    await ide.locator(".monaco-editor .view-lines").filter({ hasText: "def greet" }).waitFor({ timeout: 30_000 });
    await ide.locator(".monaco-editor .view-lines").click();
    await ide.keyboard.press("Control+End");
    await ide.keyboard.type("\n# saved-from-desktop-osionos\n");
    await ide.keyboard.press("Control+S");
    await sleep(3000);
    return "typed and saved (the host checks the disk)";
  });

  await check("terminal", async () => {
    await ide.locator("#new-terminal").click();
    const trust = ide.locator(".monaco-dialog-box .monaco-button").filter({ hasText: /trust/i }).filter({ hasNotText: /don.t|not/i }).first();
    if (await trust.waitFor({ timeout: 20_000 }).then(() => true, () => false)) await trust.click();
    await ide.locator("#terminal .xterm").waitFor({ timeout: 30_000 });
    await sleep(3000);
    await ide.locator("#terminal .xterm").click();
    await ide.keyboard.type("pwd > terminal-probe-desktop\n");
    await sleep(3000);
    return "typed (the host checks the probe)";
  });
  await shot(ide, "machine-ide");

  // C5: no script-visible credential in either window.
  await check("c5-storage", async () => {
    for (const [name, win] of [["ide", ide], ["app", page]]) {
      const dump = await win.evaluate(async () => {
        const out = [document.cookie, JSON.stringify({ ...localStorage }), JSON.stringify({ ...sessionStorage })];
        for (const db of await indexedDB.databases?.() ?? []) out.push(db.name ?? "");
        return out.join("\n");
      });
      if (/osio-node|connectionToken|vscode-tkn|[?&]tkn=[^&"\s]/.test(dump)) throw new Error(`${name} exposes a node credential`);
    }
    return "no node cookie or connection token in cookies, localStorage, sessionStorage or IndexedDB names";
  });

  // C7 from the desktop origin: app://osionos may hand over a session, never reach the node itself.
  await check("c7-desktop-origin-refused", async () => {
    const result = await page.evaluate(async (origin) => {
      const fetched = await fetch(`${origin}/api/node/laptop/version`, { credentials: "include" }).then((r) => `status ${r.status}`, () => "blocked");
      const socket = await new Promise((resolve) => {
        const ws = new WebSocket(`${origin.replace("http", "ws")}/api/node/laptop/?reconnectionToken=x&reconnection=false&skipWebSocketFrames=false`);
        ws.onopen = () => { ws.close(); resolve("open"); };
        ws.onerror = () => resolve("refused");
        setTimeout(() => resolve("timeout"), 8000);
      });
      return { fetched, socket };
    }, NODE_ORIGIN);
    if (result.socket === "open" || result.fetched === "status 200") throw new Error(JSON.stringify(result));
    return JSON.stringify(result);
  });
} finally {
  await app.close().catch(() => {});
}

await check("c5-har", async () => {
  const har = readFileSync("/out/machine.har", "utf8");
  const leaks = [...har.matchAll(/.{0,60}([?&]tkn=[^&"\s]|connectionToken|vscode-tkn).{0,60}/g)].map((m) => m[0]);
  if (leaks.length) throw new Error(`token in HAR: ${leaks[0]}`);
  return `HAR ${har.length} bytes, no connection token value`;
});
console.log(`csp-errors=${errors.filter((t) => /Content Security Policy|Refused to/.test(t)).length}`);
for (const line of errors.slice(-8)) console.log(`  ${line}`);
process.exit(failures ? 1 : 0);
