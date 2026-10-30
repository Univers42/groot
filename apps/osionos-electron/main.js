// ===========================================================================
// osionos desktop — Electron main process.
//
// Renders the bundled offline osionos (renderer/) with Chromium (fast on every
// OS, unlike Tauri's WebKitGTK on Linux), boots the local Track Binocle BaaS in
// the background, and provides a frameless window whose chrome is the app's own
// top bar (its window controls call the preload bridge).
// ===========================================================================
const { app, BrowserWindow, ipcMain, shell, protocol, net, Menu, globalShortcut, session } = require("electron");
const path = require("node:path");
const os = require("node:os");
const { spawn } = require("node:child_process");
const { pathToFileURL } = require("node:url");
const { existsSync, statSync, mkdirSync, readFileSync, writeFileSync } = require("node:fs");
const crypto = require("node:crypto");
const { createExternalOpenThrottle, isExternalHttpUrl, isAppPageUrl, isAllowedSubframeUrl, senderAllowed, baasResponseHeaders, inlineScriptHashes, frameOriginsFrom, rendererCsp, editionOf, cspHeaderName, webSecurityFor, baasTargetOf, isLoopbackUrl } = require("./desktop-guards");
const { applyTailnetBypass } = require("./desktop-proxy");

// The local mini-baas query-router speaks plain HTTP. The renderer runs from the
// secure `app://` origin, where a direct http://localhost:8002 fetch is upgraded
// to https and fails (ERR_SSL_PROTOCOL_ERROR — the router has no TLS). So the
// renderer calls it same-origin via app://osionos/__baas/* and the app:// handler
// relays to this target in the main process, where no mixed-content/upgrade rules
// apply. OSIONOS_BAAS_URL at launch overrides it; a build for a grobase elsewhere
// (build.sh with OSIONOS_DESKTOP_BAAS_URL) bakes it into desktop-config.json, so the
// app launched from the menu reaches it with no environment.
function bakedBaasUrl() {
  try { return JSON.parse(readFileSync(path.join(__dirname, "desktop-config.json"), "utf8")).baasUrl || ""; }
  catch { return ""; }
}
const BAAS_TARGET = baasTargetOf(process.env.OSIONOS_BAAS_URL, bakedBaasUrl());

// Serve the bundled renderer from a stable app:// origin (so the bridge's CORS
// can allow it) instead of file:// (origin "null", which CORS rejects). Must be
// registered before the app is ready. webSecurity depends on the edition (see EDITION).
protocol.registerSchemesAsPrivileged([
  { scheme: "app", privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true } },
]);

// Chromium GPU: rasterize on the GPU even if the driver is on the blocklist
// (helps AMD/Mesa on Linux). Safe no-ops elsewhere.
app.commandLine.appendSwitch("enable-gpu-rasterization");
app.commandLine.appendSwitch("ignore-gpu-blocklist");
app.commandLine.appendSwitch("enable-zero-copy");
// Mouse wheel: Chromium eases each notch over ~100ms ("smooth scrolling"), which
// on Linux feels like hesitation/lag with a real mouse. Disable -> instant,
// 1:1 wheel scrolling.
app.commandLine.appendSwitch("disable-smooth-scrolling");
// Disable the chrome sandbox ONLY when its setuid helper isn't usable — i.e. the
// AppImage (read-only temp mount) or a kernel that restricts unprivileged user
// namespaces (Ubuntu 24.04). The installed .deb setuids /opt/osionos/chrome-sandbox,
// so it KEEPS its sandbox. (process.env.APPIMAGE is not reliably set, so probe the
// helper's mode directly.) The setuid helper exists only on Linux, so other
// platforms never drop the sandbox.
if (process.platform === "linux") {
  try {
    const sandbox = path.join(path.dirname(process.execPath), "chrome-sandbox");
    const st = statSync(sandbox);
    const setuidRoot = st.uid === 0 && (st.mode & 0o4000) !== 0;
    if (!setuidRoot) app.commandLine.appendSwitch("no-sandbox");
  } catch {
    app.commandLine.appendSwitch("no-sandbox"); // helper missing → can't sandbox anyway
  }
}

function trackBinocleHome() {
  return process.env.TRACK_BINOCLE_HOME
    || path.join(os.homedir(), "Documents", "ft_transcendence");
}

