/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   create-shape.selfcheck.mjs                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/13 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/13 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// The shape check's own cases, kept out of proxy.mjs so the runtime file stays small. Each case
// changes the bridge's canonical body in ONE place. Run from the worktree root, no daemon needed:
//   node infrastructure/docker/osionos/ide-socket-proxy/create-shape.selfcheck.mjs
// proxy.mjs --selfcheck imports the fixtures below; the image does not ship this file.

import { fileURLToPath } from "node:url";
import { createShapeViolation, execShapeViolation, homeVolumeFor, shapeLimits } from "./create-shape.mjs";

const LIMITS = shapeLimits(process.env);
const MANAGED_LABEL = "osio.ide.managed";

// The bridge's own create body (ide-sandbox-spec.mjs buildContainerSpec) for a
// fixed digest and two fixed UUIDs — the one shape that must be accepted.
export const DIGEST = "a".repeat(32);
const OWNER = "11111111-1111-4111-8111-111111111111";
const WORKSPACE = "22222222-2222-4222-8222-222222222222";
// The bridge's own, unversioned path (ide-docker.mjs); the versioned form is checked below.
const WORKSPACE_MOUNT = { Type: "volume", Source: `osio-ide-vol-${DIGEST}`, Target: "/workspace" };
const OTHER_OWNER = "33333333-3333-4333-8333-333333333333";
export const CANON_PATH = `/containers/create?name=ide-${DIGEST}`;
export const mk = () => ({
  Image: LIMITS.image,
  User: "10001:10001",
  WorkingDir: "/workspace",
  Cmd: ["sleep", "infinity"],
  Env: [
    "HTTP_PROXY=http://ide-egress:8080", "HTTPS_PROXY=http://ide-egress:8080",
    "http_proxy=http://ide-egress:8080", "https_proxy=http://ide-egress:8080",
    "NO_PROXY=localhost,127.0.0.1", "no_proxy=localhost,127.0.0.1", "GIT_TERMINAL_PROMPT=0",
  ],
  Labels: { [MANAGED_LABEL]: "1", "osio.ide.owner": OWNER, "osio.ide.workspace": WORKSPACE },
  HostConfig: {
    NetworkMode: LIMITS.sandboxNet, CapDrop: ["ALL"], SecurityOpt: ["no-new-privileges:true"],
    ReadonlyRootfs: true,
    Mounts: [WORKSPACE_MOUNT, { Type: "volume", Source: homeVolumeFor(OWNER), Target: "/home/coder" }],
    Tmpfs: { "/tmp": "size=64m,mode=1777" },
    PidsLimit: 512, Memory: 1073741824, MemorySwap: 1073741824, NanoCpus: 1000000000,
    Ulimits: [{ Name: "core", Soft: 0, Hard: 0 }, { Name: "nproc", Soft: 512, Hard: 512 }, { Name: "nofile", Soft: 4096, Hard: 4096 }],
    RestartPolicy: { Name: "no" },
  },
});
export const host = (patch) => { const b = mk(); b.HostConfig = { ...b.HostConfig, ...patch }; return b; };
const dropHost = (key) => { const b = mk(); delete b.HostConfig[key]; return b; };

