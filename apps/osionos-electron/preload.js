// Preload bridge: exposes a tiny, safe window-control API to the renderer so
// the app's own top bar can drive the frameless window.
// contextIsolation is on, so nothing else from Node leaks into the page.
// C12: the main process accepts win:* only from the main window's top frame at app://osionos/.
const { contextBridge, ipcRenderer } = require("electron");

// The local terminal (devil verdict 2026-10-31, C2/C5): only the FULL edition's main window is
// started with --osionos-pty, and a child window inheriting this preload (the machine window,
// http://127.0.0.1) never sees the API. The main process re-checks every call regardless.
const ptyAllowed = process.argv.includes("--osionos-pty") && location.origin === "app://osionos";

function localPtyApi() {
  const listeners = { data: new Map(), exit: new Map() };
  const dispatch = (kind) => (_event, id, value) => {
    for (const cb of listeners[kind].get(id) || []) cb(value);
  };
  ipcRenderer.on("pty:data", dispatch("data"));
  ipcRenderer.on("pty:exit", dispatch("exit"));
  const subscribe = (kind, id, cb) => {
    const set = listeners[kind].get(id) || new Set();
    set.add(cb);
    listeners[kind].set(id, set);
    return () => {
      set.delete(cb);
      if (set.size === 0) listeners[kind].delete(id);
    };
  };
  return {
    create: (cols, rows) => ipcRenderer.invoke("pty:create", cols, rows),
    write: (id, data) => ipcRenderer.send("pty:write", id, data),
    resize: (id, cols, rows) => ipcRenderer.send("pty:resize", id, cols, rows),
    kill: (id) => ipcRenderer.send("pty:kill", id),
    ack: (id, chars) => ipcRenderer.send("pty:ack", id, chars),
    onData: (id, cb) => subscribe("data", id, cb),
    onExit: (id, cb) => subscribe("exit", id, cb),
  };
}

contextBridge.exposeInMainWorld("osionosDesktop", {
  minimize: () => ipcRenderer.send("win:minimize"),
  toggleMaximize: () => ipcRenderer.send("win:toggle-maximize"),
  close: () => ipcRenderer.send("win:close"),
  ...(ptyAllowed ? { pty: localPtyApi() } : {}),
});
