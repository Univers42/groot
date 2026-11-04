"use strict";
// The app: protocol (ADR 0039, T4). It dispatches on the host first:
//   app://osionos  the app: renderer/, the /__baas/ relay, a missing file falls back to index.html
//                  (client routes), and /terminal/ is a 404, so the terminal never runs on the app's origin;
//   app://terminal VS Code's terminal page: renderer/terminal/ only, no relay, no fallback;
//   any other host a 404.
// The terminal is its own origin so Chromium gives it its own renderer process, off the app's thread.
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const { statSync } = require("node:fs");
const { baasResponseHeaders } = require("./desktop-guards");

// The page needs its own scripts and wasm, its styles, its fonts and images, and workers; it talks
// to the shell over a port it is handed, so it has no network source and frames nothing.
function terminalCsp() {
  return [
    "default-src 'self'",
    "script-src 'self' 'wasm-unsafe-eval'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob:",
    "font-src 'self' data:",
    "connect-src 'self'",
    "worker-src 'self' blob:",
    "frame-src 'none'",
    "object-src 'none'",
    "base-uri 'none'",
    "frame-ancestors app://osionos",
  ].join("; ");
}

const NOT_FOUND = Object.freeze({ status: 404, policy: "terminal" });

// The decoded path relative to root, or null when it cannot be decoded or leaves root.
function insideRoot(root, pathname) {
  let decoded;
  try { decoded = decodeURIComponent(pathname); } catch { return null; }
  const rel = path.relative(root, path.join(root, decoded));
  if (rel === "" || rel === ".." || rel.startsWith(".." + path.sep) || path.isAbsolute(rel)) return null;
  return rel;
}

function resolveAppRequest(url, { rendererDir, isFile }) {
  const u = new URL(url);
  if (u.host === "terminal") {
    const root = path.join(rendererDir, "terminal");
    const rel = insideRoot(root, u.pathname);
    const file = rel === null ? null : path.join(root, rel);
    return file && isFile(file) ? { status: 200, file, policy: "terminal" } : NOT_FOUND;
  }
  if (u.host !== "osionos") return NOT_FOUND;
  if (u.pathname.startsWith("/__baas/")) return { relay: true };
  const index = { status: 200, file: path.join(rendererDir, "index.html"), policy: "renderer" };
  const rel = insideRoot(rendererDir, u.pathname);
  if (rel === null) return index;
  if (rel === "terminal" || rel.startsWith("terminal" + path.sep)) return NOT_FOUND;
  const file = path.join(rendererDir, rel);
  return isFile(file) ? { status: 200, file, policy: "renderer" } : index;
}

function isRegularFile(file) {
  try { return statSync(file).isFile(); } catch { return false; }
}

// Relay same-origin app://osionos/__baas/* to the plain-HTTP query-router from the main process
// (no renderer HTTPS-upgrade). Both directions are buffered and only the headers the router needs
// are forwarded, so the response cannot trip Chromium with a content-encoding/length mismatch
// (seen as net::ERR_UNEXPECTED). It never throws: a failure is a 502.
async function relayToBaas(net, baasTarget, request, url) {
  const target = baasTarget + url.pathname.slice("/__baas".length) + url.search;
  const headers = new Headers();
  for (const name of ["content-type", "accept", "x-baas-api-key", "apikey", "authorization"]) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  const init = { method: request.method, headers };
  if (request.method !== "GET" && request.method !== "HEAD") init.body = await request.arrayBuffer();
  try {
    const upstream = await net.fetch(target, init);
    const body = await upstream.arrayBuffer();
    // WHY: upstream MIME/headers are never trusted; baasResponseHeaders forces octet-stream + sandbox.
    return new Response(body, { status: upstream.status, statusText: upstream.statusText, headers: baasResponseHeaders(upstream.headers.get("content-type")) });
  } catch (error) {
    return new Response(JSON.stringify({ error: "baas proxy failed", detail: String(error) }), { status: 502, headers: baasResponseHeaders("application/json") });
  }
}

// WHY: the app's files carry its CSP under the edition's header (enforced in FULL, Report-Only in
// LOCAL/NATIVE whose C15 smoke is pending). The terminal's policy is always enforced: it is
// narrower than the app's, and frame-ancestors has no effect in Report-Only.
function createAppHandler({ net, rendererDir, baasTarget, rendererPolicy, rendererCspHeader }) {
  const policies = {
    renderer: [rendererCspHeader, rendererPolicy],
    terminal: ["content-security-policy", terminalCsp()],
  };
  return async (request) => {
    const url = new URL(request.url);
    const resolved = resolveAppRequest(request.url, { rendererDir, isFile: isRegularFile });
    if (resolved.relay) return relayToBaas(net, baasTarget, request, url);
    const [cspName, cspValue] = policies[resolved.policy];
    if (resolved.status === 404) return new Response("Not found", { status: 404, headers: { "content-type": "text/plain", [cspName]: cspValue } });
    const res = await net.fetch(pathToFileURL(resolved.file).toString());
    const headers = new Headers(res.headers);
    headers.set(cspName, cspValue);
    return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
  };
}

module.exports = { resolveAppRequest, terminalCsp, createAppHandler };
