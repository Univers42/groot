// **************************************************************************** //
//                                                                              //
//                                                         :::      ::::::::    //
//    osio-fs-agent.harness.mjs                          :+:      :+:    :+:    //
//                                                     +:+ +:+         +:+      //
//    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         //
//                                                 +#+#+#+#+#+   +#+            //
//    Created: 2026/10/13 00:00:00 by dlesieur          #+#    #+#              //
//    Updated: 2026/10/13 00:00:00 by dlesieur         ###   ########.fr        //
//                                                                              //
// **************************************************************************** //

// Drives the real agent for osio-fs-agent.move.test.mjs: spawn it over a temp root
// (optionally with a fault injected into fs.watch), poll its event stream, freeze it,
// force an inode reuse. Test-only: the Dockerfile COPYs the agent alone.
// Ponytail: "no event" is asserted after a 700 ms quiet window — an agent slower than
// that on a loaded host would emit late and pass a test it should fail (under-reports).

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const AGENT = path.join(path.dirname(fileURLToPath(import.meta.url)), "osio-fs-agent.mjs");
const WAIT_MS = 3000;
const QUIET_MS = 700;
export const MOVED = { "d1/a.omd": "a\n", "d1/sub/c.omd": "c\n" };

// Runs the agent with fs.watch wrapped to inject one fault at an exact point (argv:
// agent, fault, target dir). It prints "fault:<name>" when the fault fires, so a fault
// that never fired fails the test instead of passing it vacuously.
const FAULT_RUNNER = `
import fs from "node:fs";
const [agentUrl, fault, target] = process.argv.slice(2);
const watch = fs.watch;
const made = [];
fs.watch = function (dir, ...rest) {
  const watcher = watch.call(fs, dir, ...rest);
  if (dir !== target) return watcher;
  made.push(watcher);
  if (fault === "swap" && made.length === 1) {
    fs.renameSync(target, target + ".old");
    fs.mkdirSync(target);
    process.stderr.write("fault:swap\\n");
  }
  if (fault === "stale-error" && made.length === 2) {
    setImmediate(() => { made[0].emit("error", new Error("injected")); process.stderr.write("fault:stale-error\\n"); });
  }
  return watcher;
};
await import(agentUrl);
`;

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
export const quiet = () => sleep(QUIET_MS);
export const isEvent = (event, p) => (e) => e.event === event && e.path === p;
export const brief = (events) => events.map((e) => `${e.event} ${e.path}`);

// Ponytail: polls every 20 ms up to WAIT_MS — a slower agent fails the test (loud), never passes it.
export async function poll(check, describe) {
  const deadline = Date.now() + WAIT_MS;
  while (Date.now() < deadline) {
    const hit = check();
    if (hit) return hit;
    await sleep(20);
  }
  return assert.fail(`${describe()}: not within ${WAIT_MS} ms`);
}

export const waitFor = (events, predicate, from = 0) =>
  poll(() => events.slice(from).find(predicate), () => `no matching event; got ${JSON.stringify(brief(events.slice(from)))}`);

function startAgent(root, fault) {
  // process.argv[1] must be the agent's own path for its isMain check; the runner gets the URL from argv[2].
  const args = fault ? ["--input-type=module", "-e", FAULT_RUNNER, AGENT, pathToFileURL(AGENT).href, ...fault] : [AGENT];
  const child = spawn(process.execPath, args, { env: { ...process.env, OSIO_FS_ROOT: root } });
  const events = [];
  const err = { text: "" };
  let buffered = "";
  child.stdout.on("data", (chunk) => {
    buffered += chunk;
    const lines = buffered.split("\n");
    buffered = lines.pop();
    for (const line of lines) if (line) events.push(JSON.parse(line));
  });
  child.stderr.on("data", (chunk) => { err.text += chunk; });
  return { events, child, err };
}

function lay(root, layout) {
  for (const [rel, content] of Object.entries(layout)) {
    const abs = path.join(root, rel);
    fs.mkdirSync(content === null ? abs : path.dirname(abs), { recursive: true });
    if (content !== null) fs.writeFileSync(abs, content);
  }
}

export async function workspace(t, layout = MOVED, fault = undefined) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "fsw-"));
  lay(root, layout);
  const agent = startAgent(root, fault?.(root));
  t.after(() => { agent.child.kill(); fs.rmSync(root, { recursive: true, force: true }); });
  await waitFor(agent.events, (e) => e.event === "ready");
  return { root, ...agent };
}

const procState = (pid) => {
  const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
  return stat[stat.lastIndexOf(")") + 2];
};

// Every mutation lands in the inotify queue before the agent handles any (the race,
// made deterministic). Waits for the kernel's stopped state, not for a sleep.
export async function frozen(child, mutate) {
  process.kill(child.pid, "SIGSTOP");
  try {
    await poll(() => procState(child.pid) === "T", () => `agent ${child.pid} not stopped`);
    mutate();
  } finally {
    process.kill(child.pid, "SIGCONT");
  }
}

// Ponytail: parks at most 64 fresh inodes looking for the old one — a filesystem that
// never reuses it (tmpfs) returns false and the caller fails loud, never passes.
export function recreateReusingInode(dir) {
  const old = fs.statSync(dir).ino;
  fs.rmSync(dir, { recursive: true });
  fs.mkdirSync(dir);
  const parked = [];
  while (fs.statSync(dir).ino !== old && parked.length < 64) {
    parked.push(`${dir}.park${parked.length}`);
    fs.renameSync(dir, parked.at(-1));
    fs.mkdirSync(dir);
  }
  for (const p of parked) fs.rmdirSync(p);
  return fs.statSync(dir).ino === old;
}