// Best-effort: bring the local suite up so opening the app starts the backend.
function bootSuite() {
  // LOCAL edition: the installer points OSIONOS_LOCAL_COMPOSE at the bundled
  // docker-compose.local.yml and we bring up only the lean `local` profile (HTTP).
  // Otherwise (dev repo) fall back to the full `dev` profile in the repo checkout.
  const localCompose = process.env.OSIONOS_LOCAL_COMPOSE;
  const cwd = localCompose ? path.dirname(localCompose) : trackBinocleHome();
  const args = localCompose
    ? ["compose", "-f", localCompose, "--profile", "local", "up", "-d"]
    : ["compose", "--profile", "dev", "up", "-d"];
  try {
    const child = spawn("docker", args, { cwd, detached: true, stdio: "ignore" });
    child.on("error", () => {}); // docker missing / no compose -> the app just shows offline
    child.unref();
  } catch { /* ignore */ }
}

// NATIVE edition: a bundled `native-runtime/` (extraResources) means NO Docker —
// supervise embedded postgres + postgrest + gateway + bridge as child processes.
const NATIVE_DIR = path.join(process.resourcesPath || __dirname, "native-runtime");
const IS_NATIVE = existsSync(path.join(NATIVE_DIR, "native", "supervisor.mjs"));
// WHY: FULL enforces the CSP and turns webSecurity on after its clean C15 smoke; LOCAL/NATIVE wait for theirs.
// Ponytail: the edition is inferred, not declared — a LOCAL build launched without
// OSIONOS_LOCAL_COMPOSE reads as FULL and gets the stricter settings (fails toward
// enforcement; its :4000 calls then rely on the bridge's CORS). Escape hatch: set the env.
const EDITION = editionOf({ isNative: IS_NATIVE, localCompose: process.env.OSIONOS_LOCAL_COMPOSE });
let nativeHandle = null;

// Boot the bundled backend (no Docker). Node children run under Electron's own
// binary via ELECTRON_RUN_AS_NODE, so we ship no separate `node`. The pg superuser
// password is generated once and persisted (postgres bakes it into PGDATA at initdb).
async function startNative() {
  const { pathToFileURL } = require("node:url");
  const { startSuite, DEFAULT_PORTS } = await import(pathToFileURL(path.join(NATIVE_DIR, "native", "supervisor.mjs")).href);
  const dataDir = path.join(app.getPath("userData"), "native");
  mkdirSync(dataDir, { recursive: true });
  const pwPath = path.join(dataDir, "pgsuper.key");
  const superPass = existsSync(pwPath) ? readFileSync(pwPath, "utf8").trim()
    : (() => { const p = crypto.randomBytes(18).toString("hex"); writeFileSync(pwPath, p, { mode: 0o600 }); return p; })();
  const pgBin = path.join(NATIVE_DIR, "pgsql", "bin");
  const bin = {
    node: process.execPath, nodeEnv: { ELECTRON_RUN_AS_NODE: "1" },
    initdb: path.join(pgBin, "initdb"), postgres: path.join(pgBin, "postgres"),
    postgrest: path.join(NATIVE_DIR, "bin", "postgrest"),
    gotrue: path.join(NATIVE_DIR, "bin", "gotrue"), gotrueMigrations: path.join(NATIVE_DIR, "gotrue-migrations"),
    gatewayDir: path.join(NATIVE_DIR, "gateway"), gatewayScript: path.join(NATIVE_DIR, "gateway", "scripts", "auth-gateway.mjs"),
    bridgeScript: path.join(NATIVE_DIR, "bridge", "bridge-api.mjs"),
  };
  nativeHandle = await startSuite({ bin, dataDir, ports: DEFAULT_PORTS, superPass, migrationsDir: path.join(NATIVE_DIR, "models"), appUrl: "app://osionos" });
}

let mainWindow = null;

// Every WebContents gets the same guards (per-window wiring missed child windows). The main
// frame never leaves app://osionos: the Mail/Calendar buttons set location.href to an external
// URL, which would strand the user on a page with no titlebar, so it opens in the system browser.
app.on("web-contents-created", (_e, contents) => {
  const openThrottle = createExternalOpenThrottle();
  contents.setWindowOpenHandler(({ url }) => {
    if (isExternalHttpUrl(url)) {
      if (openThrottle.allow()) shell.openExternal(url);
      else console.warn("window.open throttled for host " + new URL(url).host);
    }
    return { action: "deny" };
  });
  contents.on("will-attach-webview", (e) => e.preventDefault());
  contents.on("will-navigate", (e, url) => {
    if (isAppPageUrl(url)) return;
    e.preventDefault();
    if (isExternalHttpUrl(url)) shell.openExternal(url);
  });
  contents.on("will-frame-navigate", (d) => {
    if (d.isMainFrame ? !isAppPageUrl(d.url) : !isAllowedSubframeUrl(d.url)) d.preventDefault();
  });
});

