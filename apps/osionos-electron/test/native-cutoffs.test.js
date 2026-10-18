"use strict";
// P9: the native edition applies models/auth-session-cutoffs.sql after gotrue created
// auth.users, because the bridge answers 503 until it can read that table.
// No supervisor smoke run here (test/smoke SKIPs the native edition); this proves the
// applied SQL and the call order in supervisor.mjs.
const { describe, it, before, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const NATIVE = path.join(__dirname, "..", "native");
const MODELS = path.join(__dirname, "..", "..", "..", "models");
const CUTOFFS_FILE = "auth-session-cutoffs.sql";

describe("applyAuthSessionCutoffs", () => {
  let dir;
  let applyAuthSessionCutoffs;

  before(async () => {
    // WHY: firstrun.mjs imports `pg`, which only exists in native-runtime. A copy of the real
    // file beside a recording stub pg exercises the real code without installing the driver.
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "native-cutoffs-"));
    fs.mkdirSync(path.join(dir, "native"));
    fs.mkdirSync(path.join(dir, "node_modules", "pg"), { recursive: true });
    fs.copyFileSync(path.join(NATIVE, "firstrun.mjs"), path.join(dir, "native", "firstrun.mjs"));
    fs.writeFileSync(path.join(dir, "node_modules", "pg", "package.json"), '{"name":"pg","main":"index.js"}');
    fs.writeFileSync(
      path.join(dir, "node_modules", "pg", "index.js"),
      `const log = (globalThis.__pgLog = globalThis.__pgLog || []);
       class Client {
         async connect() { log.push("connect"); }
         async query(sql) { log.push(["query", sql]); }
         async end() { log.push("end"); }
       }
       module.exports = { Client };
       module.exports.default = module.exports;`,
    );
    ({ applyAuthSessionCutoffs } = await import(path.join(dir, "native", "firstrun.mjs")));
  });

  after(() => fs.rmSync(dir, { recursive: true, force: true }));

  it("connects, runs the models file verbatim once, then closes", async () => {
    globalThis.__pgLog.length = 0;
    await applyAuthSessionCutoffs({ host: "h", port: 1, db: "d", superUser: "u", superPass: "p", migrationsDir: MODELS });
    const sql = fs.readFileSync(path.join(MODELS, CUTOFFS_FILE), "utf8");
    assert.deepEqual(globalThis.__pgLog, ["connect", ["query", sql], "end"]);
  });

  it("closes the connection when the file is missing, and rejects", async () => {
    globalThis.__pgLog.length = 0;
    await assert.rejects(applyAuthSessionCutoffs({ host: "h", port: 1, db: "d", superUser: "u", superPass: "p", migrationsDir: dir }), /ENOENT/);
    assert.deepEqual(globalThis.__pgLog, ["connect", "end"]);
  });
});

describe("supervisor wiring", () => {
  const supervisor = fs.readFileSync(path.join(NATIVE, "supervisor.mjs"), "utf8");

  it("applies the cutoffs after gotrue is healthy and before postgrest starts", () => {
    const gotrueReady = supervisor.indexOf('waitUntil("gotrue"');
    const apply = supervisor.indexOf("await applyAuthSessionCutoffs(");
    const postgrest = supervisor.indexOf("const rest = spawn(");
    assert.ok(gotrueReady > 0 && apply > gotrueReady && postgrest > apply, `order ${gotrueReady} < ${apply} < ${postgrest}`);
  });

  it("ships the models file in the native bundle", () => {
    assert.ok(fs.existsSync(path.join(MODELS, CUTOFFS_FILE)));
    assert.match(fs.readFileSync(path.join(__dirname, "..", "build-native.sh"), "utf8"), /cp models\/\*\.sql/);
  });
});
