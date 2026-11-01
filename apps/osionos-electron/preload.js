// Preload bridge: exposes a tiny, safe window-control API to the renderer so
// the app's own top bar can drive the frameless window.
// contextIsolation is on, so nothing else from Node leaks into the page.
// C12: the main process accepts win:* only from the main window's top frame at app://osionos/.
const { contextBridge, ipcRenderer } = require("electron");

// The local terminal (devil verdict 2026-10-31, C2/C5): only the FULL edition's main window is
// started with --osionos-pty, and a child window inheriting this preload (the machine window,
// http://127.0.0.1) never sees the API. The main process re-checks every call regardless.
const ptyAllowed = process.argv.includes("--osionos-pty") && location.origin === "app://osionos";

// Each pty's port arrives from main and is reposted to this window, the app's main world, as
// { type: "osionos-pty-port", id } (ADR 0039). contextBridge cannot carry a MessagePort, so the
// panel must check event.source === window before it trusts one: embeds post to the same event.
function localPtyApi() {
  const exits = new Map();
  ipcRenderer.on("pty:exit", (_event, id, exitCode) => {
    for (const cb of exits.get(id) || []) cb(exitCode);
  });
  ipcRenderer.on("pty:port", (event, message) => {
    const id = message && message.id;
    if (typeof id !== "string" || event.ports.length !== 1) {
      for (const port of event.ports) port.close();
      return;
    }
    window.postMessage({ type: "osionos-pty-port", id }, location.origin, [event.ports[0]]);
  });
  const onExit = (id, cb) => {
    const set = exits.get(id) || new Set();
    set.add(cb);
    exits.set(id, set);
    return () => {
      set.delete(cb);
      if (set.size === 0) exits.delete(id);
    };
  };
  return {
    create: (cols, rows) => ipcRenderer.invoke("pty:create", cols, rows),
    kill: (id) => ipcRenderer.send("pty:kill", id),
    onExit,
  };
}

contextBridge.exposeInMainWorld("osionosDesktop", {
  minimize: () => ipcRenderer.send("win:minimize"),
  toggleMaximize: () => ipcRenderer.send("win:toggle-maximize"),
  close: () => ipcRenderer.send("win:close"),
  ...(ptyAllowed ? { pty: localPtyApi() } : {}),
});
