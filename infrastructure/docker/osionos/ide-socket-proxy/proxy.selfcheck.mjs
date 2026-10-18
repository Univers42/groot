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
import { CANON_PATH, DIGEST, mk } from "./create-shape.selfcheck.mjs";

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
      res.writeHead(/\/json$/.test(req.url) ? 200 : /\/create/.test(req.url) ? 201 : 204, { "content-type": "application/json" });
      res.end(/\/json$/.test(req.url) ? JSON.stringify({ HostConfig: { Runtime: state.runtime } }) : "{}");
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
      res.on("end", () => resolve({ status: res.statusCode, text: Buffer.concat(chunks).toString("utf8") }));
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
  const res = await send(proxy.port, "POST", CANON_PATH, pretty);
  await settle();
  const got = daemon.seen.at(-1);
  chk("canonical pretty-printed create answered 201", res.status, 201);
  chk("forwarded bytes == JSON.stringify(vetted)", got?.body, JSON.stringify(mk()));
  chk("content-length recomputed", got?.headers["content-length"], String(Buffer.byteLength(JSON.stringify(mk()))));
  chk("no transfer-encoding upstream", got?.headers["transfer-encoding"], undefined);
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

export async function proxyFailures() {
  const fail = [];
  const chk = (label, got, want) => { if (got !== want) fail.push(`${label}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); };
  const dir = await mkdtemp(path.join(tmpdir(), "ide-proxy-selfcheck-"));
  const state = { runtime: "" };
  const daemon = await startFakeDaemon(path.join(dir, "docker.sock"), state);
  const proxy = await startProxy(dir, path.join(dir, "docker.sock"), {});
  try {
    await bytesForwardedAreVetted(proxy, daemon, chk);
    await repeatedKeysAreRefused(proxy, daemon, chk);
  } finally {
    proxy.stop();
    await daemon.close();
    await rm(dir, { recursive: true, force: true });
  }
  return fail;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const fail = await proxyFailures();
  if (fail.length) { process.stderr.write(`proxy selfcheck FAIL:\n${fail.join("\n")}\n`); process.exit(1); }
  process.stdout.write("proxy selfcheck OK: the daemon receives exactly the vetted body, repeated keys refused\n");
}
