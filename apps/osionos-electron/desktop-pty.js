// The desktop's local terminal (devil verdict 2026-10-31, docs/ide/vscode-backend in osionos):
// the app runs on this computer, so its terminal panel is a login shell here, like VS Code's.
// The shells live in a utilityProcess (pty-host.js); the main process brokers create and kill from
// the main window's top frame, and each pty's I/O runs on its own port, frame to host (ADR 0039).
// Nothing from page content chooses the shell, its argv, cwd or env.
const { HARDENED_EDITIONS } = require("./desktop-guards");

const PTY_LIMITS = Object.freeze({
  maxPerWindow: 8,
  maxWrite: 65536,
  maxSize: 1000,
  // Caveat: watermarks count UTF-16 chars, not bytes or render time — a burst of wide
  // characters renders slower than its count suggests; xterm still keeps up at these sizes.
  highWatermark: 100000,
  lowWatermark: 5000,
});

function ptyEnabledFor(edition) {
  return HARDENED_EDITIONS.has(edition);
}

// A shell started from the app must not inherit the app's runtime: ELECTRON_RUN_AS_NODE would turn
// a child `electron` into node, NODE_OPTIONS preloads code, and an AppImage's library path shadows
// the system's.
function cleanShellEnv(env) {
  const insideAppImage = Boolean(env.APPDIR || env.APPIMAGE);
  const clean = {};
  for (const [key, value] of Object.entries(env)) {
    if (/^ELECTRON_/.test(key) || key === "NODE_OPTIONS" || key === "APPDIR" || key === "APPIMAGE") continue;
    if (key === "LD_LIBRARY_PATH" && insideAppImage) continue;
    clean[key] = value;
  }
  return { ...clean, TERM: "xterm-256color", COLORTERM: "truecolor", TERM_PROGRAM: "osionos" };
}

// The shell the person's own terminal app would start: the account's, bare on Linux (Ptyxis runs
// it with no argument; a custom shell may not know -l), a login shell on macOS.
function shellCommand({ accountShell, envShell, platform }) {
  const shell = accountShell || envShell || "/bin/sh";
  return { shell, args: platform === "darwin" ? ["-l"] : [] };
}

const isSize = (n) => Number.isInteger(n) && n >= 1 && n <= PTY_LIMITS.maxSize;

// What the terminal frame may send on its pty's port (ADR 0039, T2). The port is bound to one pty,
// so a message that names an id, or carries any op but these three, is not for this pty.
function portCommand(message) {
  if (message === null || typeof message !== "object" || Array.isArray(message) || "id" in message) return null;
  if (message.op === "write") return typeof message.data === "string" && message.data.length <= PTY_LIMITS.maxWrite ? message : null;
  if (message.op === "resize") return isSize(message.cols) && isSize(message.rows) ? message : null;
  if (message.op === "ack") return Number.isSafeInteger(message.chars) && message.chars > 0 ? message : null;
  return null;
}

const closeQuietly = (port) => { try { port.close(); } catch { /* already closed */ } };

// Runs inside the pty host: one pty bound to one port, in its own closure. The port's holder gets
// this shell's I/O and nothing else; the pty's exit closes the port, the port's close kills the pty,
// and every exit still reaches main through report() so its slot is freed.
function bindPtyPort({ pty, port, report }) {
  let open = true;
  let exited = false;
  let unacked = 0;
  let paused = false;
  const send = (message) => { try { port.postMessage(message); } catch { /* the frame is gone; close follows */ } };

  function kill() {
    if (!open) return;
    open = false;
    closeQuietly(port);
    try { pty.kill(); } catch { /* the pty already exited */ }
  }
  function apply(command) {
    if (command.op === "write") pty.write(command.data);
    else if (command.op === "resize") pty.resize(command.cols, command.rows);
    else {
      unacked = Math.max(0, unacked - command.chars);
      if (paused && unacked < PTY_LIMITS.lowWatermark) { paused = false; pty.resume(); }
    }
  }

  port.on("message", (event) => {
    for (const smuggled of event.ports || []) closeQuietly(smuggled);
    const command = open ? portCommand(event.data) : null;
    if (!command) return;
    try { apply(command); } catch (err) { console.error("[pty-host] dropped a", command.op, "the pty refused:", err && err.message); }
  });
  port.on("close", kill);
  pty.onData((data) => {
    if (!open) return;
    unacked += data.length;
    if (!paused && unacked > PTY_LIMITS.highWatermark) { paused = true; pty.pause(); }
    send({ op: "data", data });
  });
  pty.onExit(({ exitCode }) => {
    if (exited) return;
    exited = true;
    if (open) {
      open = false;
      send({ op: "exit", exitCode });
      closeQuietly(port);
    }
    report(exitCode);
  });
  port.start();
  return { kill };
}

