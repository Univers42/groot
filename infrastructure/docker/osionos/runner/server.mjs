// **************************************************************************** //
//                                                                              //
//                                                         :::      ::::::::    //
//    server.mjs                                         :+:      :+:    :+:    //
//                                                     +:+ +:+         +:+      //
//    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         //
//                                                 +#+#+#+#+#+   +#+            //
//    Created: 2026/07/13 00:00:00 by dlesieur          #+#    #+#              //
//    Updated: 2026/07/13 00:00:00 by dlesieur         ###   ########.fr        //
//                                                                              //
// **************************************************************************** //

// The osionos IDE code runner — a hardened, network-isolated sandbox service.
//
// SECURITY MODEL (the container IS the sandbox — see runner.Dockerfile + the
// compose service): this process runs as a non-root user, in a container with
// `cap_drop: ALL`, `no-new-privileges`, a read-only rootfs, a size-capped tmpfs
// at /work, `pids_limit`/`mem_limit`/`cpus`/`ulimits`, on an `internal` network
// (NO egress — the Docker daemon enforces this without needing unprivileged user
// namespaces, which this host blocks: apparmor_restrict_unprivileged_userns=1).
// Docker's DEFAULT seccomp+apparmor profiles stay ON (they already block ptrace,
// and unshare-of-namespaces needs the dropped CAP_SYS_ADMIN).
//
// This server NEVER executes a client-supplied command. It receives a language
// id + source text, looks up its OWN trusted command for that language, writes
// the source to a per-request tmpfs dir, and runs the fixed command there under
// a hard wall-clock timeout with capped output. It is only reachable from the
// bridge (authenticated broker) over the internal network — never the browser.
//
// ponytail: run-to-completion with optional preset stdin. Interactive live-stdin
// (xterm keystrokes) is deferred — it needs a per-run id + ownership ACL at the
// bridge (a named devil condition), so it lands with that, not before.

import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

const PORT = Number(process.env.RUNNER_PORT || 7900);
const WORK_ROOT = process.env.RUNNER_WORKDIR || "/work";
const MAX_SOURCE_BYTES = 256 * 1024; // matches the bridge agent-route body cap
const MAX_STDIN_BYTES = 64 * 1024;
const MAX_OUTPUT_BYTES = 256 * 1024; // per stream; kill + truncate beyond
const DEFAULT_TIMEOUT_MS = 10_000;
const MAX_TIMEOUT_MS = 30_000;

// Trusted language → { file, cmd }. `cmd` is a FIXED shell line run in the
// per-request workdir; only server-owned paths appear in it, never client input.
// A language whose toolchain isn't installed in the image fails cleanly ("... :
// not found") — add the toolchain to runner.Dockerfile to enable it.
const LANGS = {
  python: { file: "main.py", cmd: "python3 main.py" },
  c: { file: "main.c", cmd: "gcc -O2 -std=c17 -o main main.c && ./main" },
  cpp: { file: "main.cpp", cmd: "g++ -O2 -std=c++20 -o main main.cpp && ./main" },
  java: { file: "Main.java", cmd: "javac Main.java && java Main" },
  javascript: { file: "main.js", cmd: "node main.js" },
  typescript: { file: "main.ts", cmd: "node --experimental-strip-types main.ts" },
  shell: { file: "main.sh", cmd: "bash main.sh" },
  ruby: { file: "main.rb", cmd: "ruby main.rb" },
  php: { file: "main.php", cmd: "php main.php" },
  go: { file: "main.go", cmd: "go run main.go" },
  rust: { file: "main.rs", cmd: "rustc -O -o main main.rs && ./main" },
  lua: { file: "main.lua", cmd: "lua main.lua" },
  perl: { file: "main.pl", cmd: "perl main.pl" },
};