// WHY: win:* registered once here so a second window cannot double-register; the C12 sender check stops framed pages driving the window.
ipcMain.on("win:minimize", (event) => {
  if (!senderAllowed(event, mainWindow && mainWindow.webContents)) return;
  if (mainWindow) mainWindow.minimize();
});
ipcMain.on("win:toggle-maximize", (event) => {
  if (!senderAllowed(event, mainWindow && mainWindow.webContents)) return;
  if (mainWindow) (mainWindow.isMaximized() ? mainWindow.unmaximize() : mainWindow.maximize());
});
ipcMain.on("win:close", (event) => {
  if (!senderAllowed(event, mainWindow && mainWindow.webContents)) return;
  if (mainWindow) mainWindow.close();
});

function createWindow() {
  const win = new BrowserWindow({
    width: 1280,
    height: 832,
    minWidth: 960,
    minHeight: 600,
    frame: false,                 // frameless -> our custom titlebar
    backgroundColor: "#111317",
    show: false,
    autoHideMenuBar: true,
    icon: path.join(__dirname, "icon.png"),
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: true,
      // WHY: on in FULL (its C15 smoke ran clean; the bridge allows app://osionos
      // by CORS), off in LOCAL/NATIVE until their smoke runs (C15). While off, the
      // navigation/window-open guards (web-contents-created) keep foreign pages out
      // of this window, and authz stays in the auth-gateway + Postgres RLS.
      webSecurity: webSecurityFor(EDITION),
    },
  });
  mainWindow = win;
  // A destroyed BrowserWindow throws on .webContents; the win:* handlers read it on every message.
  win.on("closed", () => { if (mainWindow === win) mainWindow = null; });

  win.once("ready-to-show", () => win.show());
  win.loadURL("app://osionos/index.html");

  // Black-screen recovery: the titlebar + UI live in the renderer, so a crashed or
  // hung renderer leaves you with no window controls. Reload back to the app home
  // automatically; Ctrl/Cmd+Shift+R (global, below) is the manual escape hatch.
  win.webContents.on("render-process-gone", () => { try { win.loadURL("app://osionos/index.html"); } catch { /* */ } });
  win.webContents.on("unresponsive", () => { try { win.webContents.reload(); } catch { /* */ } });

  // Zoom — wired explicitly (Tauri's zoomHotkeysEnabled has no Electron equivalent).
  const wc = win.webContents;
  const clamp = (z) => Math.max(-3, Math.min(6, z));
  // Keyboard: Ctrl/Cmd +  /  -  /  0
  wc.on("before-input-event", (event, input) => {
    if (input.type !== "keyDown") return;
    // Reload / back-to-home recovery (F5, Ctrl/Cmd+R, Ctrl/Cmd+Shift+H).
    if (input.key === "F5" || ((input.control || input.meta) && /^r$/i.test(input.key))) { wc.reload(); event.preventDefault(); return; }
    if ((input.control || input.meta) && input.shift && /^h$/i.test(input.key)) { wc.loadURL("app://osionos/index.html"); event.preventDefault(); return; }
    if (!(input.control || input.meta)) return;
    const zoomIn = input.key === "=" || input.key === "+" || input.code === "Equal" || input.code === "NumpadAdd";
    const zoomOut = input.key === "-" || input.key === "_" || input.code === "Minus" || input.code === "NumpadSubtract";
    if (zoomIn) { wc.setZoomLevel(clamp(wc.getZoomLevel() + 0.5)); event.preventDefault(); }
    else if (zoomOut) { wc.setZoomLevel(clamp(wc.getZoomLevel() - 0.5)); event.preventDefault(); }
    else if (input.key === "0") { wc.setZoomLevel(0); event.preventDefault(); }
  });
  // Ctrl + mouse-wheel: Chromium emits zoom-changed (no custom wheel listener,
  // so this can't slow scrolling back down).
  wc.on("zoom-changed", (_event, dir) => {
    wc.setZoomLevel(clamp(wc.getZoomLevel() + (dir === "in" ? 0.5 : -0.5)));
  });
}

