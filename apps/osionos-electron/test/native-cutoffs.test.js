"use strict";
// P9/P0-4: the native edition applies the session cutoffs and the account foundation
// after gotrue created auth.users, because the bridge answers 503 until it can read
// both public.auth_session_cutoffs and public.osionos_sessions.
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
const FOUNDATION_FILE = "osionos-account-foundation-migration.sql";

describe("applyPostGoTrueMigrations", () => {
  let dir;
  let applyPostGoTrueMigrations;

  before(async () => {
    // WHY: firstrun.mjs imports `pg`, which only exists in native-runtime. A copy of the real
    // file beside a recording stub pg exercises the real code without installing the driver.
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "native-post-gotrue-"));
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
    ({ applyPostGoTrueMigrations } = await import(path.join(dir, "native", "firstrun.mjs")));
  });

  after(() => fs.rmSync(dir, { recursive: true, force: true }));

  it("connects, applies the cutoffs then the foundation verbatim, then closes", async () => {
    globalThis.__pgLog.length = 0;
    await applyPostGoTrueMigrations({ host: "h", port: 1, db: "d", superUser: "u", superPass: "p", migrationsDir: MODELS });
    const cutoffs = fs.readFileSync(path.join(MODELS, CUTOFFS_FILE), "utf8");
    const foundation = fs.readFileSync(path.join(MODELS, FOUNDATION_FILE), "utf8");
    assert.deepEqual(globalThis.__pgLog, ["connect", ["query", cutoffs], ["query", foundation], "end"]);
  });

  it("closes the connection when the cutoffs file is missing, and rejects", async () => {
    globalThis.__pgLog.length = 0;
    await assert.rejects(applyPostGoTrueMigrations({ host: "h", port: 1, db: "d", superUser: "u", superPass: "p", migrationsDir: dir }), /ENOENT/);
    assert.deepEqual(globalThis.__pgLog, ["connect", "end"]);
  });

  it("closes the connection when the foundation file is missing, after the cutoffs", async () => {
    const cutoffsOnly = path.join(dir, "cutoffs-only");
    fs.mkdirSync(cutoffsOnly, { recursive: true });
    fs.copyFileSync(path.join(MODELS, CUTOFFS_FILE), path.join(cutoffsOnly, CUTOFFS_FILE));
    globalThis.__pgLog.length = 0;
    await assert.rejects(applyPostGoTrueMigrations({ host: "h", port: 1, db: "d", superUser: "u", superPass: "p", migrationsDir: cutoffsOnly }), /ENOENT/);
    assert.deepEqual(globalThis.__pgLog, ["connect", ["query", fs.readFileSync(path.join(MODELS, CUTOFFS_FILE), "utf8")], "end"]);
  });
});

describe("supervisor wiring", () => {
  const supervisor = fs.readFileSync(path.join(NATIVE, "supervisor.mjs"), "utf8");

  it("applies the post-GoTrue migrations after gotrue is healthy and before postgrest starts", () => {
    const gotrueReady = supervisor.indexOf('waitUntil("gotrue"');
    const apply = supervisor.indexOf("await applyPostGoTrueMigrations(");
    const postgrest = supervisor.indexOf("const rest = spawn(");
    assert.ok(gotrueReady > 0 && apply > gotrueReady && postgrest > apply, `order ${gotrueReady} < ${apply} < ${postgrest}`);
  });

  it("no longer calls a cutoffs-only step", () => {
    assert.ok(!supervisor.includes("applyAuthSessionCutoffs"));
  });

  it("ships both models files in the native bundle", () => {
    assert.ok(fs.existsSync(path.join(MODELS, CUTOFFS_FILE)));
    assert.ok(fs.existsSync(path.join(MODELS, FOUNDATION_FILE)));
    assert.match(fs.readFileSync(path.join(__dirname, "..", "build-native.sh"), "utf8"), /cp models\/\*\.sql/);
  });
});
