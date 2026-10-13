// **************************************************************************** //
//                                                                              //
//                                                         :::      ::::::::    //
//    osio-fs-agent.move.test.mjs                        :+:      :+:    :+:    //
//                                                     +:+ +:+         +:+      //
//    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         //
//                                                 +#+#+#+#+#+   +#+            //
//    Created: 2026/10/13 00:00:00 by dlesieur          #+#    #+#              //
//    Updated: 2026/10/13 00:00:00 by dlesieur         ###   ########.fr        //
//                                                                              //
// **************************************************************************** //

// The real agent over a temp root, driven like a shell would. Needs inotify and an
// inode-reusing filesystem (ext4 / overlay; tmpfs never reuses), so it runs in the
// sandbox's node line with TMPDIR on a docker volume, one CPU like the sandbox:
//   docker run --rm --cpus=1 -v "$PWD":/agent:ro -v fsw-vol:/vol -e TMPDIR=/vol \
//     node:18-bookworm-slim node --test /agent/osio-fs-agent.move.test.mjs
// Not copied into the image (the Dockerfile COPYs the agent alone). Race tests freeze
// the agent (SIGSTOP) so every mutation is queued before it handles any: on one CPU an
// unfrozen race passes vacuously.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";
import {
  AGENT, MOVED, brief, frozen, isEvent, poll, quiet, recreateReusingInode, sleep, waitFor, workspace,
} from "./osio-fs-agent.harness.mjs";

test("C4 an edit inside a moved directory names only the new path", async (t) => {
  const { root, events } = await workspace(t);
  fs.renameSync(path.join(root, "d1"), path.join(root, "d2"));
  await waitFor(events, isEvent("write", "d2/sub/c.omd"));
  await quiet();
  const from = events.length;
  fs.appendFileSync(path.join(root, "d2", "a.omd"), "a2\n");
  fs.appendFileSync(path.join(root, "d2", "sub", "c.omd"), "c2\n");
  await waitFor(events, isEvent("write", "d2/sub/c.omd"), from);
  await quiet();
  assert.deepEqual(brief(events.slice(from).filter((e) => e.path.startsWith("d1/"))), []);
});

test("C4 a directory recreated under the moved name is watched again", async (t) => {
  const { root, events } = await workspace(t);
  fs.renameSync(path.join(root, "d1"), path.join(root, "d2"));
  await waitFor(events, isEvent("write", "d2/a.omd"));
  await quiet();
  fs.mkdirSync(path.join(root, "d1", "sub"), { recursive: true });
  await quiet();
  fs.writeFileSync(path.join(root, "d1", "new.omd"), "new\n");
  fs.writeFileSync(path.join(root, "d1", "sub", "deep.omd"), "deep\n");
  await waitFor(events, isEvent("write", "d1/new.omd"));
  await waitFor(events, isEvent("write", "d1/sub/deep.omd"));
});

test("C1 frozen rm -rf d1; mkdir d1 reusing the inode: the new d1 is watched", async (t) => {
  const { root, events, child } = await workspace(t);
  let reused = false;
  await frozen(child, () => { reused = recreateReusingInode(path.join(root, "d1")); });
  assert.ok(reused, `inode not reused under ${os.tmpdir()}: run with TMPDIR on an ext4 docker volume, not tmpfs`);
  await quiet();
  const from = events.length;
  fs.writeFileSync(path.join(root, "d1", "y.omd"), "y\n");
  await waitFor(events, isEvent("write", "d1/y.omd"), from);
});

test("C2 frozen mv d1 d2; mkdir d1: the new d1 is watched", async (t) => {
  const { root, events, child } = await workspace(t);
  await frozen(child, () => { fs.renameSync(path.join(root, "d1"), path.join(root, "d2")); fs.mkdirSync(path.join(root, "d1")); });
  await waitFor(events, isEvent("write", "d2/a.omd"));
  await quiet();
  const from = events.length;
  fs.writeFileSync(path.join(root, "d1", "x.omd"), "x\n");
  await waitFor(events, isEvent("write", "d1/x.omd"), from);
});

