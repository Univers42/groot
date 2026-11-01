// The desktop's local terminal (devil verdict 2026-10-31): the shell runs only in the hardened
// edition, only the main window's top frame drives it, each pty belongs to the page that made it,
// output is flow-controlled, and a reload, crash or close leaves no shell behind.
const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const { ptyEnabledFor, cleanShellEnv, shellCommand, createPtySessions, createPtyBroker, PTY_LIMITS } = require("../desktop-pty");

describe("ptyEnabledFor (C2)", () => {
  it("only the hardened FULL edition has a local shell", () => {
    assert.equal(ptyEnabledFor("full"), true);
    assert.equal(ptyEnabledFor("local"), false);
    assert.equal(ptyEnabledFor("native"), false);
    assert.equal(ptyEnabledFor(undefined), false);
  });
});

describe("cleanShellEnv (C8)", () => {
  it("drops Electron, Node and AppImage variables and names the terminal", () => {
    const env = cleanShellEnv({
      HOME: "/home/me", PATH: "/usr/bin", ELECTRON_RUN_AS_NODE: "1", ELECTRON_NO_ATTACH_CONSOLE: "1",
      NODE_OPTIONS: "--require /tmp/x.js", APPDIR: "/tmp/.mount_x", APPIMAGE: "/a.AppImage", LD_LIBRARY_PATH: "/tmp/.mount_x/usr/lib",
    });
    assert.deepEqual(Object.keys(env).filter((k) => /^ELECTRON_|^NODE_OPTIONS$|^APPDIR$|^APPIMAGE$|^LD_LIBRARY_PATH$/.test(k)), []);
    assert.equal(env.HOME, "/home/me");
    assert.equal(env.PATH, "/usr/bin");
    assert.equal(env.TERM, "xterm-256color");
  });
  it("keeps the person's own LD_LIBRARY_PATH outside an AppImage", () => {
    assert.equal(cleanShellEnv({ LD_LIBRARY_PATH: "/opt/lib" }).LD_LIBRARY_PATH, "/opt/lib");
  });
});

function fakeSpawn() {
  const spawned = [];
  const spawn = (file, args, opts) => {
    const p = {
      file, args, opts, written: [], size: [opts.cols, opts.rows], paused: false, killed: false,
      write(d) { this.written.push(d); }, resize(c, r) { this.size = [c, r]; },
      pause() { this.paused = true; }, resume() { this.paused = false; }, kill() { this.killed = true; },
      onData(cb) { this.emit = cb; }, onExit(cb) { this.exit = cb; },
    };
    spawned.push(p);
    return p;
  };
  return { spawn, spawned };
}

describe("shellCommand", () => {
  // What the person's own terminal app runs: the account's shell, bare on Linux (Ptyxis runs
  // /usr/bin/hellish with no argument), a login shell on macOS as Terminal.app and VS Code do.
  it("prefers the account's shell, then $SHELL, then /bin/sh", () => {
    assert.deepEqual(shellCommand({ accountShell: "/usr/bin/hellish", envShell: "/bin/bash", platform: "linux" }), { shell: "/usr/bin/hellish", args: [] });
    assert.deepEqual(shellCommand({ accountShell: "", envShell: "/bin/bash", platform: "linux" }), { shell: "/bin/bash", args: [] });
    assert.deepEqual(shellCommand({ accountShell: null, envShell: undefined, platform: "linux" }), { shell: "/bin/sh", args: [] });
    assert.deepEqual(shellCommand({ accountShell: "/bin/zsh", envShell: "", platform: "darwin" }), { shell: "/bin/zsh", args: ["-l"] });
  });
});

function fakePort() {
  const handlers = {};
  return {
    sent: [], closes: 0, started: false,
    on(name, cb) { handlers[name] = cb; },
    start() { this.started = true; },
    postMessage(m) { this.sent.push(m); },
    close() { this.closes++; },
    deliver(data, ports = []) { handlers.message({ data, ports }); },
    remoteClose() { handlers.close(); },
  };
}

