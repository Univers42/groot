// End-to-end cases for proxy.mjs: the real proxy process in front of a fake daemon on a unix
// socket, so what the DAEMON receives is what is asserted (K12: it must be the vetted object
// re-serialized, never the client's bytes). Run from the worktree root, no real docker needed:
//   node infrastructure/docker/osionos/ide-socket-proxy/proxy.selfcheck.mjs
// The image does not ship this file; proxy.mjs --selfcheck covers the pure vetters.
//
// Caveat: the fake daemon only records bytes and answers canned JSON, so it proves what the proxy
// SENDS, not how docker decodes it; the duplicate-HostConfig divergence itself was measured on
// docker 28.1.1 (devil verdict K12), not re-run here.

import { spawn } from "node:child_process";
import http from "node:http";
import { mkdtemp, rm } from "node:fs/promises";
import net from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { CANON_PATH, DIGEST, OWNER, host, mk } from "./create-shape.selfcheck.mjs";
import { inspectRuntime, pinRuntime } from "./runtime-pin.mjs";

const PROXY = fileURLToPath(new URL("./proxy.mjs", import.meta.url));

async function freePort() {
  const probe = net.createServer();
  await new Promise((resolve) => probe.listen(0, "127.0.0.1", resolve));
  const { port } = probe.address();
  await new Promise((resolve) => probe.close(resolve));
  return port;
}

/** A stand-in daemon: records every request, answers inspect with `state.runtime`. */
async function startFakeDaemon(sock, state) {
  const seen = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => {
      seen.push({ method: req.method, url: req.url, headers: req.headers, body: Buffer.concat(chunks).toString("utf8") });
      const inspect = /\/json$/.test(req.url);
      res.writeHead(inspect ? state.inspectStatus : /\/create/.test(req.url) ? 201 : 204, {
        "content-type": "application/json",
        ...(state.responseHeaders ?? {}),
      });
      res.end(inspect ? JSON.stringify({ HostConfig: { Runtime: state.runtime } }) : "{}");
    });
  });
  await new Promise((resolve) => server.listen(sock, resolve));
  return { seen, close: () => new Promise((resolve) => server.close(resolve)) };
}

async function startProxy(dir, daemonSock, extraEnv) {
  const port = await freePort();
  const env = { PATH: process.env.PATH, IDE_SOCKET_PROXY_PORT: String(port), IDE_DOCKER_SOCK: daemonSock, IDE_UID_LEDGER: path.join(dir, `ledger-${port}.jsonl`), ...extraEnv };
  const child = spawn(process.execPath, [PROXY], { env, stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "";
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", () => {});
  for (let waited = 0; !stdout.includes(`:${port} ->`); waited += 20) {
    if (waited > 5000) throw new Error("proxy did not start");
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  const auditLines = () => stdout.split("\n").filter((line) => line.startsWith("{")).map((line) => JSON.parse(line));
  return { port, auditLines, stop: () => { child.kill(); } };
}

function send(port, method, urlPath, bodyText, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port, method, path: urlPath, headers }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => resolve({ status: res.statusCode, text: Buffer.concat(chunks).toString("utf8"), headers: res.headers }));
    });
    req.on("error", reject);
    if (bodyText !== undefined) req.write(bodyText);
    req.end();
  });
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 50));

/** The canonical body with one raw prefix spliced in, so the text carries a repeated key that
 *  JSON.parse resolves to the canonical (last) value. */
