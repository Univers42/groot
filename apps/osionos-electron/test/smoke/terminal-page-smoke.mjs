// VS Code's terminal page in the real desktop shell (ADR 0038, devil amendment A1-A6): Playwright
// _electron under xvfb, no sign-in. The dock lives behind sign-in, so the main window plays the
// panel's side of the port (osionos terminalPort.ts servePtyOverPort, pinned by its unit tests);
// the page, VS Code's terminal, the keystrokes, the shell, the CSP and the frame guards are real.
// Caveat: the shell is the container's (root, /bin/bash); time-to-prompt is one sample under xvfb
// with no GPU, so it is an upper bound for a desktop, not a benchmark. CSP violations are counted
// from console messages, so one Chromium reports without a console line would be missed.
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";

const { _electron } = createRequire("/cache/")("playwright-core");
let failures = 0;
const say = (verdict, name, evidence) => console.log(`${verdict} ${name} — ${evidence}`);
async function check(name, fn) {
  try { say("PASS", name, (await fn()) ?? "ok"); } catch (e) { failures++; say("FAIL", name, String(e?.message ?? e).split("\n")[0].slice(0, 300)); }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const assert = (ok, msg) => { if (!ok) throw new Error(msg); };
const ps = () => execFileSync("ps", ["-eo", "pid=,ppid=,args="], { encoding: "utf8" }).trim().split("\n")
  .map((l) => l.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/)).filter(Boolean).map(([, pid, ppid, args]) => ({ pid: +pid, ppid: +ppid, args }));
const hostPid = () => ps().find((p) => /--type=utility/.test(p.args) && /node\.mojom\.NodeService/.test(p.args))?.pid ?? null;
const shells = () => { const h = hostPid(); return h ? ps().filter((p) => p.ppid === h).length : 0; };
async function until(probe, ms, what) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (await probe()) return; await sleep(100); }
  throw new Error(`timed out: ${what}`);
}

const app = await _electron.launch({ executablePath: "/cache/node_modules/electron/dist/electron", args: ["/app"] });
const page = await app.firstWindow();
await page.waitForLoadState("load");
// The app's start-up can navigate after load (to its sign-in page); a frame added before that is
// thrown away with the document, so the checks start once the URL has held for 2 s.
for (let url = page.url(), held = 0; held < 2000; held += 250) {
  await sleep(250);
  if (page.url() !== url) { url = page.url(); held = 0; await page.waitForLoadState("load"); }
}
const cspLines = [];
page.on("console", (m) => {
  const text = m.text();
  if (!/Content Security Policy|Refused to/i.test(text)) return;
  const what = text.match(/^(?:Refused to \w+ |Connecting to )?'?([a-z-]+:[^'\s]{0,40})/i)?.[1] ?? text.slice(0, 60);
  cspLines.push(`${what} (${text.match(/directive: "([a-z-]+)/i)?.[1] ?? "?"})`);
});

