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
const { existsSync } = require("node:fs");

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

function trackBinocleHome() {
  return process.env.TRACK_BINOCLE_HOME
    || path.join(os.homedir(), "Documents", "ft_transcendence");
}

// Best-effort: bring the local suite up so opening the app starts the backend.
function bootSuite() {
  const home = trackBinocleHome();
  try {
    const child = spawn("docker", ["compose", "--profile", "dev", "up", "-d"], {
      cwd: home, detached: true, stdio: "ignore",
    });
    child.on("error", () => {}); // docker not installed -> offline mode covers it
    child.unref();
  } catch { /* ignore */ }
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

app.whenReady().then(() => {
  const rendererDir = path.join(__dirname, "renderer");
  protocol.handle("app", (request) => {
    let pathname = decodeURIComponent(new URL(request.url).pathname);
    if (pathname === "/" || pathname === "") pathname = "/index.html";
    let filePath = path.join(rendererDir, pathname);
    if (!filePath.startsWith(rendererDir) || !existsSync(filePath)) filePath = path.join(rendererDir, "index.html");
    return net.fetch(pathToFileURL(filePath).toString());
  });
  bootSuite();
  createWindow();
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});
