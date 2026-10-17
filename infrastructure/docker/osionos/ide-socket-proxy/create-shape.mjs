/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   create-shape.mjs                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/13 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/13 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Pure shape validators for the IDE socket proxy. The bridge's container and
// exec specs are the ONLY accepted shapes — every deviation is refused with a
// short reason. No I/O, no deps, Node 22 builtins only.

import { createHash } from "node:crypto";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// The bridge sends the unversioned path (ide-docker.mjs `call("POST", "/containers/create?name=…")`).
const CREATE_PATH_RE = /^\/(?:v[\d.]+\/)?containers\/create\?name=ide-([0-9a-f]{32})$/;
// The numeric uid a box runs as: allocated once per owner and bound in the ledger (ADR 0011). The gid is
// fixed so /etc/group stays static and never user-writable (ADR 0009).
export const UID_MIN = 20000;
export const UID_MAX = 59999;
export const BOX_GID = 10001;
const REQUIRED_ENV = [
  "HTTP_PROXY=http://ide-egress:8080",
  "HTTPS_PROXY=http://ide-egress:8080",
  "http_proxy=http://ide-egress:8080",
  "https_proxy=http://ide-egress:8080",
  "NO_PROXY=localhost,127.0.0.1",
  "no_proxy=localhost,127.0.0.1",
  "GIT_TERMINAL_PROMPT=0",
  "HOME=/home/coder",
];
export const LABEL_UID = "osio.ide.uid";
const REQUIRED_LABELS = ["osio.ide.managed", "osio.ide.owner", "osio.ide.workspace", LABEL_UID];
const REQUIRED_HOST_CONFIG = [
  "NetworkMode", "CapDrop", "SecurityOpt", "ReadonlyRootfs", "Mounts",
  "Tmpfs", "PidsLimit", "Memory", "MemorySwap", "NanoCpus", "Ulimits", "RestartPolicy",
];
const OPTIONAL_HOST_CONFIG = ["StorageOpt", "OomScoreAdj"];
// NoCopy: without it an emptied volume is re-filled from the image and its root reset to 10001:10001 755,
// which locks the user out of their own home (verdict G2).
const REQUIRED_MOUNT_KEYS = ["Type", "Source", "Target", "VolumeOptions"];
const NO_COPY = { NoCopy: true };
const REQUIRED_TMPFS_KEYS = ["/tmp"];
const HOME_TARGET = "/home/coder";
const REQUIRED_ULIMIT_NAMES = ["core", "nproc", "nofile"];
// No "User": an exec inherits the create User, and an explicit one would override it (verdict E4).
const ALLOWED_EXEC_KEYS = ["Cmd", "WorkingDir", "AttachStdin", "AttachStdout", "AttachStderr", "Tty", "Env"];

// Ponytail: the 8 Env strings and their order are the bridge's literal output;
// a bridge configured with extra proxies or a different GIT_TERMINAL_PROMPT
// value is refused until these constants move with it.
// Ponytail: maxMemory (1 GiB), maxNanoCpus (1B), maxPids (512) are the spec's
// defaults; a bridge configured with bigger limits is refused until these move
// with it.
// Ponytail: StorageOpt.size pattern ^[1-9][0-9]{0,4}[GM]$ caps at 99999G — a
// bridge asking for 100T is refused; the pattern is deliberately generous.

export function shapeLimits(env) {
  return {
    image: env.OSIONOS_IDE_SANDBOX_IMAGE || "osionos-ide-sandbox:latest",
    sandboxNet: env.OSIONOS_IDE_SANDBOX_NET || "osio-ide-sandbox-net",
    maxMemory: 1073741824,
    maxNanoCpus: 1000000000,
    maxPids: 512,
  };
}

export function sameKeys(obj, names) {
  if (obj === null || typeof obj !== "object" || Array.isArray(obj)) return false;
  const keys = Object.keys(obj);
  if (keys.length !== names.length) return false;
  for (const n of names) if (!keys.includes(n)) return false;
  return true;
}

