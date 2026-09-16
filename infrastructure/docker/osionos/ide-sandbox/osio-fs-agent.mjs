// **************************************************************************** //
//                                                                              //
//                                                         :::      ::::::::    //
//    osio-fs-agent.mjs                                  :+:      :+:    :+:    //
//                                                     +:+ +:+         +:+      //
//    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         //
//                                                 +#+#+#+#+#+   +#+            //
//    Created: 2026/07/19 00:00:00 by dlesieur          #+#    #+#              //
//    Updated: 2026/07/19 00:00:00 by dlesieur         ###   ########.fr        //
//                                                                              //
// **************************************************************************** //

// The in-sandbox filesystem agent (P4). Watches /workspace and streams
// create/modify/delete events (one JSON line each) for the gateway to map back
// into pages. The load-bearing control is the IGNORE set applied HERE, before an
// event ever leaves the container: without it a single `pip install` / `npm i`
// would turn thousands of dependency files into pages. Node built-ins only.

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const ROOT = process.env.OSIO_FS_ROOT || "/workspace";
const MAX_FILE_BYTES = 512 * 1024;

// Directory names that are never synced to pages (build output, VCS, caches,
// dependency trees). A `.osioignore` in the workspace root adds more.
const DEFAULT_IGNORE_DIRS = new Set([
  ".git", "node_modules", "dist", "build", "target", "__pycache__",
  ".venv", "venv", ".cache", ".next", ".turbo", ".gradle", ".idea",
  ".vscode", ".pnpm-store", "vendor", ".tox", ".mypy_cache", ".pytest_cache",
  ".osio", "coverage", ".nyc_output", "bin", "obj",
]);
const DEFAULT_IGNORE_FILE = /\.(pyc|pyo|class|o|a|so|dylib|dll|exe|bin|lock|log|map|min\.js|min\.css)$/i;
const DEFAULT_IGNORE_BASENAMES = new Set([".DS_Store", "Thumbs.db", "package-lock.json", "pnpm-lock.yaml", "yarn.lock"]);

/** A relative path is ignored when ANY segment is an ignored dir, or the file
 *  matches an ignored basename/extension. Pure — the sync's correctness pivot. */
export function isIgnored(relPath, extraDirs = new Set()) {
  const parts = relPath.split("/").filter(Boolean);
  if (parts.length === 0) return true;
  for (let i = 0; i < parts.length - 1; i++) {
    if (DEFAULT_IGNORE_DIRS.has(parts[i]) || extraDirs.has(parts[i])) return true;
  }
  const base = parts[parts.length - 1];
  if (DEFAULT_IGNORE_DIRS.has(base) || extraDirs.has(base)) return true;
  if (DEFAULT_IGNORE_BASENAMES.has(base)) return true;
  return DEFAULT_IGNORE_FILE.test(base);
}

/** sha256 of file bytes — the gateway compares this to the hash of an
 *  editor-originated write to suppress the echo (no loop back into updateBlock). */
export function hashContent(buffer) {
  return crypto.createHash("sha256").update(buffer).digest("hex").slice(0, 16);
}

function loadExtraIgnore(root) {
  try {
    const raw = fs.readFileSync(path.join(root, ".osioignore"), "utf8");
    return new Set(raw.split("\n").map((l) => l.trim().replace(/\/$/, "")).filter((l) => l && !l.startsWith("#")));
  } catch {
    return new Set();
  }
}

function emit(event, relPath, extra = {}) {
  process.stdout.write(`${JSON.stringify({ event, path: relPath, ...extra })}\n`);
}

/** A file is treated as binary (and NOT synced to a page) if a NUL byte appears
 *  in its leading bytes — pages hold code/text, never binaries. */
export function looksBinary(buffer) {
  const scan = buffer.subarray(0, Math.min(buffer.length, 8000));
  return scan.includes(0);
}

function readMeta(absPath) {
  try {
    const stat = fs.statSync(absPath);
    if (!stat.isFile() || stat.size > MAX_FILE_BYTES) return null;
    const buffer = fs.readFileSync(absPath);
    if (looksBinary(buffer)) return null;
    // Content rides the event (base64) so the writeback needs no read round-trip;
    // hash lets the consumer suppress the echo of its own editor→container write.
    return { hash: hashContent(buffer), content: buffer.toString("base64") };
  } catch {
    return null;
  }
}

