// Preload bridge: exposes a tiny, safe window-control API to the renderer so
// the shared titlebar (chrome/titlebar.html) can drive the frameless window.
// contextIsolation is on, so nothing else from Node leaks into the page.
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("osionosDesktop", {
  minimize: () => ipcRenderer.send("win:minimize"),
  toggleMaximize: () => ipcRenderer.send("win:toggle-maximize"),
  close: () => ipcRenderer.send("win:close"),
});
