// Volume and network create vetters for the IDE socket proxy (condition 8): the provisioner only
// ever sends a managed local volume and a bridge network, so anything else is the host-filesystem
// or physical-network escape this filter exists to stop. No I/O, no deps.

const MANAGED_LABEL = "osio.ide.managed";
const VOLUME_NAME_RE = /^osio-ide-(vol|home)-[0-9a-f]{32}$/;
// Exact-case closed set: the daemon matches JSON keys case-insensitively, so `driveropts` would
// reach DriverOpts without ever being read by the checks below.
const VOLUME_KEYS = ["Name", "Driver", "Labels", "DriverOpts"];

/** Reject a volume create that could reach the host filesystem (condition 8).
 *  `/volumes/create` was allowlisted with NO body inspection, and unsafeCreateBody only
 *  rejects `Mounts[].Type === "bind"` — so a `local` volume created with
 *  `DriverOpts {type:none, o:bind, device:/}` and then mounted as `Type:"volume"` bound
 *  the daemon host's filesystem into a sandbox. The provisioner only ever sends
 *  `{Name, Driver:"local", Labels}`, so any driver option or other driver is refused.
 *  Name and Labels are pinned to the bridge's own shape too: `osio-ide-vol-<32hex>`
 *  (workspace, digest shared with the container) or `osio-ide-home-<32hex>` (per user), and exactly the managed label —
 *  otherwise a second volume carrying someone else's identity could be mounted. */
export function unsafeVolumeBody(body) {
  if (!Object.keys(body ?? {}).every((key) => VOLUME_KEYS.includes(key))) return "keys";
  const driver = String(body?.Driver ?? "local");
  if (driver !== "local") return "Driver";
  if (!isAllowedDriverOpts(String(body?.Name ?? ""), body?.DriverOpts)) return "DriverOpts";
  if (!VOLUME_NAME_RE.test(String(body?.Name ?? ""))) return "Name";
  if (!isManagedLabels(body?.Labels)) return "Labels";
  return null;
}

/** Size quotas (OSIONOS_IDE_VOLUME_QUOTA, ADR 0011 follow-up): DriverOpts are admitted only when absent
 *  or exactly the one literal for the volume's prefix. Any other key (type, o, device) or size is the
 *  host-bind escape this filter exists to stop, so it compares the key array and the literal, never a
 *  pattern. Caveat: the local driver ignores `size` unless the volume directory sits on xfs+pquota; the
 *  filter proves what the bridge may ask for, not that the daemon enforces it. */
const VOLUME_SIZE_BY_PREFIX = [["osio-ide-home-", "2G"], ["osio-ide-vol-", "5G"]];
function isAllowedDriverOpts(name, opts) {
  if (opts === undefined || opts === null) return true;
  if (typeof opts !== "object" || Array.isArray(opts)) return false;
  const keys = Object.keys(opts);
  if (keys.length === 0) return true;
  const expected = VOLUME_SIZE_BY_PREFIX.find(([prefix]) => name.startsWith(prefix))?.[1];
  return keys.length === 1 && keys[0] === "size" && expected !== undefined && opts.size === expected;
}

/** Labels must be exactly the one managed key — compared as a key array, never by
 *  copying body keys onto an object. */
function isManagedLabels(labels) {
  const keys = Object.keys(labels ?? {});
  return keys.length === 1 && keys[0] === MANAGED_LABEL && labels[MANAGED_LABEL] === "1";
}

/** Reject a network create that leaves the isolated bridge model (condition 8).
 *  macvlan/ipvlan/host attach a sandbox to the physical network; the provisioner only
 *  ever creates `Driver:"bridge"` networks. */
export function unsafeNetworkBody(body) {
  if (String(body?.Driver ?? "bridge") !== "bridge") return "Driver";
  if (body?.ConfigFrom) return "ConfigFrom";
  return null;
}

