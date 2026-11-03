// ADR 0039, T2: the pty host takes untrusted input straight from the terminal frame on a port bound
// to one pty. Only write, resize and ack get through, nothing after the exit, and the port and the
// pty end together.
const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const { bindPtyPort, PTY_LIMITS } = require("../desktop-pty");

function fakePty() {
  const calls = [];
  return {
    calls,
    write(d) { calls.push(["write", d]); }, resize(c, r) { calls.push(["resize", c, r]); },
    pause() { calls.push(["pause"]); }, resume() { calls.push(["resume"]); }, kill() { calls.push(["kill"]); },
    onData(cb) { this.emit = cb; }, onExit(cb) { this.exit = cb; },
  };
}

function fakePort() {
  const handlers = {};
  return {
    sent: [], closes: 0,
    on(name, cb) { handlers[name] = cb; },
    start() {},
    postMessage(m) { this.sent.push(m); },
    close() { this.closes++; },
    deliver(data, ports = []) { handlers.message({ data, ports }); },
    remoteClose() { handlers.close(); },
  };
}

function bound() {
  const pty = fakePty();
  const port = fakePort();
  const reports = [];
  const handle = bindPtyPort({ pty, port, report: (code) => reports.push(code) });
  return { pty, port, reports, handle };
}

describe("bindPtyPort — what a frame may send (T2)", () => {
  const malformed = [
    ["a string", "ls\r"], ["a number", 42], ["null", null], ["an array", [{ op: "write", data: "x" }]],
    ["no op", { data: "x" }],
    ["a non-string write", { op: "write", data: 42 }],
    ["65537 chars", { op: "write", data: "x".repeat(PTY_LIMITS.maxWrite + 1) }],
    ["cols 0", { op: "resize", cols: 0, rows: 24 }], ["cols 1001", { op: "resize", cols: 1001, rows: 24 }],
    ["cols 1.5", { op: "resize", cols: 1.5, rows: 24 }], ["cols NaN", { op: "resize", cols: NaN, rows: 24 }],
    ["cols \"80\"", { op: "resize", cols: "80", rows: 24 }], ["rows missing", { op: "resize", cols: 80 }],
    ["ack 0", { op: "ack", chars: 0 }], ["ack -1", { op: "ack", chars: -1 }], ["ack 1.5", { op: "ack", chars: 1.5 }],
    ["ack 2^53", { op: "ack", chars: 2 ** 53 }],
    ["create", { op: "create", cols: 80, rows: 24 }], ["kill", { op: "kill" }],
    ["a write naming another pty", { op: "write", id: "other", data: "x" }],
    ["a resize naming another pty", { op: "resize", id: "other", cols: 80, rows: 24 }],
  ];
  for (const [name, message] of malformed) {
    it(`${name} makes 0 pty calls`, () => {
      const { pty, port } = bound();
      port.deliver(message);
      assert.deepEqual(pty.calls, []);
    });
  }
  it("65536 chars, a 1..1000 resize and a positive ack pass", () => {
    const { pty, port } = bound();
    port.deliver({ op: "write", data: "x".repeat(PTY_LIMITS.maxWrite) });
    port.deliver({ op: "resize", cols: 1, rows: 1000 });
    port.deliver({ op: "ack", chars: 1 });
    assert.deepEqual(pty.calls.map((c) => c[0]), ["write", "resize"]);
    assert.equal(pty.calls[0][1].length, PTY_LIMITS.maxWrite);
  });
  it("closes every port transferred on it, whatever the message", () => {
    const { pty, port } = bound();
    const smuggled = [fakePort(), fakePort()];
    port.deliver({ op: "write", data: "x" }, smuggled);
    port.deliver({ op: "create" }, [smuggled[0]]);
    assert.deepEqual(smuggled.map((p) => p.closes), [2, 1]);
    assert.deepEqual(pty.calls, [["write", "x"]]);
  });
  it("a pty call that throws does not escape the handler", () => {
    const { pty, port } = bound();
    pty.write = () => { throw new Error("EIO"); };
    assert.doesNotThrow(() => port.deliver({ op: "write", data: "x" }));
  });
});

describe("bindPtyPort — the port and the pty end together (T2)", () => {
  it("output goes on the port with no id", () => {
    const { pty, port } = bound();
    pty.emit("hi");
    assert.deepEqual(port.sent, [{ op: "data", data: "hi" }]);
  });
  it("exit: 1 exit message, 1 port close, 1 report; later input and output are dropped", () => {
    const { pty, port, reports } = bound();
    pty.exit({ exitCode: 3 });
    port.remoteClose();
    for (let i = 0; i < 100; i++) port.deliver({ op: "write", data: "late" });
    port.deliver({ op: "resize", cols: 90, rows: 30 });
    pty.emit("after");
    pty.exit({ exitCode: 3 });
    assert.deepEqual(port.sent, [{ op: "exit", exitCode: 3 }]);
    assert.equal(port.closes, 1);
    assert.deepEqual(reports, [3]);
    assert.deepEqual(pty.calls, []);
  });
  it("port close: exactly 1 kill, and the exit that follows is still reported", () => {
    const { pty, port, reports } = bound();
    port.remoteClose();
    port.remoteClose();
    port.deliver({ op: "write", data: "late" });
    assert.deepEqual(pty.calls, [["kill"]]);
    pty.exit({ exitCode: 0 });
    assert.deepEqual(reports, [0]);
  });
  it("kill from main closes the port once and kills once", () => {
    const { pty, port, handle } = bound();
    handle.kill();
    handle.kill();
    port.remoteClose();
    assert.equal(port.closes, 1);
    assert.deepEqual(pty.calls, [["kill"]]);
  });
  it("a kill that throws (the pty already gone) does not escape", () => {
    const { pty, handle } = bound();
    pty.kill = () => { throw new Error("ESRCH"); };
    assert.doesNotThrow(() => handle.kill());
  });
});
