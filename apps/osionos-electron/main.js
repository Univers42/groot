// ===========================================================================
// osionos desktop — Electron main process.
//
// Renders the bundled offline osionos (renderer/) with Chromium (fast on every
// OS, unlike Tauri's WebKitGTK on Linux), boots the local Track Binocle BaaS in
// the background, and provides a frameless window driven by the shared custom
// titlebar (see chrome/titlebar.html, injected into renderer/index.html).
// ===========================================================================
const { app, BrowserWindow, ipcMain, shell, protocol, net } = require("electron");
const path = require("node:path");
const os = require("node:os");
const { spawn } = require("node:child_process");
const { pathToFileURL } = require("node:url");
const { existsSync, statSync, mkdirSync, readFileSync, writeFileSync } = require("node:fs");
const crypto = require("node:crypto");

// The local mini-baas query-router speaks plain HTTP. The renderer runs from the
// secure `app://` origin, where a direct http://localhost:8002 fetch is upgraded
// to https and fails (ERR_SSL_PROTOCOL_ERROR — the router has no TLS). So the
// renderer calls it same-origin via app://osionos/__baas/* and the app:// handler
// relays to this target in the main process, where no mixed-content/upgrade rules
// apply. Override with OSIONOS_BAAS_URL if the router runs elsewhere.
//
// MUST be 127.0.0.1, not "localhost": Chromium's net.fetch resolves "localhost" to
// IPv6 ::1 first, but the mini-baas Kong binds IPv4-only (127.0.0.1:8002), so an
// ::1 attempt is refused → net.fetch throws → the proxy returns 502 (the graph /
// database calls fail). Coerce any localhost override to IPv4 too.
const BAAS_TARGET = (process.env.OSIONOS_BAAS_URL || "http://127.0.0.1:8002")
  .replace(/\/+$/, "")
  .replace(/\/\/localhost(?=[:/]|$)/, "//127.0.0.1");

// Serve the bundled renderer from a stable app:// origin (so the bridge's CORS
// can allow it) instead of file:// (origin "null", which CORS rejects). Keeps
// webSecurity ON. Must be registered before the app is ready.
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
// helper's mode directly.)
try {
  const sandbox = path.join(path.dirname(process.execPath), "chrome-sandbox");
  const st = statSync(sandbox);
  const setuidRoot = st.uid === 0 && (st.mode & 0o4000) !== 0;
  if (!setuidRoot) app.commandLine.appendSwitch("no-sandbox");
} catch {
  app.commandLine.appendSwitch("no-sandbox"); // helper missing → can't sandbox anyway
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
    gatewayDir: path.join(NATIVE_DIR, "gateway"), gatewayScript: path.join(NATIVE_DIR, "gateway", "scripts", "auth-gateway.mjs"),
    bridgeScript: path.join(NATIVE_DIR, "bridge", "bridge-api.mjs"),
  };
  nativeHandle = await startSuite({ bin, dataDir, ports: DEFAULT_PORTS, superPass, migrationsDir: path.join(NATIVE_DIR, "models"), appUrl: "app://osionos" });
}

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
      spellcheck: true,
      // Local desktop app: it loads ONLY its own bundled content (app://osionos)
      // and talks to several LOCAL backends (bridge:4000, kong:8000). Disabling
      // the renderer's same-origin/CORS/mixed-content enforcement lets those
      // direct calls work without configuring CORS on every service. Real
      // security stays in the auth-gateway + Postgres RLS; external links open
      // in the system browser (setWindowOpenHandler), so no untrusted content runs.
      webSecurity: false,
    },
  });

  win.once("ready-to-show", () => win.show());
  win.loadURL("app://osionos/index.html");

  // Open external links in the real browser, not inside the app.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/i.test(url)) { shell.openExternal(url); return { action: "deny" }; }
    return { action: "allow" };
  });

  ipcMain.on("win:minimize", () => win.minimize());
  ipcMain.on("win:toggle-maximize", () => (win.isMaximized() ? win.unmaximize() : win.maximize()));
  ipcMain.on("win:close", () => win.close());

  // Zoom — wired explicitly (Tauri's zoomHotkeysEnabled has no Electron equivalent).
  const wc = win.webContents;
  const clamp = (z) => Math.max(-3, Math.min(6, z));
  // Keyboard: Ctrl/Cmd +  /  -  /  0
  wc.on("before-input-event", (event, input) => {
    if (input.type !== "keyDown" || !(input.control || input.meta)) return;
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
  const rendererDir = path.join(__dirname, "renderer");
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
        const out = new Headers();
        const contentType = upstream.headers.get("content-type");
        if (contentType) out.set("content-type", contentType);
        return new Response(body, { status: upstream.status, statusText: upstream.statusText, headers: out });
      } catch (error) {
        return new Response(JSON.stringify({ error: "baas proxy failed", detail: String(error) }), {
          status: 502,
          headers: { "content-type": "application/json" },
        });
      }
    }
    let pathname = decodeURIComponent(url.pathname);
    if (pathname === "/" || pathname === "") pathname = "/index.html";
    let filePath = path.join(rendererDir, pathname);
    if (!filePath.startsWith(rendererDir) || !existsSync(filePath)) filePath = path.join(rendererDir, "index.html");
    return net.fetch(pathToFileURL(filePath).toString());
  });
  if (IS_NATIVE) {
    try { await startNative(); } catch (e) { console.error("[native] backend failed to start:", e); }
  } else {
    bootSuite();
  }
  createWindow();
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

// Tear down the bundled native backend (postgres/postgrest/gateway/bridge) on exit.
app.on("before-quit", () => { if (nativeHandle) { try { nativeHandle.stop(); } catch { /* */ } nativeHandle = null; } });

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});