function shapeFailures() {
  const fail = [];
  const chk = (label, got, want) => { if (got !== want) fail.push(`${label}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); };
  const refuse = (label, got) => { if (got === null) fail.push(`${label}: accepted, want a refusal reason`); };
  chk("create canonical ok", createShapeViolation(mk(), CANON_PATH, LIMITS), null);
  chk("create versioned path ok", createShapeViolation(mk(), `/v1.47/containers/create?name=ide-${DIGEST}`, LIMITS), null);
  chk("create OomScoreAdj 500 ok", createShapeViolation(host({ OomScoreAdj: 500 }), CANON_PATH, LIMITS), null);
  chk("create OomScoreAdj other refused", createShapeViolation(host({ OomScoreAdj: -1000 }), CANON_PATH, LIMITS), "OomScoreAdj");

  // Every case below changes the canonical body in exactly ONE place, so a
  // failure names the single field that stopped being the bridge's shape.
  const CREATE_REFUSALS = [
    ["volume DriverConfig", host({ Mounts: [{ Type: "volume", Source: `osio-ide-vol-${DIGEST}`, Target: "/workspace", VolumeOptions: { DriverConfig: { Name: "local", Options: { o: "bind", device: "/" } } } }] })],
    ["other volume digest", host({ Mounts: [{ ...WORKSPACE_MOUNT, Source: `osio-ide-vol-${"b".repeat(32)}` }, mk().HostConfig.Mounts[1]] })],
    ["workspace mount alone", host({ Mounts: [WORKSPACE_MOUNT] })],
    ["another owner's home hash", host({ Mounts: [WORKSPACE_MOUNT, { ...mk().HostConfig.Mounts[1], Source: homeVolumeFor(OTHER_OWNER) }] })],
    ["a third mount", host({ Mounts: [...mk().HostConfig.Mounts, { Type: "volume", Source: `osio-ide-vol-${"c".repeat(32)}`, Target: "/data" }] })],
    ["home Target not /home/coder", host({ Mounts: [WORKSPACE_MOUNT, { ...mk().HostConfig.Mounts[1], Target: "/home/other" }] })],
    ["home Type bind", host({ Mounts: [WORKSPACE_MOUNT, { ...mk().HostConfig.Mounts[1], Type: "bind" }] })],
    ["mounts in the wrong order", host({ Mounts: [...mk().HostConfig.Mounts].reverse() })],
    ["home tmpfs next to the home mount", host({ Tmpfs: { ...mk().HostConfig.Tmpfs, "/home/coder": "size=64m,mode=0700,uid=10001,gid=10001" } })],
    ["egress net", host({ NetworkMode: "osio-ide-egress-net" })],
    ["VolumesFrom", host({ VolumesFrom: ["x"] })],
    ["PortBindings", host({ PortBindings: {} })],
    ["Sysctls", host({ Sysctls: {} })],
    ["Runtime", host({ Runtime: "runc" })],
    ["CgroupParent", host({ CgroupParent: "/" })],
    ["no ReadonlyRootfs", dropHost("ReadonlyRootfs")],
    ["ReadonlyRootfs false", host({ ReadonlyRootfs: false })],
    ["CapDrop empty", host({ CapDrop: [] })],
    ["Memory over the cap", host({ Memory: 1073741825, MemorySwap: 1073741825 })],
    ["MemorySwap differs", host({ MemorySwap: 1 })],
    ["User root", { ...mk(), User: "0" }],
    ["foreign image", { ...mk(), Image: "alpine" }],
    ["eighth Env entry", { ...mk(), Env: [...mk().Env, "EXTRA=1"] }],
    ["Env entry swapped", { ...mk(), Env: mk().Env.map((e) => (e.startsWith("HTTP_PROXY") ? "HTTP_PROXY=http://elsewhere:1" : e)) }],
    ["extra top-level key", { ...mk(), Entrypoint: ["sh"] }],
    ["extra label", { ...mk(), Labels: { ...mk().Labels, extra: "1" } }],
  ];
  for (const [label, body] of CREATE_REFUSALS) refuse(`create ${label}`, createShapeViolation(body, CANON_PATH, LIMITS));
  refuse("create path without name", createShapeViolation(mk(), "/v1.47/containers/create", LIMITS));
  refuse("create path with extra query", createShapeViolation(mk(), `${CANON_PATH}&x=1`, LIMITS));
  refuse("create path digest mismatch", createShapeViolation(mk(), `/v1.47/containers/create?name=ide-${"b".repeat(32)}`, LIMITS));

  const SHELL = { User: "10001:10001", WorkingDir: "/workspace", AttachStdin: true, AttachStdout: true, AttachStderr: true, Tty: true, Env: ["TERM=xterm-256color"], Cmd: ["bash", "-l"] };
  const noUser = { ...SHELL };
  delete noUser.User;
  const EXEC_REFUSALS = [
    ["Privileged true", { ...SHELL, Privileged: true }],
    ["Privileged false", { ...SHELL, Privileged: false }],
    ["User root", { ...SHELL, User: "0" }],
    ["User missing", noUser],
    ["WorkingDir root", { ...SHELL, WorkingDir: "/" }],
    ["Cmd empty", { ...SHELL, Cmd: [] }],
    ["Cmd string", { ...SHELL, Cmd: "sh" }],
    ["Env without a name", { ...SHELL, Env: ["=x"] }],
    ["Detach", { ...SHELL, Detach: false }],
  ];
  chk("exec shell ok", execShapeViolation(SHELL), null);
  for (const [label, body] of EXEC_REFUSALS) refuse(`exec ${label}`, execShapeViolation(body));

  return fail;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const fail = shapeFailures();
  if (fail.length) { process.stderr.write(`shape selfcheck FAIL:\n${fail.join("\n")}\n`); process.exit(1); }
  process.stdout.write("shape selfcheck OK: bridge shape accepted, every one-field change refused\n");
}