app.whenReady().then(async () => {
  // No native application menu: the app uses its own custom titlebar, and the GTK
  // global-menu integration otherwise spams LIBDBUSMENU-GLIB-WARNING on Linux.
  Menu.setApplicationMenu(null);
  const rendererDir = path.join(__dirname, "renderer");
  // WHY: the file responses carry this CSP (enforced in FULL, Report-Only elsewhere); [] hashes on read failure keeps the header present.
  const frameOrigins = frameOriginsFrom(process.env.OSIONOS_FRAME_ORIGINS);
  let rendererPolicy = rendererCsp({ scriptHashes: [], frameOrigins });
  try {
    const html = readFileSync(path.join(rendererDir, "index.html"), "utf8");
    rendererPolicy = rendererCsp({ scriptHashes: inlineScriptHashes(html), frameOrigins });
  } catch (err) {
    console.error("[desktop] renderer CSP fallback without hashes:", err && err.message ? err.message : err);
  }
  protocol.handle("app", async (request) => {
    const url = new URL(request.url);
    // BaaS proxy: relay same-origin app://osionos/__baas/* to the plain-HTTP
    // query-router from the main process (no renderer HTTPS-upgrade). Buffer both
    // directions and forward only the headers the router needs, so the response
    // can't trip Chromium with a content-encoding/length mismatch (which showed
    // up as net::ERR_UNEXPECTED). Never throw — return a 502 on failure.
    if (url.pathname.startsWith("/__baas/")) {
      const target = BAAS_TARGET + url.pathname.slice("/__baas".length) + url.search;
      const headers = new Headers();
      for (const name of ["content-type", "accept", "x-baas-api-key", "apikey", "authorization"]) {
        const value = request.headers.get(name);
        if (value) headers.set(name, value);
      }
      const init = { method: request.method, headers };
      if (request.method !== "GET" && request.method !== "HEAD") {
        init.body = await request.arrayBuffer();
      }
      try {
        const upstream = await net.fetch(target, init);
        const body = await upstream.arrayBuffer();
        // WHY: upstream MIME/headers are never trusted; baasResponseHeaders forces octet-stream + sandbox.
        return new Response(body, { status: upstream.status, statusText: upstream.statusText, headers: baasResponseHeaders(upstream.headers.get("content-type")) });
      } catch (error) {
        return new Response(JSON.stringify({ error: "baas proxy failed", detail: String(error) }), {
          status: 502,
          headers: baasResponseHeaders("application/json"),
        });
      }
    }
    let pathname = decodeURIComponent(url.pathname);
    if (pathname === "/" || pathname === "") pathname = "/index.html";
    let filePath = path.join(rendererDir, pathname);
    if (!filePath.startsWith(rendererDir) || !existsSync(filePath)) filePath = path.join(rendererDir, "index.html");
    // WHY: every app:// file response (including the index fallback) carries the CSP (enforced in FULL, Report-Only in LOCAL/NATIVE whose C15 smoke is pending).
    const res = await net.fetch(pathToFileURL(filePath).toString());
    const headers = new Headers(res.headers);
    headers.set(cspHeaderName(EDITION), rendererPolicy);
    return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
  });
  // A grobase elsewhere (the tailnet data center) leaves nothing on this machine to boot.
  if (IS_NATIVE) {
    try { await startNative(); } catch (e) { console.error("[native] backend failed to start:", e); }
  } else if (isLoopbackUrl(BAAS_TARGET)) {
    bootSuite();
  }
  // Before the first request: the data center's tailnet goes direct, the rest keeps the system proxy.
  try {
    const bypass = await applyTailnetBypass(session.defaultSession, BAAS_TARGET);
    if (bypass) console.info(`[desktop] direct to the tailnet (${bypass.proxyBypassRules}); other traffic via ${bypass.proxyRules}`);
  } catch (e) {
    console.error("[desktop] tailnet proxy exception not applied; every request uses the system proxy:", e && e.message ? e.message : e);
  }
  createWindow();
  // OS-level recovery that works even if the renderer is completely dead (a black
  // screen can't receive in-page keystrokes): Ctrl/Cmd+Shift+R reloads to the app home.
  globalShortcut.register("CommandOrControl+Shift+R", () => {
    const w = BrowserWindow.getFocusedWindow() || BrowserWindow.getAllWindows()[0];
    if (w) w.loadURL("app://osionos/index.html");
  });
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

// Tear down the bundled native backend (postgres/postgrest/gateway/bridge) on exit.
app.on("before-quit", () => {
  globalShortcut.unregisterAll();
  if (nativeHandle) { try { nativeHandle.stop(); } catch { /* */ } nativeHandle = null; }
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});