test("C2 frozen mv d1 d2; mkdir d1: delete d1 precedes write d2/a.omd, as unraced", async (t) => {
  const { root, events, child } = await workspace(t);
  await frozen(child, () => { fs.renameSync(path.join(root, "d1"), path.join(root, "d2")); fs.mkdirSync(path.join(root, "d1")); });
  await waitFor(events, isEvent("write", "d2/a.omd"));
  await quiet();
  const stream = brief(events.slice(1));
  const del = stream.indexOf("delete d1");
  assert.ok(del !== -1 && del < stream.indexOf("write d2/a.omd"), `stream: ${JSON.stringify(stream)}`);
});

test("C4 rename over an existing empty directory: edits land on the new path only", async (t) => {
  const { root, events } = await workspace(t, { "d1/a.omd": "a\n", d2: null });
  fs.renameSync(path.join(root, "d1"), path.join(root, "d2"));
  await waitFor(events, isEvent("write", "d2/a.omd"));
  await quiet();
  const from = events.length;
  fs.appendFileSync(path.join(root, "d2", "a.omd"), "2\n");
  fs.writeFileSync(path.join(root, "d2", "n.omd"), "n\n");
  await waitFor(events, isEvent("write", "d2/n.omd"), from);
  await waitFor(events, isEvent("write", "d2/a.omd"), from);
  await quiet();
  assert.deepEqual(brief(events.slice(from).filter((e) => !e.path.startsWith("d2/") || e.path.startsWith("d2/d"))), []);
});

test("C4 a directory moved out of the root goes silent", async (t) => {
  const out = fs.mkdtempSync(path.join(os.tmpdir(), "out-"));
  t.after(() => fs.rmSync(out, { recursive: true, force: true }));
  const { root, events } = await workspace(t);
  fs.renameSync(path.join(root, "d1"), path.join(out, "d1"));
  await waitFor(events, isEvent("delete", "d1"));
  await quiet();
  const from = events.length;
  fs.appendFileSync(path.join(out, "d1", "a.omd"), "2\n");
  fs.writeFileSync(path.join(out, "d1", "sub", "z.omd"), "z\n");
  await quiet();
  assert.deepEqual(brief(events.slice(from)), []);
});

test("C4 a directory moved into an ignored directory goes silent", async (t) => {
  const { root, events } = await workspace(t, { ...MOVED, "node_modules/k.js": "k" });
  fs.renameSync(path.join(root, "d1"), path.join(root, "node_modules", "d1"));
  await waitFor(events, isEvent("delete", "d1"));
  await quiet();
  const from = events.length;
  fs.appendFileSync(path.join(root, "node_modules", "d1", "a.omd"), "2\n");
  fs.writeFileSync(path.join(root, "node_modules", "d1", "sub", "z.omd"), "z\n");
  await quiet();
  assert.deepEqual(brief(events.slice(from)), []);
});

test("C4 rm -rf d1, then a later mkdir d1 is watched", async (t) => {
  const { root, events } = await workspace(t);
  fs.rmSync(path.join(root, "d1"), { recursive: true });
  await waitFor(events, isEvent("delete", "d1"));
  await quiet();
  fs.mkdirSync(path.join(root, "d1"));
  await quiet();
  const from = events.length;
  fs.writeFileSync(path.join(root, "d1", "y.omd"), "y\n");
  await waitFor(events, isEvent("write", "d1/y.omd"), from);
});

test("C4 nested recreate under a moved name is watched", async (t) => {
  const { root, events } = await workspace(t, { "d1/sub/deep/q.omd": "q\n" });
  fs.renameSync(path.join(root, "d1"), path.join(root, "d2"));
  await waitFor(events, isEvent("write", "d2/sub/deep/q.omd"));
  await quiet();
  fs.mkdirSync(path.join(root, "d1", "sub", "deep"), { recursive: true });
  await quiet();
  const from = events.length;
  fs.writeFileSync(path.join(root, "d1", "sub", "deep", "r.omd"), "r\n");
  await waitFor(events, isEvent("write", "d1/sub/deep/r.omd"), from);
});

