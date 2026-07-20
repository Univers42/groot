// **************************************************************************** //
//                                                                              //
//                                                         :::      ::::::::    //
//    proxy.mjs                                          :+:      :+:    :+:    //
//                                                     +:+ +:+         +:+      //
//    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         //
//                                                 +#+#+#+#+#+   +#+            //
//    Created: 2026/07/19 00:00:00 by dlesieur          #+#    #+#              //
//    Updated: 2026/07/19 00:00:00 by dlesieur         ###   ########.fr        //
//                                                                              //
// **************************************************************************** //

// osionos IDE docker-socket proxy — the ONLY way the provisioner reaches the
// isolated rootless dind daemon (devil conditions 2, 8, 9). It fronts the dind
// UNIX socket and exposes a filtered TCP endpoint that:
//   - allowlists exactly the endpoints the provisioner needs (containers/exec/
//     volumes/networks/ping) and DENIES /build, /images, /commit, /system, etc.;
//   - inspects POST /containers/create and REJECTS a body carrying Privileged,
//     host Binds/Mounts, host NetworkMode/PidMode/IpcMode/UTSMode, CapAdd, or
//     Devices — so even a compromised provisioner cannot escalate;
//   - pins every container-scoped path id to the `ide-<32hex>` shape, so an exec
//     can never target `mini-baas-postgres` or a foreign container.
// Off-the-shelf socket proxies gate endpoints but not the create BODY; that gap
// is exactly what condition 8's probe tests, hence this custom filter.

import http from "node:http";
import net from "node:net";
import { fileURLToPath } from "node:url";

const LISTEN_PORT = Number(process.env.IDE_SOCKET_PROXY_PORT || 2375);
const DOCKER_SOCK = process.env.IDE_DOCKER_SOCK || "/dind-run/docker.sock";
const ID = "ide-[0-9a-f]{32}";

// Allowed (METHOD, path-regex). Anything not listed is denied.
const ALLOW = [
  ["GET", /^\/_ping$/],
  ["GET", /^\/(v[\d.]+\/)?containers\/json(\?.*)?$/],
  ["POST", /^\/(v[\d.]+\/)?containers\/create(\?.*)?$/],
  ["GET", new RegExp(`^/(v[\\d.]+/)?containers/${ID}/json$`)],
  ["POST", new RegExp(`^/(v[\\d.]+/)?containers/${ID}/start$`)],
  ["POST", new RegExp(`^/(v[\\d.]+/)?containers/${ID}/stop(\\?.*)?$`)],
  ["POST", new RegExp(`^/(v[\\d.]+/)?containers/${ID}/exec$`)],
  ["DELETE", new RegExp(`^/(v[\\d.]+/)?containers/${ID}(\\?.*)?$`)],
  ["POST", /^\/(v[\d.]+\/)?exec\/[a-f0-9]+\/start$/],
  // PTY geometry only — resizes an already-created exec's TTY. No new
  // capability, id-pinned, docker validates w/h as ints; scoped + benign.
  ["POST", /^\/(v[\d.]+\/)?exec\/[a-f0-9]+\/resize(\?.*)?$/],
  ["GET", /^\/(v[\d.]+\/)?exec\/[a-f0-9]+\/json$/],
  ["POST", /^\/(v[\d.]+\/)?volumes\/create$/],
  ["GET", /^\/(v[\d.]+\/)?networks\/[\w.-]+$/],
];

function isAllowed(method, path) {
  return ALLOW.some(([m, re]) => m === method && re.test(path));
}

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

function deny(res, code, message) {
  res.writeHead(code, { "content-type": "application/json" });
  res.end(JSON.stringify({ message: `ide-socket-proxy: ${message}` }));
}

function forward(clientReq, clientRes, bodyBuffer) {
  const upstream = http.request(
    { socketPath: DOCKER_SOCK, method: clientReq.method, path: clientReq.url, headers: { ...clientReq.headers, host: "docker" } },
    (upRes) => { clientRes.writeHead(upRes.statusCode ?? 502, upRes.headers); upRes.pipe(clientRes); },
  );
  upstream.on("error", () => deny(clientRes, 502, "daemon unreachable"));
  if (bodyBuffer) upstream.end(bodyBuffer);
  else clientReq.pipe(upstream);
}

