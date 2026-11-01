"use strict";
// Tests for desktop-proxy.js: the app reaches its own tailnet directly while every other
// request keeps the system proxy (node:test, CommonJS).
const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const { tailnetBypassRules, proxyRulesFrom, applyTailnetBypass } = require("../desktop-proxy");

describe("tailnetBypassRules", () => {
  it("bypasses only this tailnet's MagicDNS domain and Tailscale's private ranges", () => {
    assert.equal(
      tailnetBypassRules("https://baas.tail10f2ea.ts.net"),
      "*.tail10f2ea.ts.net;100.64.0.0/10;fd7a:115c:a1e0::/48",
    );
  });

  it("never widens to every *.ts.net host (public Funnel hosts of other people)", () => {
    assert.ok(!tailnetBypassRules("https://baas.tail10f2ea.ts.net:10000").split(";").includes("*.ts.net"));
  });

  it("covers a data center addressed by its tailnet IP", () => {
    assert.equal(tailnetBypassRules("http://100.97.49.118:8000"), "100.64.0.0/10;fd7a:115c:a1e0::/48");
  });

  it("leaves anything that is not a tailnet address on the system proxy", () => {
    for (const url of ["https://grobase-stack.fly.dev", "http://127.0.0.1:8000", "https://ts.net", "https://x.ts.net", "http://100.128.0.1", "not a url", "", undefined]) {
      assert.equal(tailnetBypassRules(url), null, String(url));
    }
  });
});

describe("proxyRulesFrom", () => {
  it("turns Chromium's resolved proxy into fixed-server rules", () => {
    assert.equal(proxyRulesFrom("SOCKS5 127.0.0.1:9050"), "socks5://127.0.0.1:9050");
    assert.equal(proxyRulesFrom("SOCKS 127.0.0.1:9050"), "socks4://127.0.0.1:9050");
    assert.equal(proxyRulesFrom("PROXY 127.0.0.1:8080"), "http://127.0.0.1:8080");
    assert.equal(proxyRulesFrom("HTTPS proxy.example:443"), "https://proxy.example:443");
  });

  it("keeps the whole fallback chain in order", () => {
    assert.equal(proxyRulesFrom("SOCKS5 127.0.0.1:9050;PROXY 127.0.0.1:8080"), "socks5://127.0.0.1:9050,http://127.0.0.1:8080");
    assert.equal(proxyRulesFrom("PROXY a:1; DIRECT"), "http://a:1,direct://");
  });

  it("returns null when the system already goes direct, or the answer is unreadable", () => {
    assert.equal(proxyRulesFrom("DIRECT"), null);
    assert.equal(proxyRulesFrom(""), null);
    assert.equal(proxyRulesFrom("QUIC weird:1"), null);
  });
});

describe("applyTailnetBypass", () => {
  function fakeSession(resolved) {
    const calls = [];
    return { calls, resolveProxy: async () => resolved, setProxy: async (config) => { calls.push(config); } };
  }

  it("keeps the system proxy for everything else and adds the tailnet bypass", async () => {
    const ses = fakeSession("SOCKS5 127.0.0.1:9050");
    const applied = await applyTailnetBypass(ses, "https://baas.tail10f2ea.ts.net");
    assert.deepEqual(ses.calls, [{
      mode: "fixed_servers",
      proxyRules: "socks5://127.0.0.1:9050",
      proxyBypassRules: "<local>;*.tail10f2ea.ts.net;100.64.0.0/10;fd7a:115c:a1e0::/48",
    }]);
    assert.equal(applied.proxyRules, "socks5://127.0.0.1:9050");
  });

  it("changes nothing when the system has no proxy or the data center is not on a tailnet", async () => {
    const direct = fakeSession("DIRECT");
    assert.equal(await applyTailnetBypass(direct, "https://baas.tail10f2ea.ts.net"), null);
    const public_ = fakeSession("SOCKS5 127.0.0.1:9050");
    assert.equal(await applyTailnetBypass(public_, "https://grobase-stack.fly.dev"), null);
    assert.deepEqual([...direct.calls, ...public_.calls], []);
  });
});