test("C4 frozen swap d1 <-> d2: edits are attributed to the right path", async (t) => {
  const { root, events, child } = await workspace(t, { "d1/a.omd": "a\n", "d2/b.omd": "b\n" });
  const at = (p) => path.join(root, p);
  await frozen(child, () => { fs.renameSync(at("d1"), at("tmp")); fs.renameSync(at("d2"), at("d1")); fs.renameSync(at("tmp"), at("d2")); });
  await waitFor(events, isEvent("write", "d2/a.omd"));
  await quiet();
  const from = events.length;
  fs.appendFileSync(at("d1/b.omd"), "2\n");
  fs.appendFileSync(at("d2/a.omd"), "2\n");
  await waitFor(events, isEvent("write", "d1/b.omd"), from);
  await waitFor(events, isEvent("write", "d2/a.omd"), from);
  await quiet();
  assert.deepEqual(brief(events.slice(from)).filter((s) => s !== "write d1/b.omd" && s !== "write d2/a.omd"), []);
});

test("C4 frozen: a watched dir replaced by a file syncs the file and the agent survives ENOTDIR", async (t) => {
  const { root, events, child } = await workspace(t);
  await frozen(child, () => { fs.rmSync(path.join(root, "d1"), { recursive: true }); fs.writeFileSync(path.join(root, "d1"), "now a file\n"); });
  await waitFor(events, isEvent("write", "d1"));
  const from = events.length;
  fs.writeFileSync(path.join(root, "z.omd"), "z\n");
  await waitFor(events, isEvent("write", "z.omd"), from);
  assert.equal(child.exitCode, null);
});

test("C6 a moved assets.map/ directory stops reporting under its old name", async (t) => {
  const { root, events } = await workspace(t, { "assets.map/a.omd": "a\n" });
  fs.renameSync(path.join(root, "assets.map"), path.join(root, "assets"));
  await waitFor(events, isEvent("write", "assets/a.omd"));
  await quiet();
  const from = events.length;
  fs.appendFileSync(path.join(root, "assets", "a.omd"), "2\n");
  await waitFor(events, isEvent("write", "assets/a.omd"), from);
  await quiet();
  assert.deepEqual(brief(events.slice(from).filter((e) => e.path.startsWith("assets.map"))), []);
});

test("C6 synced directory set unchanged: assets.map/ synced from attach, a later late.map/ not", async (t) => {
  const { root, events } = await workspace(t, { "assets.map/a.omd": "a\n" });
  fs.appendFileSync(path.join(root, "assets.map", "a.omd"), "2\n");
  await waitFor(events, isEvent("write", "assets.map/a.omd"));
  fs.mkdirSync(path.join(root, "late.map"));
  await quiet();
  fs.writeFileSync(path.join(root, "late.map", "b.omd"), "b\n");
  await quiet();
  assert.deepEqual(brief(events.filter((e) => e.path.startsWith("late.map"))), []);
});

test("C7 identity comes from a stat taken before fs.watch (swap injected inside fs.watch)", async (t) => {
  const { root, events, err } = await workspace(t, MOVED, (r) => ["swap", path.join(r, "d1")]);
  await poll(() => err.text.includes("fault:swap"), () => `fault never fired; stderr: ${err.text}`);
  await quiet();
  const from = events.length;
  fs.writeFileSync(path.join(root, "d1", "new.omd"), "new\n");
  await waitFor(events, isEvent("write", "d1/new.omd"), from);
});