// Runs inside the pty host. main's channel carries create (with the pty's port) and kill only;
// keystrokes, resizes and acks arrive on each pty's own port.
function createPtySessions({ spawn, post, env, home, shell, args }) {
  const live = new Map();

  function create({ id, cols, rows }, port) {
    const report = (exitCode) => { live.delete(id); post({ op: "exit", id, exitCode }); };
    let pty;
    try {
      pty = spawn(shell, args, { name: "xterm-256color", cols, rows, cwd: home, env: cleanShellEnv(env) });
    } catch {
      try { port.postMessage({ op: "exit", exitCode: -1 }); } catch { /* the frame is gone */ }
      closeQuietly(port);
      report(-1);
      return;
    }
    live.set(id, bindPtyPort({ pty, port, report }));
  }

  function handle(message, ports = []) {
    if (message.op === "create") {
      if (ports.length === 1) return create(message, ports[0]);
      for (const port of ports) closeQuietly(port);
      return post({ op: "exit", id: message.id, exitCode: -1 });
    }
    if (message.op === "kill" && live.has(message.id)) live.get(message.id).kill();
  }

  return { handle };
}

// Runs in the main process. Every call carries the IPC event; a sender that is not the main
// window's top frame on app://osionos, or a page that does not own the pty, changes nothing.
// Each pty gets a channel: one end to the host bound to that pty, the other to the creating window.
function createPtyBroker({ senderAllowed, mainContents, startHost, randomId, createChannel }) {
  const owners = new Map();
  let host = null;

  const toHost = (message, ports) => {
    host = host || startHost();
    host.post(message, ports);
  };
  const countFor = (contents) => [...owners.values()].filter((owner) => owner === contents).length;

  function create(event, cols, rows) {
    if (!senderAllowed(event, mainContents())) return null;
    if (!isSize(cols) || !isSize(rows)) return null;
    if (countFor(event.sender) >= PTY_LIMITS.maxPerWindow) return null;
    const id = randomId();
    const { port1, port2 } = createChannel();
    owners.set(id, event.sender);
    toHost({ op: "create", id, cols, rows }, [port1]);
    event.sender.postMessage("pty:port", { id }, [port2]);
    return id;
  }

  function kill(event, id) {
    if (!senderAllowed(event, mainContents()) || owners.get(id) !== event.sender) return;
    owners.delete(id);
    toHost({ op: "kill", id });
  }

  function send(owner, ...args) {
    if (!owner.isDestroyed()) owner.send(...args);
  }

  function onHostMessage(message) {
    const owner = owners.get(message.id);
    if (!owner || message.op !== "exit") return;
    owners.delete(message.id);
    send(owner, "pty:exit", message.id, message.exitCode);
  }

  // The host died (crash or kill): its shells went with it.
  function onHostExit() {
    host = null;
    for (const [id, owner] of owners) send(owner, "pty:exit", id, -1);
    owners.clear();
  }

  // A reload, a renderer crash or a closed window: the page that owned these shells is gone.
  function killOwnedBy(contentsId) {
    for (const [id, owner] of [...owners]) {
      if (owner.id !== contentsId) continue;
      owners.delete(id);
      if (host) host.post({ op: "kill", id });
    }
  }

  return { create, kill, onHostMessage, onHostExit, killOwnedBy };
}

module.exports = { PTY_LIMITS, ptyEnabledFor, cleanShellEnv, shellCommand, bindPtyPort, createPtySessions, createPtyBroker };