export function deepEqualJson(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

function isSafePositiveInt(n, max) {
  return Number.isInteger(n) && n > 0 && n <= max;
}

export function isUuidLike(s) {
  return typeof s === "string" && UUID_RE.test(s);
}

// Same derivation as the bridge's deriveHomeVolume (ide-sandbox-spec.mjs); scripts/tests/ide-proxy-parity.mjs pins the two together.
export function homeVolumeFor(ownerId) {
  return `osio-ide-home-${createHash("sha256").update(String(ownerId)).digest("hex").slice(0, 32)}`;
}

/** The uid of a box User string "<uid>:10001", or null for anything else (non-numeric, a gid other
 *  than 10001, or a uid outside 20000..59999, which excludes 10001 and 65534). */
export function parseBoxUid(user) {
  const match = typeof user === "string" ? /^([0-9]{5}):([0-9]{5})$/.exec(user) : null;
  if (!match || Number(match[2]) !== BOX_GID) return null;
  const uid = Number(match[1]);
  return uid >= UID_MIN && uid <= UID_MAX ? uid : null;
}

// Same derivation as the bridge's deriveNames; the parity test pins the two together.
export function digestFor(ownerId, workspaceId) {
  return createHash("sha256").update(`${ownerId}:${workspaceId}`).digest("hex").slice(0, 32);
}

export function createShapeViolation(body, path, limits) {
  const match = path.match(CREATE_PATH_RE);
  if (!match) return "name";
  const digest = match[1];

  if (!sameKeys(body, ["Image", "User", "WorkingDir", "Cmd", "Env", "Labels", "HostConfig"])) return "top-level keys";

  if (body.Image !== limits.image) return "Image";
  const uid = parseBoxUid(body.User);
  if (uid === null) return "User";
  if (body.WorkingDir !== "/workspace") return "WorkingDir";
  if (!deepEqualJson(body.Cmd, ["sleep", "infinity"])) return "Cmd";

  if (!Array.isArray(body.Env) || body.Env.length !== 8) return "Env";
  for (const e of REQUIRED_ENV) if (!body.Env.includes(e)) return "Env";

  if (!sameKeys(body.Labels, REQUIRED_LABELS)) return "Labels";
  if (body.Labels["osio.ide.managed"] !== "1") return "Labels";
  if (!isUuidLike(body.Labels["osio.ide.owner"])) return "Labels";
  if (!isUuidLike(body.Labels["osio.ide.workspace"])) return "Labels";
  if (body.Labels[LABEL_UID] !== String(uid)) return "Labels";
  // The workspace volume is named after the digest, so a digest that is not this owner's and this
  // workspace's would mount someone else's workspace under the right labels (N12).
  if (digestFor(body.Labels["osio.ide.owner"], body.Labels["osio.ide.workspace"]) !== digest) return "name";

  const hc = body.HostConfig;
  const allowedHostConfig = [...REQUIRED_HOST_CONFIG, ...OPTIONAL_HOST_CONFIG];
  const keys = Object.keys(hc);
  if (keys.length < REQUIRED_HOST_CONFIG.length || keys.length > allowedHostConfig.length) return "HostConfig keys";
  for (const k of keys) if (!allowedHostConfig.includes(k)) return "HostConfig keys";
  for (const k of REQUIRED_HOST_CONFIG) if (!keys.includes(k)) return "HostConfig keys";

  if (hc.NetworkMode !== limits.sandboxNet) return "NetworkMode";
  if (!deepEqualJson(hc.CapDrop, ["ALL"])) return "CapDrop";
  if (!deepEqualJson(hc.SecurityOpt, ["no-new-privileges:true"])) return "SecurityOpt";
  if (hc.ReadonlyRootfs !== true) return "ReadonlyRootfs";
  if (!deepEqualJson(hc.RestartPolicy, { Name: "no" })) return "RestartPolicy";

  // Positional: [workspace, home]. The home Source is recomputed from the owner label, so a
  // body naming another user's home (or any other volume) at /home/coder is refused.
  if (!Array.isArray(hc.Mounts) || hc.Mounts.length !== 2) return "Mounts";
  const [workspace, home] = hc.Mounts;
  if (!sameKeys(workspace, REQUIRED_MOUNT_KEYS) || !deepEqualJson(workspace.VolumeOptions, NO_COPY)) return "Mounts";
  if (workspace.Type !== "volume" || workspace.Target !== "/workspace") return "Mounts";
  if (workspace.Source !== `osio-ide-vol-${digest}`) return "Mounts";
  if (!sameKeys(home, REQUIRED_MOUNT_KEYS) || !deepEqualJson(home.VolumeOptions, NO_COPY)) return "Mounts";
  if (home.Type !== "volume" || home.Target !== HOME_TARGET) return "Mounts";
  if (home.Source !== homeVolumeFor(body.Labels["osio.ide.owner"])) return "Mounts";

  if (!sameKeys(hc.Tmpfs, REQUIRED_TMPFS_KEYS)) return "Tmpfs";
  if (hc.Tmpfs["/tmp"] !== "size=64m,mode=1777,exec") return "Tmpfs";

  if (!isSafePositiveInt(hc.PidsLimit, limits.maxPids)) return "PidsLimit";
  if (!isSafePositiveInt(hc.Memory, limits.maxMemory)) return "Memory";
  if (!isSafePositiveInt(hc.NanoCpus, limits.maxNanoCpus)) return "NanoCpus";
  if (hc.MemorySwap !== hc.Memory) return "MemorySwap";

  if (!Array.isArray(hc.Ulimits) || hc.Ulimits.length !== 3) return "Ulimits";
  for (let i = 0; i < 3; i++) {
    const u = hc.Ulimits[i];
    if (!sameKeys(u, ["Name", "Soft", "Hard"])) return "Ulimits";
    if (u.Name !== REQUIRED_ULIMIT_NAMES[i]) return "Ulimits";
    if (u.Name === "nproc") {
      if (u.Soft !== hc.PidsLimit || u.Hard !== hc.PidsLimit) return "Ulimits";
    } else if (u.Name === "core") {
      if (u.Soft !== 0 || u.Hard !== 0) return "Ulimits";
    } else if (u.Name === "nofile") {
      if (u.Soft !== 4096 || u.Hard !== 4096) return "Ulimits";
    }
  }

  // The bridge marks boxes as the kernel's first OOM choice; any other value is refused.
  if ("OomScoreAdj" in hc && hc.OomScoreAdj !== 500) return "OomScoreAdj";

  if (hc.StorageOpt) {
    if (!sameKeys(hc.StorageOpt, ["size"])) return "StorageOpt";
    if (!/^[1-9][0-9]{0,4}[GM]$/.test(String(hc.StorageOpt.size))) return "StorageOpt";
  }

  return null;
}

export function execShapeViolation(body) {
  if (body === null || typeof body !== "object" || Array.isArray(body)) return "not an object";

  const keys = Object.keys(body);
  if (keys.includes("User")) return "User";
  for (const k of keys) if (!ALLOWED_EXEC_KEYS.includes(k)) return "extra key";

  if (body.WorkingDir !== "/workspace") return "WorkingDir";

  if (!Array.isArray(body.Cmd) || body.Cmd.length === 0) return "Cmd";
  for (const c of body.Cmd) if (typeof c !== "string") return "Cmd";

  for (const k of ["AttachStdin", "AttachStdout", "AttachStderr", "Tty"]) {
    if (k in body && typeof body[k] !== "boolean") return k;
  }

  if ("Env" in body) {
    if (!Array.isArray(body.Env)) return "Env";
    for (const e of body.Env) {
      if (typeof e !== "string") return "Env";
      if (!/^[A-Za-z_][A-Za-z0-9_]*=/.test(e)) return "Env";
      // HOME is pinned once, in the create Env (ADR 0009): runc takes it from there for every
      // exec, whatever /etc/passwd says, so no exec may carry a different one.
      if (e.startsWith("HOME=") && e !== "HOME=/home/coder") return "Env";
    }
  }

  return null;
}