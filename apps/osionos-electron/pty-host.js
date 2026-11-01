// The pty host: a utilityProcess that owns every terminal shell, so a flood of output or a crash
// here never stalls the main process (window controls, the BaaS relay). The parent port carries
// only main's create and kill, already checked by the broker (desktop-pty.js); each pty's I/O
// arrives on its own port, straight from the terminal frame, and is validated in bindPtyPort.
const os = require("node:os");
const pty = require("node-pty");
const { createPtySessions, shellCommand } = require("./desktop-pty");

const { shell, args } = shellCommand({ accountShell: os.userInfo().shell, envShell: process.env.SHELL, platform: process.platform });
const sessions = createPtySessions({
  spawn: pty.spawn,
  post: (message) => process.parentPort.postMessage(message),
  env: process.env,
  home: os.homedir(),
  shell,
  args,
});
process.parentPort.on("message", (event) => {
  try { sessions.handle(event.data, event.ports); } catch (err) { console.error("[pty-host] dropped a message from main:", err && err.message); }
});
