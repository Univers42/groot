"use strict";
// desktop-guards.js — pure Electron shell-hardening helpers (no Electron import).
// WHY: every function takes plain objects so `node --test` can run it without Electron.
const crypto = require("node:crypto");

// WHY: only editions whose C15 Electron smoke ran clean enforce; add one when its smoke passes.
const HARDENED_EDITIONS = new Set(["full"]);

function editionOf(opts) {
  // WHY: NATIVE bundles its backend so it wins over LOCAL; empty compose means FULL.
  const o = opts || {};
  if (o.isNative) return "native";
  if (typeof o.localCompose === "string" && o.localCompose !== "") return "local";
  return "full";
}

function cspHeaderName(edition) {
  // WHY: hardened editions block violations; others stay Report-Only to gather signals.
  if (HARDENED_EDITIONS.has(edition)) return "content-security-policy";
  return "content-security-policy-report-only";
}

function webSecurityFor(edition) {
  // WHY: hardened editions passed the C15 smoke with CORS allowing app://osionos; others stay off.
  return HARDENED_EDITIONS.has(edition);
}

// WHY: the renderer frames mail/calendar/whiteboard loopback apps by default.
const DEFAULT_FRAME_ORIGINS = [
  "http://localhost:3002",
  "http://localhost:3003",
  "https://localhost:3007",
];

function isExternalHttpUrl(url) {
  // WHY: only http(s) ever leaves the app via shell.openExternal; all else stays denied.
  try {
    const u = new URL(url);
    return u.protocol === "http:" || u.protocol === "https:";
  } catch {
    return false;
  }
}

function isAppPageUrl(url) {
  // WHY: the shell hosts exactly one app origin; /__baas/ is the main-process relay, not a page.
  // Ponytail: pathname prefix check gets wrong a page that legitimately starts with /__baas/ (none exists).
  try {
    const u = new URL(url);
    if (u.protocol !== "app:" || u.host !== "osionos") return false;
    if (u.pathname === "/__baas" || u.pathname.startsWith("/__baas/")) return false;
    return true;
  } catch {
    return false;
  }
}

const PDF_DATA_URL = /^data:application\/pdf[;,]/i;

function isAllowedSubframeUrl(url) {
  // WHY: subframes may only embed remote http(s) pages; frame-src narrows further.
  // about:blank is the initial document of every iframe. data:application/pdf is the
  // attachment preview (FilePreviewModal frames the stored data: URL); it opens in the
  // PDF viewer, never as an HTML document. Enforcing the C14 CSP (frame-src without
  // data:) breaks that preview — the enforcement ruling has to move it first.
  if (url === "about:blank" || PDF_DATA_URL.test(url)) return true;
  try {
    const u = new URL(url);
    return u.protocol === "http:" || u.protocol === "https:";
  } catch {
    return false;
  }
}

function senderAllowed(event, mainContents) {
  // WHY: win:* IPC drives the frameless window, so only the main window top frame may send it.
  if (!event || event.sender !== mainContents) return false;
  const frame = event.senderFrame;
  if (frame === null || frame === undefined) return false;
  if (frame !== event.sender.mainFrame) return false;
  let u;
  try {
    u = new URL(frame.url);
  } catch {
    return false;
  }
  if (u.protocol !== "app:" || u.host !== "osionos") return false;
  return u.pathname === "/" || u.pathname === "/index.html";
}

function baasResponseHeaders(upstreamContentType) {
  // WHY: the /__baas/ relay must not let upstream dictate an executable MIME; sandbox as non-document.
  // Ponytail: JSON media-type allowlist gets wrong a JSON API that serves text/plain (downgraded to octet-stream).
  let media = "";
  if (typeof upstreamContentType === "string") media = upstreamContentType.split(";")[0].trim().toLowerCase();
  const keep = media === "application/json" || media.endsWith("+json");
  return {
    "content-type": keep ? upstreamContentType : "application/octet-stream",
    "x-content-type-options": "nosniff",
    "content-security-policy": "sandbox; default-src 'none'",
  };
}

function inlineScriptHashes(html) {
  // WHY: the renderer CSP pins the known inline bootstraps by hash so no unsafe-inline is needed.
  // Ponytail: regex scan, not an HTML parser — a <script> inside an HTML comment or a </script> inside a JS string is mis-hashed; the C15 smoke run (zero CSP reports) is what proves the hashes.
  const out = [];
  if (typeof html !== "string" || html === "") return out;
  const re = /<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi;
  let m;
  while ((m = re.exec(html)) !== null) {
    if (/\bsrc\s*=/i.test(m[1] || "")) continue;
    out.push("'sha256-" + crypto.createHash("sha256").update(m[2], "utf8").digest("base64") + "'");
  }
  return out;
}

function frameOriginsFrom(envValue) {
  // WHY: framed apps must be explicit loopback origins with a port; everything else is dropped.
  // Ponytail: loopback+port allowlist gets wrong a legitimate LAN/dev origin served off-loopback (dropped by design).
  if (envValue === undefined || envValue === null) return DEFAULT_FRAME_ORIGINS.slice();
  if (typeof envValue !== "string" || envValue.trim() === "") return DEFAULT_FRAME_ORIGINS.slice();
  const out = [];
  const parts = envValue.split(/[,\s]+/);
  for (const part of parts) {
    if (!part) continue;
    let u;
    try {
      u = new URL(part);
    } catch {
      continue;
    }
    if (u.protocol !== "http:" && u.protocol !== "https:") continue;
    if (u.hostname !== "localhost" && u.hostname !== "127.0.0.1") continue;
    if (!u.port) continue;
    if (u.pathname !== "/" || u.search !== "" || u.hash !== "") continue;
    if (!out.includes(u.origin)) out.push(u.origin);
  }
  return out;
}

function rendererCsp(opts) {
  // WHY: single policy string keeps file responses consistent; per-edition header enforces it once that edition's C15 smoke passes.
  const o = opts || {};
  const hashes = Array.isArray(o.scriptHashes) ? o.scriptHashes : [];
  const frames = Array.isArray(o.frameOrigins) ? o.frameOrigins : [];
  const scriptSrc = ["'self'", "'wasm-unsafe-eval'"].concat(hashes).join(" ");
  const frameSrc = ["https:"].concat(frames).join(" ");
  return [
    "default-src 'self'",
    "script-src " + scriptSrc,
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob: https: http://localhost:* http://127.0.0.1:*",
    "font-src 'self' data:",
    "connect-src 'self' https: wss: http://localhost:* http://127.0.0.1:* ws://localhost:* ws://127.0.0.1:*",
    "worker-src 'self' blob:",
    "frame-src " + frameSrc,
    "object-src 'none'",
    "base-uri 'none'",
  ].join("; ");
}

module.exports = {
  isExternalHttpUrl,
  isAppPageUrl,
  isAllowedSubframeUrl,
  senderAllowed,
  baasResponseHeaders,
  inlineScriptHashes,
  frameOriginsFrom,
  rendererCsp,
  editionOf,
  HARDENED_EDITIONS,
  cspHeaderName,
  webSecurityFor,
};
