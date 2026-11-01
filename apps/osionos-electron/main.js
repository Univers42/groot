// ===========================================================================
// osionos desktop — Electron main process.
//
// Renders the bundled offline osionos (renderer/) with Chromium (fast on every
// OS, unlike Tauri's WebKitGTK on Linux), boots the local Track Binocle BaaS in
// the background, and provides a frameless window whose chrome is the app's own
// top bar (its window controls call the preload bridge).
// ===========================================================================
const { app, BrowserWindow, ipcMain, shell, protocol, net, Menu, globalShortcut, session, utilityProcess, MessageChannelMain } = require("electron");
const path = require("node:path");
const { existsSync, statSync, readFileSync } = require("node:fs");
const crypto = require("node:crypto");
const { createExternalOpenThrottle, isExternalHttpUrl, isAppPageUrl, isMachineWindowUrl, isAllowedSubframeUrl, senderAllowed, inlineScriptHashes, frameOriginsFrom, rendererCsp, editionOf, cspHeaderName, webSecurityFor, baasTargetOf, isLoopbackUrl } = require("./desktop-guards");
const { applyTailnetBypass } = require("./desktop-proxy");
const { bootSuite, startNative } = require("./desktop-backend");
const { ptyEnabledFor, createPtyBroker } = require("./desktop-pty");
const { createAppHandler } = require("./desktop-app-protocol");
const { appKeyAction } = require("./desktop-keys");

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
// standard + secure apply to every host, so app://terminal (ADR 0039) is its own secure origin.
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

let mainWindow = null;

// Every WebContents gets the same guards (per-window wiring missed child windows). The main
// frame never leaves app://osionos: the Mail/Calendar buttons set location.href to an external
// URL, which would strand the user on a page with no titlebar, so it opens in the system browser.
// A machine window (/machine, C23) is this machine's own IDE page, opened as a child window so the
// app can hand it a session through window.opener; it is the only page allowed off app://osionos,
// and only in a window the app opened. Its inherited preload is inert there: win:* is accepted from
// the main window alone (C12).
const MACHINE_WINDOW = { width: 1400, height: 900, frame: true, autoHideMenuBar: true, backgroundColor: "#ffffff" };
app.on("web-contents-created", (_e, contents) => {
  const openThrottle = createExternalOpenThrottle();
  const isMachinePage = (url) => contents.opener != null && isMachineWindowUrl(url);
  contents.setWindowOpenHandler(({ url }) => {
    if (isMachineWindowUrl(url)) return { action: "allow", overrideBrowserWindowOptions: MACHINE_WINDOW };
    if (isExternalHttpUrl(url)) {
      if (openThrottle.allow()) shell.openExternal(url);
      else console.warn("window.open throttled for host " + new URL(url).host);
    }
    return { action: "deny" };
  });
  contents.on("will-attach-webview", (e) => e.preventDefault());
  contents.on("will-navigate", (e, url) => {
    if (isAppPageUrl(url) || isMachinePage(url)) return;
    e.preventDefault();
    if (isExternalHttpUrl(url)) shell.openExternal(url);
  });
  contents.on("will-frame-navigate", (d) => {
    const allowed = d.isMainFrame ? isAppPageUrl(d.url) || isMachinePage(d.url) : isAllowedSubframeUrl(d.url);
    if (!allowed) d.preventDefault();
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

// The local terminal (devil verdict 2026-10-31): FULL only (C2). Shells live in a utilityProcess
// started on the first create (C6); create and kill are re-checked by the broker (C5). Each pty's
// I/O runs on its own MessageChannelMain, frame to host, never through main (ADR 0039).
const PTY_ENABLED = ptyEnabledFor(EDITION);
const ptyBroker = PTY_ENABLED ? createPtyBroker({
  senderAllowed,
  mainContents: () => mainWindow && mainWindow.webContents,
  startHost: startPtyHost,
  randomId: () => crypto.randomUUID(),
  createChannel: () => new MessageChannelMain(),
}) : null;
function startPtyHost() {
  const child = utilityProcess.fork(path.join(__dirname, "pty-host.js"), [], { serviceName: "osionos-terminal" });
  child.on("message", (message) => ptyBroker.onHostMessage(message));
  child.on("exit", () => ptyBroker.onHostExit());
  return { post: (message, ports) => child.postMessage(message, ports) };
}
if (ptyBroker) {
  ipcMain.handle("pty:create", (event, cols, rows) => ptyBroker.create(event, cols, rows));
  ipcMain.on("pty:kill", (event, id) => ptyBroker.kill(event, id));
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
      sandbox: true,
      spellcheck: true,
      // WHY: on in FULL (its C15 smoke ran clean; the bridge allows app://osionos
      // by CORS), off in LOCAL/NATIVE until their smoke runs (C15). While off, the
      // navigation/window-open guards (web-contents-created) keep foreign pages out
      // of this window, and authz stays in the auth-gateway + Postgres RLS.
      webSecurity: webSecurityFor(EDITION),
      additionalArguments: PTY_ENABLED ? ["--osionos-pty"] : [],
    },
  });
  mainWindow = win;
  // A reload, a renderer crash or a closed window ends the page that owned the shells (C6).
  const contentsId = win.webContents.id;
  const endShells = () => { if (ptyBroker) ptyBroker.killOwnedBy(contentsId); };
  win.webContents.on("did-start-navigation", (details) => { if (details.isMainFrame && !details.isSameDocument) endShells(); });
  win.webContents.on("render-process-gone", endShells);
  win.webContents.on("destroyed", endShells);
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
  // Reload (F5, Ctrl/Cmd+R), back to home (Ctrl/Cmd+Shift+H) and zoom (Ctrl/Cmd + = - 0), except
  // while the terminal frame has focus: those keys are the shell's (ADR 0039, T9).
  const keyActions = {
    reload: () => wc.reload(),
    home: () => wc.loadURL("app://osionos/index.html"),
    zoomIn: () => wc.setZoomLevel(clamp(wc.getZoomLevel() + 0.5)),
    zoomOut: () => wc.setZoomLevel(clamp(wc.getZoomLevel() - 0.5)),
    zoomReset: () => wc.setZoomLevel(0),
  };
  wc.on("before-input-event", (event, input) => {
    const action = appKeyAction(input, wc.focusedFrame && wc.focusedFrame.url);
    if (!action) return;
    keyActions[action]();
    event.preventDefault();
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
  protocol.handle("app", createAppHandler({ net, rendererDir, baasTarget: BAAS_TARGET, rendererPolicy, rendererCspHeader: cspHeaderName(EDITION) }));
  // A grobase elsewhere (the tailnet data center) leaves nothing on this machine to boot.
  if (IS_NATIVE) {
    try { nativeHandle = await startNative({ nativeDir: NATIVE_DIR, userDataDir: app.getPath("userData") }); } catch (e) { console.error("[native] backend failed to start:", e); }
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
