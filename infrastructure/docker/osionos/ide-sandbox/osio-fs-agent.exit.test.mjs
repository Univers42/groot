// **************************************************************************** //
//                                                                              //
//                                                         :::      ::::::::    //
//    osio-fs-agent.exit.test.mjs                        :+:      :+:    :+:    //
//                                                     +:+ +:+         +:+      //
//    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         //
//                                                 +#+#+#+#+#+   +#+            //
//    Created: 2026/10/14 00:00:00 by dlesieur          #+#    #+#              //
//    Updated: 2026/10/14 00:00:00 by dlesieur         ###   ########.fr        //
//                                                                              //
// **************************************************************************** //

// A reload re-attaches: the bridge opens a new agent and the old stream closes, which
// dockerd turns into EOF on the old agent's stdin (no TTY). The old agent must go; the new
// one must keep streaming. Runs like the move tests:
//   docker run --rm -v "$PWD":/agent:ro node:18-bookworm-slim \
//     node --test /agent/osio-fs-agent.exit.test.mjs

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { isEvent, poll, sleep, waitFor, workspace } from "./osio-fs-agent.harness.mjs";

test("a re-attach leaves one agent: the first exits when its stdin ends, the second keeps streaming", async (t) => {
  const first = await workspace(t, {});
  const second = await workspace(t, {});
  const exits = [];
  first.child.once("exit", (code, signal) => exits.push({ code, signal }));
  first.child.stdin.end();
  await poll(() => exits.length > 0, () => "the first agent is still running after its stdin ended");
  assert.deepEqual(exits, [{ code: 0, signal: null }]);
  await sleep(200);
  assert.equal(second.child.exitCode, null, "the second agent is still running");
  fs.writeFileSync(path.join(second.root, "main.c"), "int\tmain(void);\n");
  await waitFor(second.events, isEvent("write", "main.c"));
});
