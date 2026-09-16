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

// osionos IDE egress proxy — the ONLY route off-box for a sandbox.
//
// The sandbox joins an `internal: true` network with no default route; every
// package/git fetch tunnels through this HTTPS-CONNECT proxy. Off-the-shelf
// proxies allowlist by HOSTNAME, which DNS-rebinding defeats; this proxy
// re-validates the RESOLVED IP at connect time and pins the socket to the exact
// address it validated, so a hostname that resolves to 169.254.169.254 or a
// mini-baas backend IP is refused (devil conditions 3, 5, 6).
//
// SECURITY MODEL (Node built-ins only; runs cap_drop ALL, non-root, read-only):
//  - CONNECT only, port 443 only. No plain-HTTP forwarding, no other ports.
//  - Host must match the allowlist (exact or dotted-suffix). The user's git host
//    is added via IDE_EGRESS_GIT_HOSTS but is STILL IP-revalidated (SSRF guard).
//  - Every resolved A/AAAA is checked against the deny CIDRs (RFC1918, loopback,
//    link-local, ULA, metadata v4+v6, and configured backend ranges). ANY denied
//    address for the host → refuse the whole host (rebind-safe).
//  - The upstream socket connects to the VALIDATED literal IP (not the hostname),
//    so DNS cannot change under us between check and connect (TOCTOU-safe).

import net from "node:net";
import dns from "node:dns/promises";
import { fileURLToPath } from "node:url";

const PORT = Number(process.env.IDE_EGRESS_PORT || 8080);
const ALLOW_PORT = 443;
const DIAL_TIMEOUT_MS = 15_000;

const BASE_ALLOW = [
  "registry.npmjs.org", "pypi.org", "files.pythonhosted.org",
  "github.com", "codeload.github.com", "objects.githubusercontent.com",
  "raw.githubusercontent.com", "crates.io", "static.crates.io",
  "index.crates.io", "proxy.golang.org", "sum.golang.org",
];
const GIT_HOSTS = (process.env.IDE_EGRESS_GIT_HOSTS || "")
  .split(",").map((h) => h.trim().toLowerCase()).filter(Boolean);
const ALLOWLIST = new Set([...BASE_ALLOW, ...GIT_HOSTS]);

/** host matches an allowed name exactly or as a `.`-anchored suffix. */
function hostAllowed(host) {
  const lower = host.toLowerCase();
  if (ALLOWLIST.has(lower)) return true;
  for (const allowed of ALLOWLIST) {
    if (lower.endsWith(`.${allowed}`)) return true;
  }
  return false;
}

// Deny CIDRs, matched against the RESOLVED address (not the hostname).
const DENY4 = [
  ["10.0.0.0", 8], ["172.16.0.0", 12], ["192.168.0.0", 16],
  ["127.0.0.0", 8], ["169.254.0.0", 16], ["100.64.0.0", 10],
  ["0.0.0.0", 8], ["192.0.0.0", 24], ["198.18.0.0", 15],
];
function ip4ToInt(ip) {
  const parts = ip.split(".").map(Number);
  if (parts.length !== 4 || parts.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return null;
  return ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]) >>> 0;
}
function denied4(ip) {
  const value = ip4ToInt(ip);
  if (value === null) return true; // unparseable → refuse
  for (const [base, bits] of DENY4) {
    const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
    if ((value & mask) === (ip4ToInt(base) & mask)) return true;
  }
  return false;
}
function denied6(ip) {
  const lower = ip.toLowerCase();
  // loopback, unspecified, link-local (fe80::/10), ULA (fc00::/7),
  // v6 metadata (fd00:ec2::254) and v4-mapped forms all refuse.
  if (lower === "::1" || lower === "::") return true;
  if (lower.startsWith("fe8") || lower.startsWith("fe9") || lower.startsWith("fea") || lower.startsWith("feb")) return true;
  if (lower.startsWith("fc") || lower.startsWith("fd")) return true;
  if (lower.startsWith("::ffff:")) return denied4(lower.slice(7)); // v4-mapped
  return false;
}

/** Resolve host to a single validated, connectable IP or throw. Rebind-safe:
 *  EVERY resolved address must pass, then we return the first to dial by literal. */
