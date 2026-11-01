"use strict";
// The desktop app's exception to the system proxy: its own data center, when it lives on a
// tailnet, is reached directly; every other request keeps the proxy the system names.
//
// Why: with the system proxy on Tor, each request to the tailnet data center left the tailnet
// through a Tor circuit and Tailscale's public Funnel: 0.3-0.5 s per request warm and 2.6 s
// cold, against ~6 ms direct over Tailscale (measured 2026-10-30 from this laptop). Only this
// tailnet's MagicDNS domain and Tailscale's private ranges are exempt — never every *.ts.net
// host, which would also send other people's public Funnel sites around the proxy.
//
// Caveat: the system proxy is read once at launch. Changing it while the app runs (turning
// Tor off, another port) takes effect at the next launch; until then the app keeps the
// launch-time proxy for non-tailnet requests.

// Tailscale's CGNAT IPv4 range and its IPv6 ULA prefix.
const TAILNET_RANGES = "100.64.0.0/10;fd7a:115c:a1e0::/48";
const SCHEME_OF = new Map([
  ["PROXY", "http"],
  ["HTTPS", "https"],
  ["SOCKS", "socks4"],
  ["SOCKS4", "socks4"],
  ["SOCKS5", "socks5"],
]);

function isTailnetIp(host) {
  if (/^\[fd7a:115c:a1e0:/i.test(host)) return true;
  const octets = host.split(".").map(Number);
  return octets.length === 4 && octets.every((o) => Number.isInteger(o) && o >= 0 && o <= 255)
    && octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127;
}

/** Bypass rules for the data center's own tailnet, or null when it is not on one. */
function tailnetBypassRules(dataCenterUrl) {
  let host;
  try { host = new URL(dataCenterUrl).hostname.toLowerCase(); } catch { return null; }
  if (isTailnetIp(host)) return TAILNET_RANGES;
  // A MagicDNS machine name is <machine>.<tailnet>.ts.net: four labels at least.
  const labels = host.split(".");
  if (labels.length < 4 || labels.slice(-2).join(".") !== "ts.net") return null;
  return `*.${labels.slice(-3).join(".")};${TAILNET_RANGES}`;
}

/** Chromium's resolved proxy ("SOCKS5 h:p;PROXY h:p;DIRECT") as fixed-server rules, or null. */
function proxyRulesFrom(resolved) {
  const entries = String(resolved ?? "").split(";").map((e) => e.trim()).filter(Boolean);
  if (!entries.length || entries[0] === "DIRECT") return null;
  const rules = [];
  for (const entry of entries) {
    if (entry === "DIRECT") { rules.push("direct://"); continue; }
    const [type, hostPort] = entry.split(/\s+/);
    const scheme = SCHEME_OF.get(type);
    if (!scheme || !hostPort) return null;
    rules.push(`${scheme}://${hostPort}`);
  }
  return rules.join(",");
}

/** Keep the system proxy for everything else and send the data center's tailnet direct. */
async function applyTailnetBypass(ses, dataCenterUrl) {
  const bypass = tailnetBypassRules(dataCenterUrl);
  if (!bypass) return null;
  const proxyRules = proxyRulesFrom(await ses.resolveProxy("https://example.com/"));
  if (!proxyRules) return null;
  const config = { mode: "fixed_servers", proxyRules, proxyBypassRules: `<local>;${bypass}` };
  await ses.setProxy(config);
  return config;
}

module.exports = { tailnetBypassRules, proxyRulesFrom, applyTailnetBypass };
