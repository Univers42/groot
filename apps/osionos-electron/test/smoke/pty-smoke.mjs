// The local terminal against the REAL main.js and preload (devil verdict 2026-10-31, C1-C8, and
// Amendment 2 / ADR 0039, T2-T5): Playwright _electron under xvfb, no sign-in (the preload API
// exists before login). The page drives each pty on its own port, as the terminal frame does.
// Caveat: the shell is the container's (root, /bin/bash), not a person's; latencies are one
// sample on this host, and the /__baas/ probe reads SKIP when the configured grobase is unreachable.
// The terminal frame here gets no handoff, so its CSP count covers the page's boot, not VS Code's.
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
const cspLines = [];
page.on("console", (m) => {
  const text = m.text();
  if (!/Content Security Policy|Refused to/i.test(text)) return;
  cspLines.push(`${m.location()?.url ?? "?"} ${text.slice(0, 120)}`);
});
// A pty driven from the page, the way the terminal frame drives it: create through the preload,
// then the port the preload reposts to this window carries write/resize/ack in and data/exit out.
const open = (cols = 80, rows = 24) => page.evaluate(async ([c, r]) => {
  if (!window.__ports) {
    Object.assign(window, { __ports: {}, __out: {}, __exit: {}, __portExit: {} });
    window.addEventListener("message", (e) => {
      if (e.source !== window || e.data?.type !== "osionos-pty-port") return;
      const { id } = e.data;
      const port = e.ports[0];
      window.__ports[id] = port;
      window.__out[id] ??= "";
      port.onmessage = ({ data: m }) => {
        if (m.op === "data") { window.__out[id] += m.data; if (!window.__noAck) port.postMessage({ op: "ack", chars: m.data.length }); }
        else if (m.op === "exit") window.__portExit[id] = m.exitCode;
      };
    });
  }
  const id = await window.osionosDesktop.pty.create(c, r);
  if (!id) return null;
  window.osionosDesktop.pty.onExit(id, (code) => { window.__exit[id] = code; });
  for (const end = Date.now() + 5000; !window.__ports[id] && Date.now() < end;) await new Promise((ok) => setTimeout(ok, 10));
  if (!window.__ports[id]) throw new Error(`no port for ${id}`);
  return id;
}, [cols, rows]);
const onPort = (id, message) => page.evaluate(([i, m]) => window.__ports[i].postMessage(m), [id, message]);
const type = (id, text) => onPort(id, { op: "write", data: text });
const output = (id) => page.evaluate((i) => window.__out[i] ?? "", id);
const exitOf = (id) => page.evaluate((i) => window.__exit?.[i], id);
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
    await onPort(id, { op: "resize", cols: 132, rows: 40 });
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
  await check("T3 one path: no write/resize/ack/data IPC, the preload offers create, kill, onExit", async () => {
    const counts = await app.evaluate(({ ipcMain }) => ["pty:write", "pty:resize", "pty:ack", "pty:data"].map((c) => ipcMain.listenerCount(c)));
    assert(counts.every((n) => n === 0), `listeners ${counts}`);
    const api = await page.evaluate(() => Object.keys(window.osionosDesktop.pty).sort().join(","));
    assert(api === "create,kill,onExit", api);
    return "listenerCount 0,0,0,0; pty = create,kill,onExit";
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
    await page.evaluate(([i, n]) => { window.__noAck = false; window.__ports[i].postMessage({ op: "ack", chars: n }); }, [flood, held]);
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
  let exited;
  await check("T3 create 8, exit 8: every slot is freed and a 9th create succeeds", async () => {
    const ids = [];
    for (let i = 0; i < 8; i++) ids.push(await open());
    assert(ids.every(Boolean), `only ${ids.filter(Boolean).length} of 8 created`);
    for (const i of ids) await type(i, "exit\r");
    await until(async () => (await Promise.all(ids.map(exitOf))).every((c) => c !== undefined), 10000, "8 exits through main");
    const portExits = await page.evaluate((list) => list.filter((i) => window.__portExit[i] !== undefined).length, ids);
    const ninth = await open();
    assert(ninth, "the 9th create was refused");
    exited = { id: ids[0], next: ninth };
    return `8 pty:exit + ${portExits}/8 port exits; the 9th create returned ${ninth.slice(0, 8)}`;
  });
  await check("T2 100 writes and a resize after the exit, on that port, break nothing", async () => {
    assert(exited, "no exited pty");
    await page.evaluate((i) => { for (let n = 0; n < 100; n++) window.__ports[i].postMessage({ op: "write", data: "echo late\r" }); window.__ports[i].postMessage({ op: "resize", cols: 90, rows: 30 }); }, exited.id);
    await type(exited.next, "echo still-$((2+3))\r");
    await until(async () => /still-5/.test(await output(exited.next)), 10000, "the second shell's echo");
    return "the next shell still echoes";
  });
  await check("T5 closing the port in the page kills its shell and frees the slot", async () => {
    const host = hostPid();
    const id = await open();
    const before = shellsOf(host);
    await page.evaluate((i) => window.__ports[i].close(), id);
    await until(async () => shellsOf(host) === before - 1 && (await exitOf(id)) !== undefined, 2000, "the shell's end after the port close");
    return `host ${host}: ${before} -> ${before - 1} shells, pty:exit ${await exitOf(id)} within 2 s`;
  });
  await check("C6 a killed host leaves the window alive and the next shell starts", async () => {
    const first = await open();
    const host = hostPid();
    process.kill(host, "SIGKILL");
    await until(async () => (await exitOf(first)) === -1, 5000, "the -1 exit");
    const next = await open();
    assert(next, "no shell after the host died");
    await type(next, "echo again-$((1+1))\r");
    await until(async () => /again-2/.test(await output(next)), 10000, "a shell on the new host");
    return `host ${host} killed; the page saw exit -1 and a new host ${hostPid()} answers`;
  });
  // ADR 0039 (T4): the terminal on its own origin. No handoff here: the frame only boots.
  const terminal = await page.evaluate(() => new Promise((ok) => {
    const frame = document.createElement("iframe");
    frame.style.cssText = "position:fixed;left:0;top:0;width:600px;height:300px;border:0;z-index:99999";
    frame.addEventListener("load", () => ok(true));
    frame.src = "app://terminal/index.html";
    document.body.appendChild(frame);
    setTimeout(() => ok(false), 8000);
  }));
  await sleep(1500);
  await check("T4 the terminal page loads on app://terminal, a secure origin in its own process", async () => {
    assert(terminal, "the frame never loaded");
    const frame = page.frames().find((f) => f.url().startsWith("app://terminal/"));
    assert(frame, "no app://terminal frame");
    const where = await frame.evaluate(() => ({ origin: location.origin, secure: isSecureContext, title: document.title }));
    assert(where.origin === "app://terminal" && where.secure, JSON.stringify(where));
    const pids = await app.evaluate(({ BrowserWindow }) => {
      const main = BrowserWindow.getAllWindows()[0].webContents.mainFrame;
      return [main.osProcessId, main.framesInSubtree.find((f) => f.url.startsWith("app://terminal/"))?.osProcessId];
    });
    assert(pids[1] && pids[0] !== pids[1], `pids ${pids}`);
    return `origin ${where.origin}, isSecureContext, "${where.title}"; app pid ${pids[0]}, terminal pid ${pids[1]}`;
  });
  await check("T4 the handler: 404s carry the terminal policy, app://osionos/terminal/ is gone", async () => {
    const got = await app.evaluate(async ({ net }) => {
      const out = [];
      for (const url of ["app://terminal/__baas/rest/v1/x", "app://terminal/missing.js", "app://terminal/..%2findex.html", "app://x/index.html", "app://osionos/terminal/index.html", "app://terminal/index.html"]) {
        const r = await net.fetch(url);
        out.push([url, r.status, r.headers.get("content-security-policy") ?? ""]);
      }
      return out;
    });
    const bad = got.filter(([url, status, csp]) => status !== (url === "app://terminal/index.html" ? 200 : 404) || !csp.includes("frame-ancestors app://osionos"));
    assert(bad.length === 0, JSON.stringify(bad));
    return `${got.length - 1} URLs 404, the page 200, all with frame-ancestors app://osionos`;
  });
  await check("T4 (c) CSP on the terminal page: 0 violations at boot, a deliberate one is counted", async () => {
    const boot = cspLines.filter((l) => l.startsWith("app://terminal")).length;
    const frame = page.frames().find((f) => f.url().startsWith("app://terminal/"));
    await frame.evaluate(() => document.body.insertAdjacentHTML("beforeend", '<img src="x-missing" onerror="window.__p=1">'));
    await sleep(800);
    const ran = await frame.evaluate(() => window.__p);
    const after = cspLines.filter((l) => l.startsWith("app://terminal")).length;
    assert(ran === undefined, "the inline handler ran");
    assert(after > boot, `the deliberate violation was not counted (${boot} -> ${after}); U3: the frame's console may not reach the page`);
    assert(boot === 0, `${boot} violations at boot: ${cspLines.join(" | ").slice(0, 200)}`);
    return `boot 0, control ${after - boot} counted`;
  });
} catch (e) {
  failures++;
  say("FAIL", "run", String(e?.message ?? e).split("\n")[0]);
} finally {
  await app.close().catch(() => {});
  console.log(failures ? "RESULT FAIL" : "RESULT PASS");
  process.exit(failures ? 1 : 0);
}
