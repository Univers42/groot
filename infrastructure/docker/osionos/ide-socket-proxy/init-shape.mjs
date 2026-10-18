// The one create shape that carries capabilities: `ideinit-<digest>`, a root container that
// sets a volume root to <uid>:10001 700 before the box mounts it (ADR 0011, verdict A3). Pure
// validator, no I/O. It is not a variation of the box shape and shares none of its denylist:
// the box shape refuses CapAdd outright, this one demands exactly three.
//
// Why the pinned sandbox image at the real targets (verdict F1/F3): Docker copies the image
// directory into an empty volume on first mount and resets its root to 10001:10001 755. An init
// from another image at another path would be undone by the box's first mount. DAC_READ_SEARCH
// lets chown -R walk the 0700 directories a previous uid left behind (verdict E3/E3b).

import {
  BOX_GID, LABEL_UID, deepEqualJson, digestFor, homeVolumeFor, isUuidLike, parseBoxUid, sameKeys,
} from "./create-shape.mjs";

export const INIT_PATH_RE = /^\/(?:v[\d.]+\/)?containers\/create\?name=ideinit-([0-9a-f]{32})$/;
const INIT_REQUIRED_LABELS = ["osio.ide.managed", "osio.ide.owner", "osio.ide.workspace", LABEL_UID];
const INIT_HOST_CONFIG = [
  "NetworkMode", "CapDrop", "CapAdd", "SecurityOpt", "ReadonlyRootfs", "Mounts", "PidsLimit", "Memory", "MemorySwap", "RestartPolicy",
];
const MOUNT_KEYS = ["Type", "Source", "Target"];
const MAX_INIT_PIDS = 16;
const MAX_INIT_MEMORY = 128 * 1024 * 1024;

/** The uid a well-formed init body asks for, or null. User is "0:0"; the uid rides Env and the label. */
function initUid(body) {
  const match = Array.isArray(body.Env) && body.Env.length === 1 ? /^OSIO_UID=([2-5][0-9]{4})$/.exec(body.Env[0]) : null;
  return match ? parseBoxUid(`${match[1]}:${BOX_GID}`) : null;
}

export function initShapeViolation(body, path, limits) {
  const match = path.match(INIT_PATH_RE);
  if (!match) return "name";
  const digest = match[1];

  const topKeys = body && typeof body === "object" && !Array.isArray(body) ? Object.keys(body) : [];
  const required = ["Image", "User", "Entrypoint", "Env", "Labels", "HostConfig"];
  const allowed = [...required, "Cmd"];
  if (!required.every((k) => topKeys.includes(k)) || !topKeys.every((k) => allowed.includes(k))) return "top-level keys";

  if (body.Image !== limits.image) return "Image";
  if (body.User !== "0:0") return "User";
  if (!deepEqualJson(body.Entrypoint, ["/usr/local/sbin/osio-volume-init"])) return "Entrypoint";
  if ("Cmd" in body && !deepEqualJson(body.Cmd, [])) return "Cmd";

  const uid = initUid(body);
  if (uid === null) return "Env";

  if (!sameKeys(body.Labels, INIT_REQUIRED_LABELS)) return "Labels";
  if (body.Labels["osio.ide.managed"] !== "1") return "Labels";
  if (!isUuidLike(body.Labels["osio.ide.owner"]) || !isUuidLike(body.Labels["osio.ide.workspace"])) return "Labels";
  if (body.Labels[LABEL_UID] !== String(uid)) return "Labels";
  if (digestFor(body.Labels["osio.ide.owner"], body.Labels["osio.ide.workspace"]) !== digest) return "name";

  const hc = body.HostConfig;
  if (!sameKeys(hc, INIT_HOST_CONFIG)) return "HostConfig keys";
  if (hc.NetworkMode !== "none") return "NetworkMode";
  if (!deepEqualJson(hc.CapDrop, ["ALL"])) return "CapDrop";
  if (!deepEqualJson(hc.CapAdd, ["CHOWN", "DAC_READ_SEARCH", "FOWNER"])) return "CapAdd";
  if (!deepEqualJson(hc.SecurityOpt, ["no-new-privileges:true"])) return "SecurityOpt";
  if (hc.ReadonlyRootfs !== true) return "ReadonlyRootfs";
  if (!deepEqualJson(hc.RestartPolicy, { Name: "no" })) return "RestartPolicy";
  if (!Number.isInteger(hc.PidsLimit) || hc.PidsLimit < 1 || hc.PidsLimit > MAX_INIT_PIDS) return "PidsLimit";
  if (!Number.isInteger(hc.Memory) || hc.Memory < 1 || hc.Memory > MAX_INIT_MEMORY) return "Memory";
  if (hc.MemorySwap !== hc.Memory) return "MemorySwap";

  // No VolumeOptions on either mount: the copy-up must run here (verdict F2).
  const expected = [
    { Type: "volume", Source: `osio-ide-vol-${digest}`, Target: "/workspace" },
    { Type: "volume", Source: homeVolumeFor(body.Labels["osio.ide.owner"]), Target: "/home/coder" },
  ];
  if (!Array.isArray(hc.Mounts) || hc.Mounts.length !== 2) return "Mounts";
  for (let i = 0; i < 2; i++) {
    if (!sameKeys(hc.Mounts[i], MOUNT_KEYS) || !deepEqualJson(hc.Mounts[i], expected[i])) return "Mounts";
  }
  return null;
}