const withPrefix = (prefix) => JSON.stringify(mk()).replace(/^\{/, `{${prefix},`);
const withinHostConfig = (prefix) => JSON.stringify(mk()).replace('"HostConfig":{', `"HostConfig":{${prefix},`);

async function bytesForwardedAreVetted(proxy, daemon, chk) {
  const pretty = JSON.stringify(mk(), null, 2);
  const res = await send(proxy.port, "POST", CANON_PATH, pretty, {
    "content-type": "application/json",
    "x-untrusted-header": "must-not-reach-daemon",
  });
  await settle();
  const got = daemon.seen.at(-1);
  chk("canonical pretty-printed create answered 201", res.status, 201);
  chk("forwarded bytes == JSON.stringify(vetted)", got?.body, JSON.stringify(mk()));
  chk("content-length recomputed", got?.headers["content-length"], String(Buffer.byteLength(JSON.stringify(mk()))));
  chk("no transfer-encoding upstream", got?.headers["transfer-encoding"], undefined);
  chk("required content-type retained", got?.headers["content-type"], "application/json");
  chk("untrusted request header dropped", got?.headers["x-untrusted-header"], undefined);
}

async function daemonRedirectHeadersAreDropped(proxy, state, chk) {
  Object.assign(state, {
    responseHeaders: {
      location: "https://attacker.example/redirect",
      refresh: "0;url=https://attacker.example/",
      "x-docker-size": "1024",
    },
  });
  const response = await send(proxy.port, "GET", `${BOX}/json`);
  chk("daemon Location header is not proxied", response.headers.location, undefined);
  chk("daemon Refresh header is not proxied", response.headers.refresh, undefined);
  chk("documented Docker response header retained", response.headers["x-docker-size"], "1024");
  state.responseHeaders = {};
}

async function traversalNamesNeverReachDaemon(sock, daemon, chk) {
  const before = daemon.seen.length;
  const got = await inspectRuntime(sock, `../${DIGEST}/../../../etc/passwd`);
  await settle();
  chk("runtime inspect refuses a traversal name", got, null);
  chk("runtime traversal never reaches daemon", daemon.seen.length, before);
}

async function repeatedKeysAreRefused(proxy, daemon, chk) {
  const cases = [
    ["duplicated HostConfig (privileged copy first)", withPrefix('"HostConfig":{"Privileged":true,"Binds":["/:/host"],"PidMode":"host"}')],
    ["duplicated HostConfig (privileged copy last)", JSON.stringify(mk()).replace(/\}$/, ',"HostConfig":{"Privileged":true}}')],
    ["duplicated Privileged inside HostConfig", withinHostConfig('"Privileged":true,"Privileged":false')],
    ["duplicated top-level Image", withPrefix('"Image":"evil/escape:latest"')],
    ["HostConfig repeated by escape spelling", withPrefix('"Host\\u0043onfig":{"Privileged":true}')],
    ["HostConfig repeated in another case", withPrefix('"hostconfig":{"Privileged":true}')],
  ];
  const before = daemon.seen.length;
  for (const [label, text] of cases) {
    const res = await send(proxy.port, "POST", CANON_PATH, text);
    chk(`${label}: refused 400`, res.status, 400);
  }
  await settle();
  chk("nothing repeated reached the daemon", daemon.seen.length, before);
}

const BOX = `/containers/ide-${DIGEST}`;
const startsSeen = (daemon) => daemon.seen.filter((r) => r.method === "POST" && r.url.endsWith("/start")).length;
const inspectsSeen = (daemon) => daemon.seen.filter((r) => r.method === "GET").length;

async function unsetPlaneKeepsToday(proxy, daemon, chk) {
  const refused = await send(proxy.port, "POST", CANON_PATH, JSON.stringify(host({ Runtime: "runsc" })));
  chk("unset: Runtime in the create is refused", refused.status, 403);
  await send(proxy.port, "POST", CANON_PATH, JSON.stringify(mk()));
  await settle();
  chk("unset: no Runtime is added to the create", daemon.seen.at(-1).body.includes("Runtime"), false);
  const started = await send(proxy.port, "POST", `${BOX}/start`);
  chk("unset: start answered by the daemon", started.status, 204);
  chk("unset: start is not inspected", inspectsSeen(daemon), 0);
}

async function pinnedPlaneAssertsRuntime(proxy, daemon, state, chk) {
  await send(proxy.port, "POST", CANON_PATH, JSON.stringify(mk()));
  await settle();
  chk("pinned: Runtime written into the forwarded create", daemon.seen.at(-1).body, JSON.stringify({ ...mk(), HostConfig: { ...mk().HostConfig, Runtime: "runsc" } }));
  chk("pinned: a pids limit below the gVisor floor is raised to it", pinRuntime({ HostConfig: { PidsLimit: 16 } }, "runsc").HostConfig.PidsLimit, 64);
  chk("pinned: a pids limit at or above the floor is left alone", pinRuntime({ HostConfig: { PidsLimit: 512 } }, "runsc").HostConfig.PidsLimit, 512);
  chk("pinned: a body with no pids limit gets none", "PidsLimit" in pinRuntime({ HostConfig: {} }, "runsc").HostConfig, false);
  chk("pinned: Runtime runsc from the client ok", (await send(proxy.port, "POST", CANON_PATH, JSON.stringify(host({ Runtime: "runsc" })))).status, 201);
  chk("pinned: Runtime runc from the client refused", (await send(proxy.port, "POST", CANON_PATH, JSON.stringify(host({ Runtime: "runc" })))).status, 403);
  chk("pinned: empty Runtime from the client refused", (await send(proxy.port, "POST", CANON_PATH, JSON.stringify(host({ Runtime: "" })))).status, 403);

  const starts = startsSeen(daemon);
  for (const [label, runtime, inspectStatus, want] of [["runsc", "runsc", 200, 204], ["runc", "runc", 200, 403], ["empty", "", 200, 403], ["inspect failing", "runsc", 500, 403]]) {
    Object.assign(state, { runtime, inspectStatus });
    chk(`pinned: start of a ${label} box`, (await send(proxy.port, "POST", `${BOX}/start`)).status, want);
  }
  chk("pinned: only the matching start reached the daemon", startsSeen(daemon) - starts, 1);
  Object.assign(state, { runtime: "runc", inspectStatus: 200 });
  chk("pinned: an init container is gated the same way", (await send(proxy.port, "POST", `/containers/ideinit-${DIGEST}/start`)).status, 403);
}

