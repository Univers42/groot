// The runtime the plane insists on (devil K11/R1). With OSIONOS_IDE_REQUIRE_RUNTIME set (for
// example `runsc` for gVisor) the proxy writes that runtime into every container create it
// forwards, and refuses to start a container whose inspected HostConfig.Runtime differs, so a
// daemon whose default-runtime silently fell back to runc cannot run a box. Unset, nothing here
// is used and the plane behaves as before.
//
// Caveat: the start gate reads what the daemon reports for the container; it cannot tell whether
// the named runtime is really sandboxing (a `runsc` entry that points at runc passes). verify.sh
// probes /proc/version inside a box for that. An inspect that fails or times out refuses the start.

import http from "node:http";

export const START_PATH_RE = /^\/(?:v[\d.]+\/)?containers\/(ide(?:init)?-[0-9a-f]{32})\/start$/;
const MANAGED_CONTAINER_NAME_RE = /^(?:ide|ideinit)-[0-9a-f]{32}$/;
const INSPECT_TIMEOUT_MS = 3000;

// gVisor's sentry threads count against the container's pids cgroup: `true` needs a limit of 32 and
// osio-volume-init 40 (measured 2026-10-18, runsc 20261012.0, systrap; 24 and 28 fail with "cannot read
// client sync file"). The app's init asks for 16, so every first box would fail under runsc.
// Caveat: 64 is the measured need plus headroom for the init, not a bound derived from runsc; a heavier
// init needs a higher floor. The box's own 512 is untouched.
export const MIN_PIDS_UNDER_RUNTIME = 64;

/** The body with HostConfig.Runtime set to the required runtime and a pids limit the sentry can live in. Call after the shape check. */
export function pinRuntime(body, runtime) {
  const pids = body.HostConfig?.PidsLimit;
  const floor = Number.isInteger(pids) && pids < MIN_PIDS_UNDER_RUNTIME ? { PidsLimit: MIN_PIDS_UNDER_RUNTIME } : {};
  return { ...body, HostConfig: { ...body.HostConfig, ...floor, Runtime: runtime } };
}

/** HostConfig.Runtime of the named container as the daemon reports it, or null when unknown. */
export function inspectRuntime(socketPath, name) {
  // Validate before interpolating into a URL path; encoding is defense in depth,
  // while the allowlist excludes separators and dot segments entirely.
  if (typeof name !== "string" || !MANAGED_CONTAINER_NAME_RE.test(name)) return Promise.resolve(null);
  const safeName = encodeURIComponent(name);
  return new Promise((resolve) => {
    const req = http.get({ socketPath, path: `/containers/${safeName}/json`, timeout: INSPECT_TIMEOUT_MS, headers: { host: "docker" } }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("close", () => resolve(null));
      res.on("end", () => {
        try { resolve(res.statusCode === 200 ? JSON.parse(Buffer.concat(chunks).toString("utf8"))?.HostConfig?.Runtime ?? null : null); } catch { resolve(null); }
      });
    });
    req.on("timeout", () => req.destroy());
    req.on("error", () => resolve(null));
  });
}
