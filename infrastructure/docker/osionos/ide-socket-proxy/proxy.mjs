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
//   - matches the POST /containers/create and POST /containers/<id>/exec BODIES
//     against the bridge's own shape (create-shape.mjs): only the fields the
//     spec builders emit are accepted, every other shape gets a reason back;
//   - keeps the escalation denylist (Privileged, host Binds/Mounts, host
//     NetworkMode/PidMode/IpcMode/UTSMode, CapAdd, Devices) as a second layer
//     UNDER that shape check, so a spec that drifts is still covered;
//   - pins every container-scoped path id to the `ide-<32hex>` shape, so an exec
//     can never target `mini-baas-postgres` or a foreign container.
// Off-the-shelf socket proxies gate endpoints but not the create BODY; that gap
// is exactly what condition 8's probe tests, hence this custom filter.

import http from "node:http";
import net from "node:net";
import { fileURLToPath } from "node:url";
import { createShapeViolation, execShapeViolation, shapeLimits } from "./create-shape.mjs";
import { INIT_PATH_RE, initShapeViolation } from "./init-shape.mjs";
import { createLedger } from "./uid-ledger.mjs";
import { UID_PATH, handleUidRequest } from "./uid-endpoint.mjs";

const LISTEN_PORT = Number(process.env.IDE_SOCKET_PROXY_PORT || 2375);
const DOCKER_SOCK = process.env.IDE_DOCKER_SOCK || "/dind-run/docker.sock";
const ID = "ide-[0-9a-f]{32}";
// Volume-ownership init containers get create, start, wait, json and DELETE, and nothing else:
// no exec, attach or upgrade route names them (ADR 0011).
const INIT_ID = "ideinit-[0-9a-f]{32}";
const EXEC_PATH = new RegExp(`^/(v[\\d.]+/)?containers/${ID}/exec$`);
const VOLUME_NAME_RE = /^osio-ide-(vol|home)-[0-9a-f]{32}$/;
const MANAGED_LABEL = "osio.ide.managed";
const LIMITS = shapeLimits(process.env);
const ledger = createLedger({ file: process.env.IDE_UID_LEDGER || "/ledger/uid-ledger.jsonl" });

