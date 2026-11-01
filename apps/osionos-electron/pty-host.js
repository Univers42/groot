// The pty host: a utilityProcess that owns every terminal shell, so a flood of output or a crash
// here never stalls the main process (window controls, the BaaS relay). Messages come only from
// the main process's broker (desktop-pty.js), which has already checked the sender.
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
process.parentPort.on("message", (event) => sessions.handle(event.data));