async function auditLinesAreWritten(proxy, chk) {
  const headers = { "x-ide-reason": "open-workspace" };
  const earlier = proxy.auditLines().length;
  await send(proxy.port, "POST", CANON_PATH, JSON.stringify(mk()), headers);
  await send(proxy.port, "POST", `${BOX}/start`, undefined, headers);
  await send(proxy.port, "POST", `${BOX}/stop?t=5`, undefined, { "x-ide-reason": "Bad Reason!" });
  await send(proxy.port, "DELETE", `${BOX}?force=true`);
  await send(proxy.port, "GET", `${BOX}/json`);
  await settle();
  const lines = proxy.auditLines().slice(earlier);
  chk("audit: one line per create/start/stop/remove, none for a read", lines.map((l) => l.op).join(","), "create,start,stop,remove");
  chk("audit: box digest", lines.every((l) => l.box === DIGEST), true);
  chk("audit: uid from the create", lines.map((l) => l.uid).join(","), "20000,20000,20000,20000");
  chk("audit: asserted reason kept", lines[0].reason, "open-workspace");
  chk("audit: malformed reason replaced", lines[2].reason, "unspecified");
  chk("audit: daemon status recorded", lines.map((l) => l.status).join(","), "201,204,204,204");
  const text = JSON.stringify(lines);
  chk("audit: no env value, owner or label in a line", ["HTTP_PROXY", "ide-egress", OWNER, "osio.ide"].some((secret) => text.includes(secret)), false);
  chk("audit: ts is ISO", /^\d{4}-\d\d-\d\dT[\d:.]+Z$/.test(lines[0].ts), true);
}

async function refusedStartIsAudited(proxy, chk) {
  const last = proxy.auditLines().at(-1);
  chk("audit: runtime refusal logged", `${last.op} ${last.reason} ${last.status}`, "start runtime-mismatch 403");
}

export async function proxyFailures() {
  const fail = [];
  const chk = (label, got, want) => { if (got !== want) fail.push(`${label}: got ${JSON.stringify(got).slice(0, 160)}, want ${JSON.stringify(want).slice(0, 160)}`); };
  const dir = await mkdtemp(path.join(tmpdir(), "ide-proxy-selfcheck-"));
  const sock = path.join(dir, "docker.sock");
  const state = { runtime: "", inspectStatus: 200 };
  const daemon = await startFakeDaemon(sock, state);
  const plain = await startProxy(dir, sock, {});
  const pinned = await startProxy(dir, sock, { OSIONOS_IDE_REQUIRE_RUNTIME: "runsc" });
  try {
    await traversalNamesNeverReachDaemon(sock, daemon, chk);
    await bytesForwardedAreVetted(plain, daemon, chk);
    await daemonRedirectHeadersAreDropped(plain, state, chk);
    await repeatedKeysAreRefused(plain, daemon, chk);
    await unsetPlaneKeepsToday(plain, daemon, chk);
    await pinnedPlaneAssertsRuntime(pinned, daemon, state, chk);
    await refusedStartIsAudited(pinned, chk);
    await auditLinesAreWritten(plain, chk);
  } finally {
    plain.stop();
    pinned.stop();
    await daemon.close();
    await rm(dir, { recursive: true, force: true });
  }
  return fail;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const fail = await proxyFailures();
  if (fail.length) { process.stderr.write(`proxy selfcheck FAIL:\n${fail.join("\n")}\n`); process.exit(1); }
  process.stdout.write("proxy selfcheck OK: vetted bytes only, repeated keys refused, runtime pinned, audit lines written\n");
}