test("C7 a replaced watcher's late error leaves its successor's map entry", async (t) => {
  const { root, events, err } = await workspace(t, MOVED, (r) => ["stale-error", path.join(r, "d1")]);
  fs.rmSync(path.join(root, "d1"), { recursive: true });
  await waitFor(events, isEvent("delete", "d1"));
  await quiet();
  fs.mkdirSync(path.join(root, "d1"));
  await poll(() => err.text.includes("fault:stale-error"), () => `fault never fired; stderr: ${err.text}`);
  fs.writeFileSync(path.join(root, "d1", "n.omd"), "n\n");
  await waitFor(events, isEvent("write", "d1/n.omd"));
  fs.renameSync(path.join(root, "d1"), path.join(root, "d2"));
  await waitFor(events, isEvent("write", "d2/n.omd"));
  await quiet();
  const from = events.length;
  fs.appendFileSync(path.join(root, "d2", "n.omd"), "2\n");
  await waitFor(events, isEvent("write", "d2/n.omd"), from);
  await quiet();
  assert.deepEqual(brief(events.slice(from).filter((e) => e.path.startsWith("d1"))), []);
});

test("C5 watch table: dropping a subtree closes it and leaves no index entry behind", async () => {
  const { watchTable } = await import(pathToFileURL(AGENT).href);
  const closed = [];
  const table = watchTable();
  for (const p of ["/r", "/r/a", "/r/a/b", "/r/c"]) table.add(p, { watcher: { close: () => closed.push(p) } });
  table.drop("/r/a");
  assert.deepEqual(closed, ["/r/a", "/r/a/b"]);
  assert.deepEqual([...table.entries.keys()], ["/r", "/r/c"]);
  assert.deepEqual([...table.kids.get("/r")], ["/r/c"]);
  assert.equal(table.kids.has("/r/a"), false);
});

test("C5 watch table: a drop reaches the children of an entry its error handler removed", async () => {
  const { watchTable } = await import(pathToFileURL(AGENT).href);
  const closed = [];
  const table = watchTable();
  for (const p of ["/r", "/r/a", "/r/a/b"]) table.add(p, { watcher: { close: () => closed.push(p) } });
  table.entries.delete("/r/a");
  table.drop("/r");
  assert.deepEqual(closed, ["/r", "/r/a/b"]);
  assert.equal(table.entries.size, 0);
  assert.deepEqual([...table.kids].map(([dir, set]) => [dir, [...set]]), [["/", []]]);
});

// The delete is synchronous on purpose: during it only rm and the agent compete for the
// CPU, as in the sandbox (the gateway reads from outside). A reader parsing concurrently
// steals enough CPU that even the unfixed agent overflowed inotify (27626/30000).
// Counts real paths, not events: libuv also echoes each deleted dir's own DELETE_SELF and
// IGNORED as `delete dX/dX`, a path that never existed, and fewer echoes is not loss.
// Ponytail: "done" = 1.5 s without a new event (30 s cap); an agent stalled longer than
// that is cut short and fails the count (loud, never a false pass). Overflow is a threshold:
// a build ~10% costlier per event than the fix passes some runs (the fix with a throwing
// stat failed 3 of 6) — it under-reports a small slowdown; the drain bench measures it.
test("C5 bulk rm -rf of 3000 dirs x 10 files loses no file or directory delete", async (t) => {
  const layout = {};
  const expected = new Set(["top"]);
  for (let d = 0; d < 3000; d++) {
    const dir = `top/g${d % 50}/d${d}`;
    expected.add(path.dirname(dir)).add(dir);
    for (let f = 0; f < 10; f++) {
      layout[`${dir}/f${f}.omd`] = "x\n";
      expected.add(`${dir}/f${f}.omd`);
    }
  }
  const { root, events } = await workspace(t, layout);
  const from = events.length;
  fs.rmSync(path.join(root, "top"), { recursive: true });
  const cap = Date.now() + 30000;
  for (let seen = -1; seen !== events.length && Date.now() < cap; ) { seen = events.length; await sleep(1500); }
  const deleted = new Set(events.slice(from).filter((e) => e.event === "delete").map((e) => e.path));
  const missing = [...expected].filter((p) => !deleted.has(p));
  t.diagnostic(`bulk events=${events.length - from} missing=${missing.length}/${expected.size}`);
  assert.deepEqual(missing.slice(0, 5), []);
});