describe("createPtySessions — the host (C7, ADR 0039)", () => {
  const make = () => {
    const { spawn, spawned } = fakeSpawn();
    const posted = [];
    const sessions = createPtySessions({ spawn, post: (m) => posted.push(m), env: { HOME: "/home/me", ELECTRON_X: "1" }, home: "/home/me", shell: "/usr/bin/hellish", args: [] });
    const port = fakePort();
    return { sessions, spawned, posted, port };
  };
  it("spawns the person's shell with the host's arguments, in the home folder, at the asked size, with a clean env", () => {
    const { sessions, spawned, port } = make();
    sessions.handle({ op: "create", id: "a", cols: 100, rows: 30 }, [port]);
    assert.equal(spawned[0].file, "/usr/bin/hellish");
    assert.deepEqual(spawned[0].args, []);
    assert.equal(spawned[0].opts.cwd, "/home/me");
    assert.deepEqual(spawned[0].size, [100, 30]);
    assert.equal(spawned[0].opts.env.ELECTRON_X, undefined);
    assert.equal(port.started, true);
  });
  it("output goes on the port, never to main; it pauses past the high watermark and resumes on a port ack", () => {
    const { sessions, spawned, posted, port } = make();
    sessions.handle({ op: "create", id: "a", cols: 80, rows: 24 }, [port]);
    const p = spawned[0];
    p.emit("x".repeat(PTY_LIMITS.highWatermark + 1));
    assert.equal(p.paused, true);
    assert.equal(port.sent.at(-1).op, "data");
    assert.equal("id" in port.sent.at(-1), false);
    assert.deepEqual(posted, []);
    port.deliver({ op: "ack", chars: PTY_LIMITS.highWatermark + 1 - PTY_LIMITS.lowWatermark + 1 });
    assert.equal(p.paused, false);
  });
  it("forwards port writes and resizes; main's kill closes the port and the exit reaches main once", () => {
    const { sessions, spawned, posted, port } = make();
    sessions.handle({ op: "create", id: "a", cols: 80, rows: 24 }, [port]);
    port.deliver({ op: "write", data: "ls\r" });
    port.deliver({ op: "resize", cols: 120, rows: 40 });
    assert.deepEqual(spawned[0].written, ["ls\r"]);
    assert.deepEqual(spawned[0].size, [120, 40]);
    sessions.handle({ op: "kill", id: "a" });
    assert.equal(spawned[0].killed, true);
    assert.equal(port.closes, 1);
    port.deliver({ op: "write", data: "late" });
    spawned[0].exit({ exitCode: 0 });
    assert.deepEqual(posted, [{ op: "exit", id: "a", exitCode: 0 }]);
    assert.deepEqual(spawned[0].written, ["ls\r"]);
    assert.equal(port.closes, 1);
  });
  it("main's channel carries create and kill only: write, resize and ack from main do nothing", () => {
    const { sessions, spawned, port } = make();
    sessions.handle({ op: "create", id: "a", cols: 80, rows: 24 }, [port]);
    sessions.handle({ op: "write", id: "a", data: "x" });
    sessions.handle({ op: "resize", id: "a", cols: 90, rows: 30 });
    assert.deepEqual(spawned[0].written, []);
    assert.deepEqual(spawned[0].size, [80, 24]);
  });
  it("a create without exactly one port spawns nothing and frees the slot", () => {
    const { sessions, spawned, posted } = make();
    sessions.handle({ op: "create", id: "a", cols: 80, rows: 24 });
    sessions.handle({ op: "create", id: "b", cols: 80, rows: 24 }, [fakePort(), fakePort()]);
    assert.equal(spawned.length, 0);
    assert.deepEqual(posted, [{ op: "exit", id: "a", exitCode: -1 }, { op: "exit", id: "b", exitCode: -1 }]);
  });
  it("a failed spawn reports an exit to main and on the port instead of throwing", () => {
    const posted = [];
    const port = fakePort();
    const sessions = createPtySessions({ spawn: () => { throw new Error("no shell"); }, post: (m) => posted.push(m), env: {}, home: "/", shell: "/nope", args: [] });
    sessions.handle({ op: "create", id: "a", cols: 80, rows: 24 }, [port]);
    assert.deepEqual(posted, [{ op: "exit", id: "a", exitCode: -1 }]);
    assert.deepEqual(port.sent, [{ op: "exit", exitCode: -1 }]);
    assert.equal(port.closes, 1);
  });
});

function fakeWorld({ allowed = true } = {}) {
  const sent = [];
  const hostMsgs = [];
  const hostPorts = [];
  const pagePorts = [];
  let starts = 0;
  const main = { id: 1, isDestroyed: () => false, send: (...a) => sent.push(a), postMessage: (ch, m, ports) => pagePorts.push([ch, m, ports]) };
  const broker = createPtyBroker({
    senderAllowed: (event) => allowed && event.sender === main,
    mainContents: () => main,
    startHost: () => { starts++; return { post: (m, ports) => { hostMsgs.push(m); hostPorts.push(ports); } }; },
    randomId: (() => { let n = 0; return () => `p${++n}`; })(),
    createChannel: (() => { let n = 0; return () => { n++; return { port1: `host-end-${n}`, port2: `page-end-${n}` }; }; })(),
  });
  const ev = (sender = main) => ({ sender });
  return { broker, main, sent, hostMsgs, hostPorts, pagePorts, ev, starts: () => starts };
}

