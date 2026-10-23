// Second layer UNDER the create shape: names the escalation a drifted spec would carry
// (Privileged, host Binds/Mounts, host namespaces, CapAdd, Devices). No I/O, no deps.

/** Reject a create body that would escalate out of the sandbox (condition 8). */
export function unsafeCreateBody(body) {
  const host = body?.HostConfig ?? {};
  if (host.Privileged === true) return "Privileged";
  if (Array.isArray(host.Binds) && host.Binds.length) return "Binds";
  if (Array.isArray(host.CapAdd) && host.CapAdd.length) return "CapAdd";
  if (Array.isArray(host.Devices) && host.Devices.length) return "Devices";
  if (/^(host|container:)/.test(String(host.NetworkMode ?? ""))) return "NetworkMode";
  if (["host"].includes(String(host.PidMode ?? ""))) return "PidMode";
  if (["host"].includes(String(host.IpcMode ?? ""))) return "IpcMode";
  if (["host"].includes(String(host.UTSMode ?? ""))) return "UTSMode";
  if (host.UsernsMode === "host") return "UsernsMode";
  if (Array.isArray(host.Mounts) && host.Mounts.some((m) => m?.Type === "bind")) return "bind-mount";
  if (Array.isArray(host.SecurityOpt) && host.SecurityOpt.some((o) => /seccomp=unconfined|apparmor=unconfined|systempaths=unconfined/i.test(String(o)))) return "SecurityOpt";
  return null;
}