// The panel: frame the page, hand it a port on load, serve the desktop pty over it.
const frameTerminal = (frameId, { handOff = true, inside = null } = {}) => page.evaluate(([fid, give, host]) => {
  const pty = window.osionosDesktop.pty;
  const log = (window.__panel = window.__panel || {})[fid] = { creates: 0, out: "", t0: performance.now(), tFirst: null };
  const doc = host ? document.getElementById(host).contentDocument : document;
  const frame = doc.createElement("iframe");
  frame.id = fid;
  frame.style.cssText = "position:fixed;left:0;bottom:0;width:900px;height:320px;border:0;z-index:99999";
  frame.src = "/terminal/index.html";
  frame.addEventListener("load", () => {
    if (!give) return;
    const { port1, port2 } = new MessageChannel();
    port1.onmessage = async ({ data: m }) => {
      if (m.op === "create") {
        log.creates++;
        const id = await pty.create(m.cols, m.rows);
        if (id) {
          pty.onData(id, (d) => { log.tFirst ??= performance.now(); log.out += d; port1.postMessage({ op: "data", id, data: d }); });
          pty.onExit(id, (exitCode) => port1.postMessage({ op: "exit", id, exitCode }));
        }
        port1.postMessage({ op: "created", req: m.req, id });
      } else if (m.op === "write") pty.write(m.id, m.data);
      else if (m.op === "resize") pty.resize(m.id, m.cols, m.rows);
      else if (m.op === "ack") pty.ack(m.id, m.chars);
      else if (m.op === "kill") pty.kill(m.id);
    };
    frame.contentWindow.postMessage({ type: "osionos-terminal/port", colors: { background: "#0d1117", foreground: "#e6edf3" } }, location.origin, [port2]);
  });
  doc.body.appendChild(frame);
}, [frameId, handOff, inside]);
const panel = (frameId) => page.evaluate((fid) => window.__panel[fid], frameId);
const xtermIn = (frameId) => page.evaluate((fid) => !!document.getElementById(fid)?.contentDocument?.querySelector(".xterm"), frameId);

try {
  await check("A1 handed a port, the page starts VS Code's terminal on a shell", async () => {
    await frameTerminal("t1");
    await until(async () => (await panel("t1")).tFirst !== null, 20000, "the first shell output");
    await until(() => xtermIn("t1"), 10000, "VS Code's .xterm in the frame");
    const p = await panel("t1");
    return `${p.creates} create; first shell output ${Math.round(p.tFirst - p.t0)} ms after the frame was added`;
  });
  await check("typing in VS Code's terminal reaches the shell and its answer comes back", async () => {
    await page.locator("#t1").click({ position: { x: 300, y: 150 } });
    await sleep(300);
    await page.keyboard.type("echo vscode-$((6*7))");
    await page.keyboard.press("Enter");
    await until(async () => /vscode-42/.test((await panel("t1")).out), 10000, "vscode-42 from the shell");
    await sleep(300);
    await page.locator("#t1").screenshot({ path: "/out/terminal-page.png" });
    return "keystrokes went VS Code -> port -> pty, the echo came back";
  });
  await check("A1 a frame of the page with no handoff starts nothing and draws nothing", async () => {
    const before = shells();
    await frameTerminal("t2", { handOff: false });
    await sleep(4000);
    assert(!(await xtermIn("t2")), "a terminal was drawn");
    assert(shells() === before, `${shells() - before} shells appeared`);
    return `0 shells, no .xterm after 4 s (${before} shells before and after)`;
  });
  await check("A2 framed below another frame, the page refuses even a handed port", async () => {
    await page.evaluate(() => { const f = document.createElement("iframe"); f.id = "host"; f.src = "about:blank"; document.body.appendChild(f); });
    await sleep(300);
    const before = shells();
    await frameTerminal("t3", { inside: "host" });
    await sleep(4000);
    const nested = await page.evaluate(() => !!document.getElementById("host").contentDocument.getElementById("t3")?.contentDocument?.querySelector(".xterm"));
    assert(!nested, "the nested page drew a terminal");
    assert((await panel("t3")).creates === 0 && shells() === before, "the nested page asked for a shell");
    return "0 creates, no .xterm (parent is not top)";
  });
  await check("A6 no CSP violation in the app or the terminal page", async () => {
    assert(await xtermIn("t1"), "VS Code's terminal is not on the page: 0 violations would prove nothing");
    assert(cspLines.length === 0, `${cspLines.length}: ${[...new Set(cspLines)].join(" | ")}`);
    return "0 console lines naming the Content Security Policy";
  });
} catch (e) {
  failures++;
  say("FAIL", "run", String(e?.message ?? e).split("\n")[0]);
} finally {
  await app.close().catch(() => {});
  console.log(failures ? "RESULT FAIL" : "RESULT PASS");
  process.exit(failures ? 1 : 0);
}
