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
const INSPECT_TIMEOUT_MS = 3000;

/** The body with HostConfig.Runtime set to the required runtime. Call after the shape check. */
export function pinRuntime(body, runtime) {
  return { ...body, HostConfig: { ...body.HostConfig, Runtime: runtime } };
}

/** HostConfig.Runtime of the named container as the daemon reports it, or null when unknown. */
export function inspectRuntime(socketPath, name) {
  return new Promise((resolve) => {
    const req = http.get({ socketPath, path: `/containers/${name}/json`, timeout: INSPECT_TIMEOUT_MS, headers: { host: "docker" } }, (res) => {
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