const server = http.createServer((req, res) => {
  const method = (req.method || "GET").toUpperCase();
  const path = req.url || "/";
  if (!isAllowed(method, path)) return deny(res, 403, `endpoint not allowed: ${method} ${path}`);

  // Create must have its body vetted before it reaches the daemon.
  if (method === "POST" && /\/containers\/create/.test(path)) {
    const chunks = [];
    let size = 0;
    req.on("data", (c) => { size += c.length; if (size > 256 * 1024) req.destroy(); chunks.push(c); });
    req.on("end", () => {
      const raw = Buffer.concat(chunks);
      let body;
      try { body = JSON.parse(raw.toString("utf8") || "{}"); } catch { return deny(res, 400, "invalid create body"); }
      const bad = unsafeCreateBody(body);
      if (bad) return deny(res, 403, `create rejected: ${bad}`);
      forward(req, res, raw);
    });
    return;
  }
  forward(req, res, null);
});

// Exec-attach hijack (PTY/LSP): docker upgrades `/exec/{id}/start` to a raw
// bidirectional stream. Only that endpoint may upgrade; pipe it to the dind
// socket both ways. Everything else already went through the filtered path.
server.on("upgrade", (req, clientSocket, head) => {
  if (!/^\/(v[\d.]+\/)?exec\/[a-f0-9]+\/start$/.test(req.url || "")) {
    clientSocket.destroy();
    return;
  }
  const headers = Object.entries(req.headers).map(([k, v]) => `${k}: ${v}`).join("\r\n");
  const upstream = net.connect(DOCKER_SOCK, () => {
    upstream.write(`${req.method} ${req.url} HTTP/1.1\r\n${headers}\r\n\r\n`);
    if (head && head.length) upstream.write(head);
    upstream.pipe(clientSocket);
    clientSocket.pipe(upstream);
  });
  upstream.on("error", () => clientSocket.destroy());
  clientSocket.on("error", () => upstream.destroy());
});

const isMain = process.argv[1] === fileURLToPath(import.meta.url);

if (isMain && process.argv.includes("--selfcheck")) {
  const fail = [];
  const chk = (label, got, want) => { if (got !== want) fail.push(`${label}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); };
  chk("allow create", isAllowed("POST", "/containers/create?name=ide-" + "a".repeat(32)), true);
  chk("allow start", isAllowed("POST", "/containers/ide-" + "a".repeat(32) + "/start"), true);
  chk("allow resize", isAllowed("POST", "/exec/deadbeef01/resize?w=120&h=40"), true);
  chk("deny foreign resize", isAllowed("POST", "/exec/../containers/x/resize"), false);
  chk("deny images", isAllowed("POST", "/images/create?fromImage=x"), false);
  chk("deny build", isAllowed("POST", "/build"), false);
  chk("deny foreign exec", isAllowed("POST", "/containers/mini-baas-postgres/exec"), false);
  chk("deny foreign start", isAllowed("POST", "/containers/mini-baas-postgres/start"), false);
  chk("privileged rejected", unsafeCreateBody({ HostConfig: { Privileged: true } }), "Privileged");
  chk("binds rejected", unsafeCreateBody({ HostConfig: { Binds: ["/:/host"] } }), "Binds");
  chk("host net rejected", unsafeCreateBody({ HostConfig: { NetworkMode: "host" } }), "NetworkMode");
  chk("capadd rejected", unsafeCreateBody({ HostConfig: { CapAdd: ["SYS_ADMIN"] } }), "CapAdd");
  chk("bind mount rejected", unsafeCreateBody({ HostConfig: { Mounts: [{ Type: "bind", Source: "/" }] } }), "bind-mount");
  chk("clean body ok", unsafeCreateBody({ HostConfig: { CapDrop: ["ALL"], Mounts: [{ Type: "volume" }] } }), null);
  if (fail.length) { process.stderr.write(`selfcheck FAIL:\n${fail.join("\n")}\n`); process.exit(1); }
  process.stdout.write("selfcheck OK: socket-proxy allow/deny + body filter correct\n");
  process.exit(0);
}

if (isMain) {
  server.listen(LISTEN_PORT, () => process.stdout.write(`[ide-socket-proxy] :${LISTEN_PORT} -> ${DOCKER_SOCK}\n`));
}
