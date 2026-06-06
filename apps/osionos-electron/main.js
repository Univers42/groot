// ===========================================================================
// osionos desktop — Electron main process.
//
// Renders the bundled offline osionos (renderer/) with Chromium (fast on every
// OS, unlike Tauri's WebKitGTK on Linux), boots the local Track Binocle BaaS in
// the background, and provides a frameless window driven by the shared custom
// titlebar (see chrome/titlebar.html, injected into renderer/index.html).
// ===========================================================================
const { app, BrowserWindow, ipcMain, shell } = require("electron");
const path = require("node:path");
const os = require("node:os");
const { spawn } = require("node:child_process");

// Chromium GPU: rasterize on the GPU even if the driver is on the blocklist
// (helps AMD/Mesa on Linux). Safe no-ops elsewhere.
app.commandLine.appendSwitch("enable-gpu-rasterization");
app.commandLine.appendSwitch("ignore-gpu-blocklist");
app.commandLine.appendSwitch("enable-zero-copy");

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
    },
  });

  win.once("ready-to-show", () => win.show());
  win.loadFile(path.join(__dirname, "renderer", "index.html"));

  // Open external links in the real browser, not inside the app.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/i.test(url)) { shell.openExternal(url); return { action: "deny" }; }
    return { action: "allow" };
  });

  ipcMain.on("win:minimize", () => win.minimize());
  ipcMain.on("win:toggle-maximize", () => (win.isMaximized() ? win.unmaximize() : win.maximize()));
  ipcMain.on("win:close", () => win.close());
}

app.whenReady().then(() => {
  bootSuite();
  createWindow();
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});
