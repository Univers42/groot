// The local terminal against the REAL main.js and preload (devil verdict 2026-10-31, C1-C8):
// Playwright _electron under xvfb, no sign-in (the preload API exists before login).
// Caveat: the shell is the container's (root, /bin/bash), not a person's; latencies are one
// sample on this host, and the /__baas/ probe reads SKIP when the configured grobase is unreachable.
import { execFileSync } from "node:child_process";
import http from "node:http";
import { createRequire } from "node:module";

const { _electron } = createRequire("/cache/")("playwright-core");
// Electron supports its latest three majors; 45 was the latest on 2026-10-31.
const MIN_ELECTRON_MAJOR = 43;
const HIGH_WATERMARK = 100000;
let failures = 0;
const say = (verdict, name, evidence) => console.log(`${verdict} ${name} — ${evidence}`);
async function check(name, fn) {
  try {
    const r = await fn();
    if (typeof r === "string" && r.startsWith("SKIP")) say("SKIP", name, r.slice(5));
    else say("PASS", name, r ?? "ok");
  } catch (e) { failures++; say("FAIL", name, String(e?.message ?? e).split("\n")[0].slice(0, 300)); }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const assert = (ok, msg) => { if (!ok) throw new Error(msg); };
const ps = () => execFileSync("ps", ["-eo", "pid=,ppid=,args="], { encoding: "utf8" }).trim().split("\n")
  .map((l) => l.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/)).filter(Boolean).map(([, pid, ppid, args]) => ({ pid: +pid, ppid: +ppid, args }));
const hostPid = () => ps().find((p) => /--type=utility/.test(p.args) && /node\.mojom\.NodeService/.test(p.args))?.pid ?? null;
const shellsOf = (pid) => ps().filter((p) => p.ppid === pid).length;

const app = await _electron.launch({ executablePath: "/cache/node_modules/electron/dist/electron", args: ["/app"] });
const page = await app.firstWindow();
await page.waitForLoadState("domcontentloaded");
// A pty driven from the page, the way the terminal panel drives it.
const open = (cols = 80, rows = 24) => page.evaluate(async ([c, r]) => {
  const id = await window.osionosDesktop.pty.create(c, r);
  if (!id) return null;
  window.__out = window.__out || {};
  window.__exit = window.__exit || {};
  window.__out[id] = "";
  window.osionosDesktop.pty.onData(id, (d) => { window.__out[id] += d; if (!window.__noAck) window.osionosDesktop.pty.ack(id, d.length); });
  window.osionosDesktop.pty.onExit(id, (code) => { window.__exit[id] = code; });
  return id;
}, [cols, rows]);
const type = (id, text) => page.evaluate(([i, t]) => window.osionosDesktop.pty.write(i, t), [id, text]);
const output = (id) => page.evaluate((i) => window.__out[i] ?? "", id);
async function until(probe, ms, what) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (await probe()) return; await sleep(100); }
  throw new Error(`timed out: ${what}`);
}

