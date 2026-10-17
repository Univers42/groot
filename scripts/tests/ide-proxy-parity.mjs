/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   ide-proxy-parity.mjs                               :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/13 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/13 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Proves the socket proxy's shape filter still accepts everything the bridge
// actually sends: the spec builders run here, the proxy's own checker decides.
// A bridge edit that changes a create/exec body fails this file before it can
// fail at provisioning time. Run from the worktree root, no daemon needed:
//
//   node scripts/tests/ide-proxy-parity.mjs

import {
  deriveNames,
  buildContainerSpec,
  buildGitExecSpec,
  buildSearchExecSpec,
  buildFsOpSpec,
  buildWriteExecSpec,
  buildPortsExecSpec,
  buildPortTunnelExecSpec,
  buildShellExecSpec,
  buildFsAgentExecSpec,
} from "../../apps/osionos/app/scripts/ide-sandbox-spec.mjs";
import { createShapeViolation, execShapeViolation, shapeLimits } from "../../infrastructure/docker/osionos/ide-socket-proxy/create-shape.mjs";

const LIMITS = shapeLimits({});
const UUIDS = [
  ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"],
  ["33333333-3333-4333-8333-333333333333", "44444444-4444-4444-8444-444444444444"],
  ["AAAAAAAA-bbbb-4ccc-8ddd-eeeeeeeeeeee", "55555555-5555-4555-8555-555555555555"],
];

const fail = [];
let count = 0;

/** The bridge derives the volume name from the SAME digest as the container
 *  name, so the create path and the volume mount are built from one call. */
function assertCreate(label, userId, workspaceId, diskSize) {
  const names = deriveNames(userId, workspaceId);
  const spec = buildContainerSpec({ userId, workspaceId, image: LIMITS.image, sandboxNet: LIMITS.sandboxNet, volumeName: names.volumeName, diskSize });
  // The bridge's own path (ide-docker.mjs) and the versioned form a client may send.
  for (const path of [`/containers/create?name=${encodeURIComponent(names.containerName)}`, `/v1.47/containers/create?name=${names.containerName}`]) {
    const got = createShapeViolation(spec, path, LIMITS);
    count += 1;
    if (got !== null) fail.push(`${label} (${path}): ${got}`);
  }
}

for (const [userId, workspaceId] of UUIDS) assertCreate(`create ${userId}`, userId, workspaceId, "");
for (const [userId, workspaceId] of UUIDS) assertCreate(`create+quota ${userId}`, userId, workspaceId, "10G");

function assertExec(label, spec) {
  const got = execShapeViolation(spec);
  count += 1;
  if (got !== null) fail.push(`${label}: ${got}`);
}

assertExec("git status", buildGitExecSpec(["git", "status"]));
assertExec("git status with PAT", buildGitExecSpec(["git", "status"], "x"));
assertExec("search", buildSearchExecSpec("needle"));
assertExec("fsop read", buildFsOpSpec("read", { path: "a.txt", offset: 0, length: 16 }));
assertExec("write", buildWriteExecSpec("a.txt", "aGk="));
assertExec("ports", buildPortsExecSpec());
assertExec("tunnel", buildPortTunnelExecSpec(3000));
assertExec("shell", buildShellExecSpec());
assertExec("shell with a username", buildShellExecSpec({ username: "dylan" }));
assertExec("safe shell", buildShellExecSpec({ safe: true, username: "dylan" }));
assertExec("fs-agent", buildFsAgentExecSpec());
// COPIED, not imported: lspExecSpec is a private function of bridge-ide-exec.mjs.
// Its literal shape is line 113 of that file; keep the copy in step with it.
assertExec("lsp", {
  User: "10001:10001",
  WorkingDir: "/workspace",
  AttachStdin: true,
  AttachStdout: true,
  AttachStderr: true,
  Cmd: ["typescript-language-server", "--stdio"],
});

if (fail.length) {
  process.stderr.write(`parity FAIL: ${fail.length} of ${count}\n${fail.map((f) => `  ${f}`).join("\n")}\n`);
  process.exit(1);
}
process.stdout.write(`parity OK: ${count} shapes\n`);