describe("createPtyBroker — the main process (C5, C6, ADR 0039)", () => {
  it("has no write, resize or ack: keystrokes travel on the pty's port only", () => {
    const { broker } = fakeWorld();
    for (const name of ["write", "resize", "ack"]) assert.equal(broker[name], undefined, name);
  });
  it("a refused sender never reaches the host and gets no port", () => {
    const w = fakeWorld({ allowed: false });
    assert.equal(w.broker.create(w.ev(), 80, 24), null);
    assert.equal(w.starts(), 0);
    assert.deepEqual(w.hostMsgs, []);
    assert.deepEqual(w.pagePorts, []);
  });
  it("creates at a validated size, binds one channel end to the host's pty and posts the other to the page", () => {
    const w = fakeWorld();
    for (const [c, r] of [[0, 24], [80, 1001], [80.5, 24], ["80", 24], [NaN, 24]]) assert.equal(w.broker.create(w.ev(), c, r), null, `${c}x${r}`);
    assert.deepEqual(w.pagePorts, []);
    const id = w.broker.create(w.ev(), 80, 24);
    assert.equal(id, "p1");
    assert.deepEqual(w.hostMsgs.at(-1), { op: "create", id: "p1", cols: 80, rows: 24 });
    assert.deepEqual(w.hostPorts.at(-1), ["host-end-1"]);
    assert.deepEqual(w.pagePorts, [["pty:port", { id: "p1" }, ["page-end-1"]]]);
  });
  it("a pty id is bound to the page that created it", () => {
    const w = fakeWorld();
    const id = w.broker.create(w.ev(), 80, 24);
    w.broker.kill(w.ev(), "p999");
    w.broker.kill(w.ev({ id: 2, isDestroyed: () => false, send() {} }), id);
    assert.equal(w.hostMsgs.length, 1);
    w.broker.kill(w.ev(), id);
    assert.deepEqual(w.hostMsgs.at(-1), { op: "kill", id });
  });
  it("refuses a ninth concurrent shell per window", () => {
    const w = fakeWorld();
    for (let i = 0; i < PTY_LIMITS.maxPerWindow; i++) assert.notEqual(w.broker.create(w.ev(), 80, 24), null);
    assert.equal(w.broker.create(w.ev(), 80, 24), null);
  });
  it("create 8, exit 8: every exit frees its slot and reaches the page, and a 9th create succeeds", () => {
    const w = fakeWorld();
    const ids = [];
    for (let i = 0; i < PTY_LIMITS.maxPerWindow; i++) ids.push(w.broker.create(w.ev(), 80, 24));
    for (const id of ids) w.broker.onHostMessage({ op: "exit", id, exitCode: 0 });
    assert.deepEqual(w.sent, ids.map((id) => ["pty:exit", id, 0]));
    assert.notEqual(w.broker.create(w.ev(), 80, 24), null);
  });
  it("ignores host messages other than an exit of a pty it owns", () => {
    const w = fakeWorld();
    const id = w.broker.create(w.ev(), 80, 24);
    w.broker.onHostMessage({ op: "data", id, data: "hello" });
    w.broker.onHostMessage({ op: "exit", id: "p999", exitCode: 0 });
    assert.deepEqual(w.sent, []);
  });
  it("a reload, crash or close kills every shell the page owned", () => {
    const w = fakeWorld();
    w.broker.create(w.ev(), 80, 24);
    w.broker.create(w.ev(), 80, 24);
    w.broker.killOwnedBy(w.main.id);
    assert.deepEqual(w.hostMsgs.filter((m) => m.op === "kill").map((m) => m.id), ["p1", "p2"]);
    assert.notEqual(w.broker.create(w.ev(), 80, 24), null, "the slots are free again");
  });
  it("a dead host ends its shells for the page and the next create starts a new one", () => {
    const w = fakeWorld();
    const id = w.broker.create(w.ev(), 80, 24);
    w.broker.onHostExit();
    assert.deepEqual(w.sent.at(-1), ["pty:exit", id, -1]);
    w.broker.create(w.ev(), 80, 24);
    assert.equal(w.starts(), 2);
  });
});