try {
  await check("C1 electron is a supported major", async () => {
    const v = await app.evaluate(() => process.versions.electron);
    assert(Number(v.split(".")[0]) >= MIN_ELECTRON_MAJOR, `electron ${v} < ${MIN_ELECTRON_MAJOR}`);
    return `electron ${v}`;
  });
  await check("C2 enforced CSP stops an inline handler", async () => {
    await page.evaluate(() => document.body.insertAdjacentHTML("beforeend", '<img src="x-missing" onerror="window.__p=1">'));
    await sleep(800);
    assert((await page.evaluate(() => window.__p)) === undefined, "onerror ran");
    return "window.__p stayed undefined";
  });
  let id;
  await check("shell runs and answers", async () => {
    id = await open(100, 30);
    assert(id, "create refused");
    await type(id, "echo osionos-$((6*7)); tput cols\r");
    await until(async () => /osionos-42/.test(await output(id)), 10000, "the echo");
    return "echo came back through the pty";
  });
  await check("resize reaches the shell", async () => {
    await page.evaluate((i) => window.osionosDesktop.pty.resize(i, 132, 40), id);
    await type(id, "echo cols=$(tput cols)\r");
    await until(async () => /cols=132/.test(await output(id)), 5000, "cols=132");
    return "tput cols = 132";
  });
  await check("C8 the shell's env carries no ELECTRON_* / NODE_OPTIONS", async () => {
    await type(id, "echo leak=$(env | grep -cE '^(ELECTRON_|NODE_OPTIONS=)')\r");
    await until(async () => /leak=\d+/.test(await output(id)), 5000, "the env count");
    const n = (await output(id)).match(/leak=(\d+)/)[1];
    assert(n === "0", `${n} variables leaked`);
    return "0 variables";
  });
  await check("C5 malformed sizes are refused", async () => {
    const refused = await page.evaluate(async () => [await window.osionosDesktop.pty.create(0, 24), await window.osionosDesktop.pty.create(80, 1001), await window.osionosDesktop.pty.create("80", 24)]);
    assert(refused.every((r) => r === null), JSON.stringify(refused));
    return "0x24, 80x1001 and \"80\" all null";
  });
  await check("C5 a machine window inherits no terminal API", async () => {
    const server = http.createServer((_q, s) => { s.writeHead(200, { "content-type": "text/html" }); s.end("<title>m</title>"); }).listen(47199, "127.0.0.1");
    try {
      const child = app.waitForEvent("window", { timeout: 10000 });
      await page.evaluate(() => { window.open("http://127.0.0.1:47199/?node=m-abcdefghijklmnop"); });
      const win = await child;
      // Electron opens the child on about:blank, then navigates it.
      await win.waitForURL(/127\.0\.0\.1:47199/, { timeout: 10000 });
      await win.waitForLoadState("domcontentloaded");
      const api = await win.evaluate(() => typeof window.osionosDesktop?.pty);
      await win.close();
      assert(api === "undefined", `pty is ${api} there`);
      return "window.osionosDesktop.pty is undefined on http://127.0.0.1";
    } finally { server.close(); }
  });
  await check("C7 output pauses while unacknowledged and resumes on ack", async () => {
    await page.evaluate(() => { window.__noAck = true; });
    const flood = await open();
    await type(flood, "yes osionos-flow-control\r");
    await sleep(2500);
    const held = (await output(flood)).length;
    assert(held <= HIGH_WATERMARK + 70000, `${held} chars arrived unacknowledged`);
    const t0 = Date.now();
    const probe = await page.evaluate(async () => { const s = Date.now(); const x = await window.osionosDesktop.pty.create(80, 24); if (x) window.osionosDesktop.pty.kill(x); return Date.now() - s; });
    assert(probe < 1000, `main process answered in ${probe} ms`);
    await page.evaluate(([i, n]) => { window.__noAck = false; window.osionosDesktop.pty.ack(i, n); }, [flood, held]);
    await until(async () => (await output(flood)).length > held + 1000, 5000, "output after the ack");
    await type(flood, "\x03");
    return `${held} chars held before the ack; main answered in ${probe} ms (${Date.now() - t0} ms total)`;
  });
  await check("C7 the BaaS relay answers during a flood", async () => {
    const flood = await open();
    await type(flood, "timeout 6 yes\r");
    await sleep(500);
    const r = await page.evaluate(async () => { const s = Date.now(); try { const res = await fetch("app://osionos/__baas/auth/v1/health"); return { ms: Date.now() - s, status: res.status }; } catch (e) { return { ms: Date.now() - s, error: String(e) }; } });
    if (r.error) return `SKIP relay unreachable here (${r.error.slice(0, 80)})`;
    assert(r.ms < 1000, `relay took ${r.ms} ms`);
    return `HTTP ${r.status} in ${r.ms} ms`;
  });
  await check("C6 a ninth shell per window is refused", async () => {
    const ids = [];
    for (let i = 0; i < 12; i++) ids.push(await open());
    const live = ids.filter(Boolean).length;
    assert(ids.includes(null), "no create was refused");
    return `${live} live after 12 asks (cap 8 per window, earlier shells included)`;
  });
  await check("C6 a reload leaves no shell behind", async () => {
    const host = hostPid();
    assert(host, "no pty host process");
    assert(shellsOf(host) > 0, "no shells before the reload");
    await page.reload();
    await page.waitForLoadState("domcontentloaded");
    await until(async () => shellsOf(host) === 0, 2000, `shells under host ${host} after the reload`);
    return `host ${host}: 0 shells within 2 s`;
  });
  await check("C6 a killed host leaves the window alive and the next shell starts", async () => {
    const first = await open();
    const host = hostPid();
    process.kill(host, "SIGKILL");
    await until(async () => (await page.evaluate((i) => window.__exit?.[i], first)) === -1, 5000, "the -1 exit");
    const next = await open();
    assert(next, "no shell after the host died");
    await type(next, "echo again-$((1+1))\r");
    await until(async () => /again-2/.test(await output(next)), 10000, "a shell on the new host");
    return `host ${host} killed; the page saw exit -1 and a new host ${hostPid()} answers`;
  });
} catch (e) {
  failures++;
  say("FAIL", "run", String(e?.message ?? e).split("\n")[0]);
} finally {
  await app.close().catch(() => {});
  console.log(failures ? "RESULT FAIL" : "RESULT PASS");
  process.exit(failures ? 1 : 0);
}