// Allowed (METHOD, path-regex). Anything not listed is denied.
const ALLOW = [
  ["GET", /^\/_ping$/],
  ["GET", /^\/(v[\d.]+\/)?containers\/json(\?.*)?$/],
  ["POST", /^\/(v[\d.]+\/)?containers\/create\?name=ide(init)?-[0-9a-f]{32}$/],
  ["POST", new RegExp(`^/(v[\\d.]+/)?containers/${INIT_ID}/start$`)],
  ["POST", new RegExp(`^/(v[\\d.]+/)?containers/${INIT_ID}/wait(\\?.*)?$`)],
  ["GET", new RegExp(`^/(v[\\d.]+/)?containers/${INIT_ID}/json$`)],
  ["DELETE", new RegExp(`^/(v[\\d.]+/)?containers/${INIT_ID}(\\?.*)?$`)],
  ["POST", new RegExp(`^${UID_PATH}$`)],
  ["GET", new RegExp(`^/(v[\\d.]+/)?containers/${ID}/json$`)],
  ["POST", new RegExp(`^/(v[\\d.]+/)?containers/${ID}/start$`)],
  ["POST", new RegExp(`^/(v[\\d.]+/)?containers/${ID}/stop(\\?.*)?$`)],
  ["POST", EXEC_PATH],
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
  const driver = String(body?.Driver ?? "local");
  if (driver !== "local") return "Driver";
  const opts = body?.DriverOpts;
  if (opts && typeof opts === "object" && Object.keys(opts).length) return "DriverOpts";
  if (!VOLUME_NAME_RE.test(String(body?.Name ?? ""))) return "Name";
  if (!isManagedLabels(body?.Labels)) return "Labels";
  return null;
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

/** A container create, box or init by its name: the shape first (the box shape is also run
 *  through the escalation denylist, the init shape is the one that may carry capabilities), then
 *  the ledger. Resolves to a refusal reason or null. */
export async function vetCreateBody(body, path, boundLedger = ledger) {
  const isInit = INIT_PATH_RE.test(path);
  const bad = isInit ? initShapeViolation(body, path, LIMITS) : createShapeViolation(body, path, LIMITS) ?? unsafeCreateBody(body);
  if (bad) return bad;
  return boundLedger.admit(body.Labels["osio.ide.owner"], Number(body.Labels["osio.ide.uid"]));
}

/** The body vetter for a POST endpoint, or null when the endpoint carries no body risk.
 *  A create body must match the bridge's shape FIRST, then survive the escalation
 *  denylist — the two cover different directions, so both run. */
function bodyVetter(path) {
  if (/\/containers\/create/.test(path)) {
    return (body) => vetCreateBody(body, path);
  }
  if (EXEC_PATH.test(path)) return execShapeViolation;
  if (/\/volumes\/create$/.test(path)) return unsafeVolumeBody;
  if (/\/networks\/create$/.test(path)) return unsafeNetworkBody;
  return null;
}

// Ponytail: the 2 MiB exec ceiling is a guess at the largest base64 file write
// (the bridge caps its own request body at 1 MiB, so a write larger than this is
// refused with 413) and the 256 KiB create ceiling predates it; both move by hand.
function bodyCap(path) {
  return EXEC_PATH.test(path) ? 2 * 1024 * 1024 : 256 * 1024;
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

/** Buffer a vetted body, refuse an oversized one with a status the client can read.
 *  Over the cap the request is drained instead of destroyed — a destroyed request
 *  takes the socket with it and leaves the caller waiting with no answer. */
function vetBody(req, res, vet, cap) {
  const chunks = [];
  let size = 0;
  let over = false;
  req.on("data", (c) => {
    size += c.length;
    if (size > cap) { over = true; chunks.length = 0; return; }
    chunks.push(c);
  });
  req.on("end", () => {
    if (over) return deny(res, 413, "body too large");
    const raw = Buffer.concat(chunks);
    let body;
    try { body = JSON.parse(raw.toString("utf8") || "{}"); } catch { return deny(res, 400, "invalid create body"); }
    // A vetter may be async (the ledger); a throw is a refusal, never a pass. The trailing
    // catch matters: an unhandled rejection (deny on a response already answered) would
    // kill the proxy, and with it every user's IDE.
    void (async () => {
      let bad;
      try { bad = await vet(body); } catch { bad = "vetter failed"; }
      if (bad) return deny(res, 403, `create rejected: ${bad}`);
      forward(req, res, raw);
    })().catch((error) => {
      process.stderr.write(`[ide-socket-proxy] vet/forward failed: ${error?.code ?? error?.message ?? "error"}\n`);
      if (!res.headersSent) deny(res, 502, "proxy error");
      else res.destroy();
    });
  });
}

const server = http.createServer((req, res) => {
  const method = (req.method || "GET").toUpperCase();
  const path = req.url || "/";
  if (!isAllowed(method, path)) return deny(res, 403, `endpoint not allowed: ${method} ${path}`);

  if (path === UID_PATH) return handleUidRequest(req, res, ledger);

  // Every create (container, volume, network) and every exec create has its body
  // vetted before it reaches the daemon.
  const vet = method === "POST" ? bodyVetter(path) : null;
  if (vet) return vetBody(req, res, vet, bodyCap(path));
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
  const refuse = (label, got) => { if (got === null) fail.push(`${label}: accepted, want a refusal reason`); };

  // The canonical bridge body and its one-field variants live with the shape cases.
  const { DIGEST, CANON_PATH, host, shapeFailures } = await import("./create-shape.selfcheck.mjs");
  fail.push(...shapeFailures());
  fail.push(...await (await import("./uid-ledger.selfcheck.mjs")).ledgerFailures(vetCreateBody));
  const INIT = `ideinit-${DIGEST}`;
  for (const [method, route, want] of [
    ["POST", `/containers/create?name=${INIT}`, true], ["POST", `/containers/${INIT}/start`, true],
    ["POST", `/containers/${INIT}/wait?condition=not-running`, true], ["GET", `/containers/${INIT}/json`, true],
    ["DELETE", `/containers/${INIT}?force=true&v=false`, true], ["POST", UID_PATH, true],
    ["POST", `/containers/${INIT}/exec`, false], ["POST", `/containers/${INIT}/attach`, false],
    ["POST", `/containers/${INIT}/stop`, false], ["POST", `/containers/${INIT}/archive`, false],
    ["GET", UID_PATH, false], ["POST", `/v1.47/osio/v1/uid`, false], ["POST", "/containers/ideinit-short/start", false],
    ["POST", `/containers/ideinit-${"G".repeat(32)}/start`, false],
  ]) chk(`${method} ${route.replace(DIGEST, "<digest>")} allowed`, isAllowed(method, route), want);
  chk("the upgrade path stays exec-only", /^\/(v[\d.]+\/)?exec\/[a-f0-9]+\/start$/.test(`/containers/${INIT}/attach`), false);

  chk("allow create", isAllowed("POST", "/containers/create?name=ide-" + "a".repeat(32)), true);
  chk("allow start", isAllowed("POST", "/containers/ide-" + "a".repeat(32) + "/start"), true);
  chk("allow resize", isAllowed("POST", "/exec/deadbeef01/resize?w=120&h=40"), true);
  chk("deny foreign resize", isAllowed("POST", "/exec/../containers/x/resize"), false);
  chk("deny images", isAllowed("POST", "/images/create?fromImage=x"), false);
  chk("deny build", isAllowed("POST", "/build"), false);
  chk("deny foreign exec", isAllowed("POST", "/containers/mini-baas-postgres/exec"), false);
  chk("deny foreign start", isAllowed("POST", "/containers/mini-baas-postgres/start"), false);
  chk("deny create without name", isAllowed("POST", "/containers/create"), false);
  chk("deny create with short name", isAllowed("POST", "/containers/create?name=x"), false);
  chk("privileged rejected", unsafeCreateBody({ HostConfig: { Privileged: true } }), "Privileged");
  chk("binds rejected", unsafeCreateBody({ HostConfig: { Binds: ["/:/host"] } }), "Binds");
  chk("host net rejected", unsafeCreateBody({ HostConfig: { NetworkMode: "host" } }), "NetworkMode");
  chk("capadd rejected", unsafeCreateBody({ HostConfig: { CapAdd: ["SYS_ADMIN"] } }), "CapAdd");
  chk("bind mount rejected", unsafeCreateBody({ HostConfig: { Mounts: [{ Type: "bind", Source: "/" }] } }), "bind-mount");
  chk("clean body ok", unsafeCreateBody({ HostConfig: { CapDrop: ["ALL"], Mounts: [{ Type: "volume" }] } }), null);
  chk("host-bind volume rejected", unsafeVolumeBody({ Name: "x", Driver: "local", DriverOpts: { type: "none", o: "bind", device: "/" } }), "DriverOpts");
  chk("foreign volume driver rejected", unsafeVolumeBody({ Name: "x", Driver: "vieux/sshfs" }), "Driver");
  chk("provisioner home volume ok", unsafeVolumeBody({ Name: `osio-ide-home-${DIGEST}`, Driver: "local", Labels: { [MANAGED_LABEL]: "1" } }), null);
  chk("home volume DriverOpts refused", unsafeVolumeBody({ Name: `osio-ide-home-${DIGEST}`, Driver: "local", Labels: { [MANAGED_LABEL]: "1" }, DriverOpts: { type: "none", o: "bind", device: "/" } }), "DriverOpts");
  chk("other volume prefix refused", unsafeVolumeBody({ Name: `osio-ide-data-${DIGEST}`, Driver: "local", Labels: { [MANAGED_LABEL]: "1" } }), "Name");
  chk("provisioner volume ok", unsafeVolumeBody({ Name: `osio-ide-vol-${DIGEST}`, Driver: "local", Labels: { [MANAGED_LABEL]: "1" } }), null);
  chk("unmanaged volume name rejected", unsafeVolumeBody({ Name: "other", Driver: "local" }), "Name");
  chk("empty volume labels rejected", unsafeVolumeBody({ Name: `osio-ide-vol-${DIGEST}`, Driver: "local", Labels: {} }), "Labels");
  chk("macvlan network rejected", unsafeNetworkBody({ Name: "x", Driver: "macvlan" }), "Driver");
  chk("provisioner network ok", unsafeNetworkBody({ Name: "ide-net", Driver: "bridge", Internal: true }), null);
  chk("volume create is vetted", bodyVetter("/v1.47/volumes/create") === unsafeVolumeBody, true);
  chk("network create is vetted", bodyVetter("/networks/create") === unsafeNetworkBody, true);
  refuse("create vetter refuses Privileged", await bodyVetter(CANON_PATH)(host({ Privileged: true })));
  chk("create vetter wraps vetCreateBody", await bodyVetter(CANON_PATH)(host({ Privileged: true })), await vetCreateBody(host({ Privileged: true }), CANON_PATH));
  chk("exec create is vetted", bodyVetter(`/containers/ide-${DIGEST}/exec`)({ User: "20000:10001" }), "User");

  if (fail.length) { process.stderr.write(`selfcheck FAIL:\n${fail.join("\n")}\n`); process.exit(1); }
  process.stdout.write("selfcheck OK: socket-proxy allow/deny + body filter correct\n");
  process.exit(0);
}

if (isMain) {
  await ledger.ready();
  server.listen(LISTEN_PORT, () => process.stdout.write(`[ide-socket-proxy] :${LISTEN_PORT} -> ${DOCKER_SOCK}\n`));
}