// Trusted formatters: language → [binary, args]. The formatter reads the source
// on STDIN and writes the formatted result to STDOUT (no temp file, no client
// command). A language absent here → 400. Toolchains live in runner.Dockerfile.
const FORMATTERS = {
  python: ["black", ["-q", "-"]],
  c: ["clang-format", ["--assume-filename=main.c"]],
  cpp: ["clang-format", ["--assume-filename=main.cpp"]],
};

/** Minimal env for the child — no host/bridge secrets leak in (there are none in
 *  this container, but keep it hygienic). HOME must be writable → the tmpfs dir. */
function childEnv(workDir) {
  return {
    PATH: process.env.PATH || "/usr/local/bin:/usr/bin:/bin",
    HOME: workDir,
    LANG: "C.UTF-8",
    TMPDIR: workDir,
    GOCACHE: join(workDir, ".gocache"),
    GOFLAGS: "-mod=mod",
  };
}

function sse(res, event, data) {
  res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}

/** Run one request to completion, streaming SSE. Cleans its tmpfs dir on exit. */
function execRun(res, { language, source, stdin, timeoutMs }) {
  const spec = LANGS[language];
  if (!spec) {
    sse(res, "error", { message: `Unsupported language: ${language}` });
    return res.end();
  }
  const limit = Math.min(Math.max(Number(timeoutMs) || DEFAULT_TIMEOUT_MS, 1), MAX_TIMEOUT_MS);
  const workDir = mkdtempSync(join(WORK_ROOT, "run-"));
  writeFileSync(join(workDir, spec.file), source, "utf8");

  const child = spawn("/bin/sh", ["-c", spec.cmd], {
    cwd: workDir,
    env: childEnv(workDir),
    // New process group (detached) so a kill reaps the WHOLE subtree, not just
    // the `sh` parent — compilers, interpreters and their children die together.
    // (Double-forked grandchildren that reparent to init still escape the group;
    // pids_limit is the backstop for those, e.g. a fork bomb.)
    detached: true,
    stdio: [stdin ? "pipe" : "ignore", "pipe", "pipe"],
  });
  const killGroup = (sig) => {
    try { process.kill(-child.pid, sig); } catch { try { child.kill(sig); } catch { /* gone */ } }
  };

  const started = Date.now();
  let timedOut = false;
  const sizes = { stdout: 0, stderr: 0 };
  const pump = (stream, name) => {
    child[stream].on("data", (chunk) => {
      if (sizes[name] >= MAX_OUTPUT_BYTES) return;
      sizes[name] += chunk.length;
      sse(res, name, { chunk: chunk.toString("utf8") });
      if (sizes[name] >= MAX_OUTPUT_BYTES) {
        sse(res, name, { chunk: `\n[output truncated at ${MAX_OUTPUT_BYTES} bytes]\n` });
        killGroup("SIGKILL");
      }
    });
  };
  pump("stdout", "stdout");
  pump("stderr", "stderr");

  const killer = setTimeout(() => { timedOut = true; killGroup("SIGKILL"); }, limit);
  if (stdin) { child.stdin.end(String(stdin).slice(0, MAX_STDIN_BYTES)); }

  child.on("error", (err) => {
    clearTimeout(killer);
    sse(res, "error", { message: err.message });
    cleanup();
    res.end();
  });
  child.on("close", (code, signal) => {
    clearTimeout(killer);
    sse(res, "exit", { code, signal, timedOut, durationMs: Date.now() - started });
    cleanup();
    res.end();
  });

  function cleanup() {
    try { rmSync(workDir, { recursive: true, force: true }); } catch { /* tmpfs */ }
  }
}

/** Format `source` on the formatter's stdin → stdout. JSON in, JSON out (no SSE):
 *  { formatted } on success, { message } + 422 on a syntax error the formatter
 *  rejects. Wall-clock bounded like a run. */