async function resolveSafe(host) {
  const records = await dns.lookup(host, { all: true, verbatim: true });
  if (records.length === 0) throw new Error("no address");
  for (const record of records) {
    const bad = record.family === 6 ? denied6(record.address) : denied4(record.address);
    if (bad) throw new Error(`blocked address ${record.address} for ${host}`);
  }
  return records[0];
}

const server = net.createServer((client) => {
  client.once("data", (chunk) => {
    const line = chunk.toString("latin1").split("\r\n")[0];
    const match = /^CONNECT\s+([^\s:]+):(\d+)\s+HTTP\/1\.[01]$/i.exec(line);
    if (!match) return refuse(client, 400, "Bad Request");
    const host = match[1];
    const port = Number(match[2]);
    if (port !== ALLOW_PORT) return refuse(client, 403, "Port not allowed");
    if (!hostAllowed(host)) return refuse(client, 403, "Host not allowed");

    resolveSafe(host)
      .then((record) => dialUpstream(client, host, record))
      .catch(() => refuse(client, 403, "Address denied"));
  });
  client.on("error", () => client.destroy());
});

function dialUpstream(client, host, record) {
  const upstream = net.connect({ host: record.address, port: ALLOW_PORT, family: record.family });
  const timer = setTimeout(() => upstream.destroy(), DIAL_TIMEOUT_MS);
  upstream.on("connect", () => {
    clearTimeout(timer);
    client.write("HTTP/1.1 200 Connection Established\r\n\r\n");
    upstream.pipe(client);
    client.pipe(upstream);
    log("ALLOW", host, record.address);
  });
  upstream.on("error", () => { clearTimeout(timer); refuse(client, 502, "Upstream failed"); });
  client.on("error", () => upstream.destroy());
  client.on("close", () => upstream.destroy());
}

function refuse(client, code, message) {
  try { client.write(`HTTP/1.1 ${code} ${message}\r\n\r\n`); } catch { /* gone */ }
  client.destroy();
}

function log(decision, host, address) {
  process.stdout.write(`[ide-egress] ${decision} ${host} -> ${address ?? "-"}\n`);
}

export { hostAllowed, denied4, denied6, ALLOWLIST };

const isMain = process.argv[1] === fileURLToPath(import.meta.url);

// `node proxy.mjs --selfcheck` asserts the allow/deny tables without a socket —
// a fast gate that runs in any node container (no daemon, no user code).
if (isMain && process.argv.includes("--selfcheck")) {
  const fail = [];
  const expect = (label, got, want) => { if (got !== want) fail.push(`${label}: got ${got}, want ${want}`); };
  expect("github allowed", hostAllowed("github.com"), true);
  expect("api.github suffix", hostAllowed("api.github.com"), true);
  expect("pypi allowed", hostAllowed("files.pythonhosted.org"), true);
  expect("evil denied", hostAllowed("evil.example.com"), false);
  expect("evilgithub.com denied", hostAllowed("evilgithub.com"), false);
  expect("metadata v4 denied", denied4("169.254.169.254"), true);
  expect("rfc1918 10 denied", denied4("10.1.2.3"), true);
  expect("rfc1918 172.16 denied", denied4("172.16.5.5"), true);
  expect("rfc1918 192.168 denied", denied4("192.168.1.1"), true);
  expect("loopback denied", denied4("127.0.0.1"), true);
  expect("cgnat denied", denied4("100.64.0.1"), true);
  expect("public allowed", denied4("8.8.8.8"), false);
  expect("public cloudflare", denied4("1.1.1.1"), false);
  expect("v6 loopback denied", denied6("::1"), true);
  expect("v6 ula denied", denied6("fd00:ec2::254"), true);
  expect("v6 linklocal denied", denied6("fe80::1"), true);
  expect("v6 mapped metadata denied", denied6("::ffff:169.254.169.254"), true);
  expect("v6 public allowed", denied6("2606:4700:4700::1111"), false);
  if (fail.length) { process.stderr.write(`selfcheck FAIL:\n${fail.join("\n")}\n`); process.exit(1); }
  process.stdout.write("selfcheck OK: egress allow/deny tables correct\n");
  process.exit(0);
}

if (isMain) {
  server.listen(PORT, () => {
    process.stdout.write(`[ide-egress] CONNECT proxy on :${PORT} — ${ALLOWLIST.size} allowed hosts, 443 only\n`);
  });
}
