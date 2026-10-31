// The desktop's local terminal (devil verdict 2026-10-31, docs/ide/vscode-backend in osionos):
// the app runs on this computer, so its terminal panel is a login shell here, like VS Code's.
// The shells live in a utilityProcess (pty-host.js); the main process only brokers IPC from the
// main window's top frame. Nothing from page content chooses the shell, its argv, cwd or env.
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

// Runs inside the pty host: one entry per shell, output paused while the page is behind.
function createPtySessions({ spawn, post, env, home, shell, args }) {
  const live = new Map();

  function create({ id, cols, rows }) {
    let pty;
    try {
      pty = spawn(shell, args, { name: "xterm-256color", cols, rows, cwd: home, env: cleanShellEnv(env) });
    } catch {
      post({ op: "exit", id, exitCode: -1 });
      return;
    }
    const entry = { pty, unacked: 0, paused: false };
    live.set(id, entry);
    pty.onData((data) => {
      entry.unacked += data.length;
      if (!entry.paused && entry.unacked > PTY_LIMITS.highWatermark) { entry.paused = true; pty.pause(); }
      post({ op: "data", id, data });
    });
    pty.onExit(({ exitCode }) => {
      if (!live.has(id)) return;
      live.delete(id);
      post({ op: "exit", id, exitCode });
    });
  }

  function ack(entry, chars) {
    entry.unacked = Math.max(0, entry.unacked - chars);
    if (entry.paused && entry.unacked < PTY_LIMITS.lowWatermark) { entry.paused = false; entry.pty.resume(); }
  }

  function handle(message) {
    if (message.op === "create") return create(message);
    const entry = live.get(message.id);
    if (!entry) return;
    if (message.op === "write") entry.pty.write(message.data);
    else if (message.op === "resize") entry.pty.resize(message.cols, message.rows);
    else if (message.op === "ack") ack(entry, message.chars);
    else if (message.op === "kill") entry.pty.kill();
  }

  return { handle };
}

const isSize = (n) => Number.isInteger(n) && n >= 1 && n <= PTY_LIMITS.maxSize;

// Runs in the main process. Every call carries the IPC event; a sender that is not the main
// window's top frame on app://osionos, or a page that does not own the pty, changes nothing.
function createPtyBroker({ senderAllowed, mainContents, startHost, randomId }) {
  const owners = new Map();
  let host = null;

  const ownerOf = (event, id) => {
    if (!senderAllowed(event, mainContents())) return null;
    const owner = owners.get(id);
    return owner && owner === event.sender ? owner : null;
  };
  const toHost = (message) => {
    host = host || startHost();
    host.post(message);
  };
  const countFor = (contents) => [...owners.values()].filter((owner) => owner === contents).length;

  function create(event, cols, rows) {
    if (!senderAllowed(event, mainContents())) return null;
    if (!isSize(cols) || !isSize(rows)) return null;
    if (countFor(event.sender) >= PTY_LIMITS.maxPerWindow) return null;
    const id = randomId();
    owners.set(id, event.sender);
    toHost({ op: "create", id, cols, rows });
    return id;
  }

  function write(event, id, data) {
    if (!ownerOf(event, id) || typeof data !== "string" || data.length > PTY_LIMITS.maxWrite) return;
    toHost({ op: "write", id, data });
  }

  function resize(event, id, cols, rows) {
    if (!ownerOf(event, id) || !isSize(cols) || !isSize(rows)) return;
    toHost({ op: "resize", id, cols, rows });
  }

  function ack(event, id, chars) {
    if (!ownerOf(event, id) || !Number.isInteger(chars) || chars < 0) return;
    toHost({ op: "ack", id, chars });
  }

  function kill(event, id) {
    if (!ownerOf(event, id)) return;
    owners.delete(id);
    toHost({ op: "kill", id });
  }

  function send(owner, ...args) {
    if (!owner.isDestroyed()) owner.send(...args);
  }

  function onHostMessage(message) {
    const owner = owners.get(message.id);
    if (!owner) return;
    if (message.op === "data") send(owner, "pty:data", message.id, message.data);
    else if (message.op === "exit") {
      owners.delete(message.id);
      send(owner, "pty:exit", message.id, message.exitCode);
    }
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

  return { create, write, resize, ack, kill, onHostMessage, onHostExit, killOwnedBy };
}

module.exports = { PTY_LIMITS, ptyEnabledFor, cleanShellEnv, shellCommand, createPtySessions, createPtyBroker };
