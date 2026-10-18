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
  deriveHomeVolume,
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
import { volumeDriverOpts } from "../../apps/osionos/app/scripts/ide-docker.mjs";
import { buildInitSpec } from "../../apps/osionos/app/scripts/ide-volume-init.mjs";
import { createShapeViolation, execShapeViolation, shapeLimits } from "../../infrastructure/docker/osionos/ide-socket-proxy/create-shape.mjs";
import { unsafeVolumeBody } from "../../infrastructure/docker/osionos/ide-socket-proxy/volume-shape.mjs";
import { initShapeViolation } from "../../infrastructure/docker/osionos/ide-socket-proxy/init-shape.mjs";

const LIMITS = shapeLimits({});
const UUIDS = [
  ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"],
  ["33333333-3333-4333-8333-333333333333", "44444444-4444-4444-8444-444444444444"],
  ["AAAAAAAA-bbbb-4ccc-8ddd-eeeeeeeeeeee", "55555555-5555-4555-8555-555555555555"],
];

const UID = 20042;
const fail = [];
let count = 0;

/** The bridge derives the volume name from the SAME digest as the container
 *  name, so the create path and the volume mount are built from one call. */
function assertCreate(label, userId, workspaceId, diskSize) {
  const names = deriveNames(userId, workspaceId);
  const spec = buildContainerSpec({ userId, workspaceId, image: LIMITS.image, sandboxNet: LIMITS.sandboxNet, volumeName: names.volumeName, uid: UID, diskSize });
  // The bridge's own path (ide-docker.mjs) and the versioned form a client may send.
  for (const path of [`/containers/create?name=${encodeURIComponent(names.containerName)}`, `/v1.47/containers/create?name=${names.containerName}`]) {
    const got = createShapeViolation(spec, path, LIMITS);
    count += 1;
    if (got !== null) fail.push(`${label} (${path}): ${got}`);
  }
}

for (const [userId, workspaceId] of UUIDS) assertCreate(`create ${userId}`, userId, workspaceId, "");
/** The init the bridge sends before every create, through the proxy's own ideinit-* checker. */
function assertInit(userId, workspaceId) {
  const names = deriveNames(userId, workspaceId);
  const spec = buildInitSpec({
    userId, workspaceId, image: LIMITS.image, uid: UID,
    volumeName: names.volumeName, homeVolumeName: deriveHomeVolume(userId),
  });
  for (const path of [`/containers/create?name=ideinit-${names.digest}`, `/v1.47/containers/create?name=ideinit-${names.digest}`]) {
    const got = initShapeViolation(spec, path, LIMITS);
    count += 1;
    if (got !== null) fail.push(`init ${userId} (${path}): ${got}`);
  }
}

for (const [userId, workspaceId] of UUIDS) assertInit(userId, workspaceId);
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
assertExec("shell with a time zone", buildShellExecSpec({ username: "dylan", tz: "Europe/Paris" }));
assertExec("safe shell with a time zone", buildShellExecSpec({ safe: true, tz: "America/Argentina/Buenos_Aires" }));
assertExec("shell with an invalid time zone (UTC)", buildShellExecSpec({ tz: "not a zone;" }));
assertExec("fs-agent", buildFsAgentExecSpec());
// COPIED, not imported: lspExecSpec is a private function of bridge-ide-exec.mjs.
// Its literal shape is lspExecSpec in that file; keep the copy in step with it. No User: ADR 0011.
assertExec("lsp", {
  WorkingDir: "/workspace",
  AttachStdin: true,
  AttachStdout: true,
  AttachStderr: true,
  Cmd: ["typescript-language-server", "--stdio"],
});

// The quota literals the bridge sends must be exactly what the proxy admits, flag on or off.
for (const [flag, prefix] of [["on", "osio-ide-home-"], ["on", "osio-ide-vol-"], ["off", "osio-ide-home-"], ["off", "osio-ide-vol-"]]) {
  const name = `${prefix}${"a".repeat(32)}`;
  const DriverOpts = volumeDriverOpts(name, { OSIONOS_IDE_VOLUME_QUOTA: flag });
  count += 1;
  const got = unsafeVolumeBody({ Name: name, Driver: "local", Labels: { "osio.ide.managed": "1" }, ...(DriverOpts ? { DriverOpts } : {}) });
  if (got !== null) fail.push(`volume ${prefix} quota ${flag}: ${got}`);
}

// An exec that names a User is refused by the proxy; the bridge must never send one.
count += 1;
if (execShapeViolation({ ...buildShellExecSpec(), User: `${UID}:10001` }) !== "User") fail.push("exec with User was not refused");

if (fail.length) {
  process.stderr.write(`parity FAIL: ${fail.length} of ${count}\n${fail.map((f) => `  ${f}`).join("\n")}\n`);
  process.exit(1);
}
process.stdout.write(`parity OK: ${count} shapes\n`);