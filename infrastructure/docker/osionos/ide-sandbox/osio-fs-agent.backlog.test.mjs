// **************************************************************************** //
//                                                                              //
//                                                         :::      ::::::::    //
//    osio-fs-agent.backlog.test.mjs                     :+:      :+:    :+:    //
//                                                     +:+ +:+         +:+      //
//    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         //
//                                                 +#+#+#+#+#+   +#+            //
//    Created: 2026/10/14 00:00:00 by dlesieur          #+#    #+#              //
//    Updated: 2026/10/14 00:00:00 by dlesieur         ###   ########.fr        //
//                                                                              //
// **************************************************************************** //

// A consumer that stops reading (a frozen tab, a stalled relay) while the shell rewrites a
// 400 KB file: through a pipe, every event the agent wrote queued in its memory, +0.53 MB
// each (devil C1, 2026-10-14). Past a small backlog the agent must keep the path alone, send
// its newest content once read again, and still exit when its stdin ends. Runs like the move tests:
//   docker run --rm -v "$PWD":/agent:ro node:18-bookworm-slim \
//     node --test /agent/osio-fs-agent.backlog.test.mjs
// Ponytail: 100 rewrites at 5 ms apart; a host too slow to fire a watch event per rewrite
// coalesces them, queues less, and could pass an unbounded agent (under-reports).

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { isEvent, poll, sleep, waitFor, workspace } from "./osio-fs-agent.harness.mjs";

const rssMb = (pid) => Number(/VmRSS:\s+(\d+)/.exec(fs.readFileSync(`/proc/${pid}/status`, "utf8"))[1]) / 1024;

test("a stalled consumer leaves the agent's memory flat; read again, it streams and exits on EOF", async (t) => {
  const agent = await workspace(t, {});
  agent.child.stdout.pause(); // the reader stops: the pipe fills, the agent's next write would queue
  const before = rssMb(agent.child.pid);
  const big = "a".repeat(400_000);
  for (let i = 0; i < 100; i += 1) {
    fs.writeFileSync(path.join(agent.root, "big.txt"), `${i}${big}`);
    await sleep(5);
  }
  await sleep(1_000);
  const growth = rssMb(agent.child.pid) - before;
  t.diagnostic(`grew ${growth.toFixed(1)} MB over 100 rewrites`);
  assert.ok(growth <= 16, `the agent grew ${growth.toFixed(1)} MB while nobody read it`);
  agent.child.stdout.resume();
  const last = (e) => e.event === "write" && e.path === "big.txt" && Buffer.from(e.content, "base64").toString().startsWith("99a");
  await waitFor(agent.events, last); // the waiting path is read again: its newest content arrives
  const sent = agent.events.filter(isEvent("write", "big.txt")).length;
  t.diagnostic(`big.txt sent ${sent} times for 100 rewrites`);
  assert.ok(sent < 100, "every rewrite was queued: nothing waited as a path");
  fs.writeFileSync(path.join(agent.root, "after.c"), "int\tx;\n");
  await waitFor(agent.events, isEvent("write", "after.c"));
  const exits = [];
  agent.child.once("exit", (code) => exits.push(code));
  agent.child.stdin.end();
  await poll(() => exits.length > 0, () => "the agent is still running after its stdin ended");
  assert.deepEqual(exits, [0]);
});