// Hand-rolled recursive watch: `fs.watch(dir, {recursive:true})` is unavailable
// on Linux before node 20 (the sandbox runs node 18), so we watch each directory
// and grow the watch set as subdirs appear. When a NEW subtree lands (e.g. a
// `git pull` creating dirs), its existing files are emitted too — a plain watch
// would miss files created before we attached.
function startWatch() {
  const extraDirs = loadExtraIgnore(ROOT);
  const watchers = new Map(); // absDir -> FSWatcher
  const relOf = (abs) => path.relative(ROOT, abs).replaceAll("\\", "/");

  const dirIgnored = (relDir) =>
    Boolean(relDir) && relDir.split("/").some((seg) => DEFAULT_IGNORE_DIRS.has(seg) || extraDirs.has(seg));

  function addTree(absDir, emitExisting) {
    if (dirIgnored(relOf(absDir))) return;
    if (!watchers.has(absDir)) {
      let watcher;
      try { watcher = fs.watch(absDir, (_t, filename) => onEvent(absDir, filename)); }
      catch { return; }
      watcher.on("error", () => { try { watcher.close(); } catch { /* gone */ } watchers.delete(absDir); });
      watchers.set(absDir, watcher);
    }
    let entries;
    try { entries = fs.readdirSync(absDir, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      const abs = path.join(absDir, entry.name);
      if (entry.isDirectory()) addTree(abs, emitExisting);
      else if (emitExisting) {
        const rel = relOf(abs);
        if (!isIgnored(rel, extraDirs)) { const meta = readMeta(abs); if (meta) emit("write", rel, meta); }
      }
    }
  }

  function onEvent(absDir, filename) {
    if (!filename) return;
    const abs = path.join(absDir, String(filename));
    const rel = relOf(abs);
    if (!rel || isIgnored(rel, extraDirs)) return;
    let stat;
    try { stat = fs.statSync(abs); } catch { emit("delete", rel); return; }
    if (stat.isDirectory()) { addTree(abs, true); return; } // new subtree → watch + surface its files
    const meta = readMeta(abs);
    if (meta) emit("write", rel, meta);
  }

  addTree(ROOT, false); // initial scan doesn't re-emit already-materialized files
  emit("ready", "", { root: ROOT });
}

const isMain = process.argv[1] === fileURLToPath(import.meta.url);

if (isMain && process.argv.includes("--selfcheck")) {
  const fail = [];
  const chk = (label, got, want) => { if (got !== want) fail.push(`${label}: got ${got}, want ${want}`); };
  chk("keep source", isIgnored("src/main.py"), false);
  chk("keep nested", isIgnored("a/b/c/util.ts"), false);
  chk("ignore node_modules", isIgnored("node_modules/left-pad/index.js"), true);
  chk("ignore nested node_modules", isIgnored("src/x/node_modules/y.js"), true);
  chk("ignore .git", isIgnored(".git/config"), true);
  chk("ignore __pycache__", isIgnored("pkg/__pycache__/mod.cpython.pyc"), true);
  chk("ignore .pyc", isIgnored("mod.pyc"), true);
  chk("ignore lockfile", isIgnored("package-lock.json"), true);
  chk("ignore dist", isIgnored("dist/bundle.js"), true);
  chk("ignore .osio", isIgnored(".osio/manifest.json"), true);
  chk("extra ignore", isIgnored("secrets/key.txt", new Set(["secrets"])), true);
  chk("hash stable", hashContent(Buffer.from("hello")), hashContent(Buffer.from("hello")));
  chk("text not binary", looksBinary(Buffer.from("print('hi')\n")), false);
  chk("NUL is binary", looksBinary(Buffer.from([0x89, 0x50, 0x00, 0x01])), true);
  if (fail.length) { process.stderr.write(`selfcheck FAIL:\n${fail.join("\n")}\n`); process.exit(1); }
  process.stdout.write("selfcheck OK: fs-agent ignore matcher correct\n");
  process.exit(0);
}

if (isMain) startWatch();