function formatReq(res, { language, source }) {
  const spec = FORMATTERS[language];
  if (!spec) { res.writeHead(400, { "content-type": "application/json" }); return res.end(JSON.stringify({ message: `No formatter for ${language}` })); }
  const child = spawn(spec[0], spec[1], { stdio: ["pipe", "pipe", "pipe"], env: { PATH: process.env.PATH || "/usr/bin:/bin" } });
  let out = "", err = "", outLen = 0;
  const killer = setTimeout(() => child.kill("SIGKILL"), DEFAULT_TIMEOUT_MS);
  child.stdout.on("data", (c) => { if (outLen < MAX_OUTPUT_BYTES) { out += c; outLen += c.length; } });
  child.stderr.on("data", (c) => { if (err.length < 8192) err += c; });
  child.on("error", (e) => { clearTimeout(killer); res.writeHead(500, { "content-type": "application/json" }); res.end(JSON.stringify({ message: `Formatter unavailable: ${e.message}` })); });
  child.on("close", (code) => {
    clearTimeout(killer);
    if (code === 0) { res.writeHead(200, { "content-type": "application/json" }); res.end(JSON.stringify({ formatted: out })); }
    else { res.writeHead(422, { "content-type": "application/json" }); res.end(JSON.stringify({ message: (err || "format failed").slice(0, 4000) })); }
  });
  child.stdin.end(source);
}

function readJsonBody(req, cap, cb) {
  let raw = "", over = false;
  req.on("data", (c) => { raw += c; if (raw.length > cap) { over = true; req.destroy(); } });
  req.on("end", () => {
    if (over) return cb(new Error("body too large"));
    try { cb(null, JSON.parse(raw || "{}")); } catch (e) { cb(e); }
  });
  req.on("error", (e) => cb(e));
}

const server = createServer((req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify({ ok: true, languages: Object.keys(LANGS), formatters: Object.keys(FORMATTERS) }));
  }
  if (req.method === "POST" && req.url === "/exec") {
    return readJsonBody(req, MAX_SOURCE_BYTES + MAX_STDIN_BYTES + 4096, (err, body) => {
      if (err) { res.writeHead(413, { "content-type": "application/json" }); return res.end(JSON.stringify({ error: err.message })); }
      if (typeof body.source !== "string" || body.source.length > MAX_SOURCE_BYTES) {
        res.writeHead(400, { "content-type": "application/json" });
        return res.end(JSON.stringify({ error: "invalid or oversized source" }));
      }
      res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive" });
      execRun(res, body);
    });
  }
  if (req.method === "POST" && req.url === "/format") {
    return readJsonBody(req, MAX_SOURCE_BYTES + 4096, (err, body) => {
      if (err) { res.writeHead(413, { "content-type": "application/json" }); return res.end(JSON.stringify({ message: err.message })); }
      if (typeof body.source !== "string" || body.source.length > MAX_SOURCE_BYTES) {
        res.writeHead(400, { "content-type": "application/json" });
        return res.end(JSON.stringify({ message: "invalid or oversized source" }));
      }
      formatReq(res, body);
    });
  }
  res.writeHead(404, { "content-type": "application/json" });
  res.end(JSON.stringify({ error: "not found" }));
});

server.listen(PORT, () => {
  process.stdout.write(`[osionos-runner] listening on :${PORT} — ${Object.keys(LANGS).length} languages, workdir ${WORK_ROOT}\n`);
});

// Self-check: `node server.mjs --selfcheck` asserts the trusted map is well-formed
// (every cmd references its own file, no shell metachars from client could reach
// the command — the command is a constant). Runs no user code.
if (process.argv.includes("--selfcheck")) {
  const bad = Object.entries(LANGS).filter(([, v]) => !v.file || !v.cmd || !v.cmd.includes(v.file.split(".")[0]));
  if (bad.length) { process.stderr.write(`selfcheck FAIL: ${bad.map((b) => b[0]).join(",")}\n`); process.exit(1); }
  process.stdout.write(`selfcheck OK: ${Object.keys(LANGS).length} languages, all commands reference their own file\n`);
  process.exit(0);
}
