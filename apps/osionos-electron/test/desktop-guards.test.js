"use strict";
// Tests for desktop-guards.js pure helpers (node:test, CommonJS).
const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const {
  isExternalHttpUrl,
  isAppPageUrl,
  isAllowedSubframeUrl,
  senderAllowed,
  baasResponseHeaders,
  inlineScriptHashes,
  frameOriginsFrom,
  rendererCsp,
} = require("../desktop-guards");

function mainEvent(overrides) {
  // WHY: builds a main-frame event shape mirroring Electron's sender/senderFrame.
  const sender = { mainFrame: null, url: "" };
  const frame = { url: "app://osionos/index.html?x=1#h" };
  sender.mainFrame = frame;
  const base = { sender, senderFrame: frame };
  return { base, sender, frame, event: Object.assign(base, overrides) };
}

describe("isExternalHttpUrl", () => {
  it("true for http/https, false otherwise", () => {
    assert.equal(isExternalHttpUrl("https://example.com/a"), true);
    assert.equal(isExternalHttpUrl("http://localhost:3002/"), true);
    assert.equal(isExternalHttpUrl("app://osionos/index.html"), false);
    assert.equal(isExternalHttpUrl("file:///x"), false);
    assert.equal(isExternalHttpUrl("not a url"), false);
  });
});

describe("senderAllowed", () => {
  it("true for the main frame at /index.html with query+hash", () => {
    const { event, sender } = mainEvent();
    assert.equal(senderAllowed(event, sender), true);
  });
  it("true for pathname /", () => {
    const { event, sender, frame } = mainEvent();
    frame.url = "app://osionos/";
    assert.equal(senderAllowed(event, sender), true);
  });
  it("false for a null senderFrame", () => {
    const { event, sender } = mainEvent({ senderFrame: null });
    assert.equal(senderAllowed(event, sender), false);
  });
  it("false for undefined senderFrame", () => {
    const { event, sender } = mainEvent({ senderFrame: undefined });
    assert.equal(senderAllowed(event, sender), false);
  });
  it("false for a subframe (senderFrame !== sender.mainFrame)", () => {
    const { event, sender } = mainEvent({ senderFrame: { url: "app://osionos/index.html" } });
    assert.equal(senderAllowed(event, sender), false);
  });
  it("false for a child window (sender !== mainContents)", () => {
    const { event } = mainEvent();
    assert.equal(senderAllowed(event, { mainFrame: {} }), false);
  });
  it("false for frame URL app://osionos/__baas/x", () => {
    const { event, sender, frame } = mainEvent();
    frame.url = "app://osionos/__baas/x";
    assert.equal(senderAllowed(event, sender), false);
  });
  it("false for app://evil/index.html", () => {
    const { event, sender, frame } = mainEvent();
    frame.url = "app://evil/index.html";
    assert.equal(senderAllowed(event, sender), false);
  });
  it("false for https://osionos/", () => {
    const { event, sender, frame } = mainEvent();
    frame.url = "https://osionos/";
    assert.equal(senderAllowed(event, sender), false);
  });
});

describe("isAppPageUrl", () => {
  it("false for /__baas/, /__baas, app://other/", () => {
    assert.equal(isAppPageUrl("app://osionos/__baas/"), false);
    assert.equal(isAppPageUrl("app://osionos/__baas"), false);
    assert.equal(isAppPageUrl("app://osionos/__baas/x?y=1"), false);
    assert.equal(isAppPageUrl("app://other/"), false);
    assert.equal(isAppPageUrl("https://osionos/"), false);
  });
  it("true for app pages", () => {
    assert.equal(isAppPageUrl("app://osionos/index.html"), true);
    assert.equal(isAppPageUrl("app://osionos/?q=1#h"), true);
  });
});

describe("isAllowedSubframeUrl", () => {
  it("false for app/blob/data/javascript", () => {
    assert.equal(isAllowedSubframeUrl("app://osionos/"), false);
    assert.equal(isAllowedSubframeUrl("blob:https://example.com/x"), false);
    assert.equal(isAllowedSubframeUrl("data:text/html,hi"), false);
    assert.equal(isAllowedSubframeUrl("javascript:alert(1)"), false);
  });
  it("true for http/https", () => {
    assert.equal(isAllowedSubframeUrl("https://localhost:3007/"), true);
    assert.equal(isAllowedSubframeUrl("http://localhost:3002/"), true);
  });
  it("PDF data: previews pass, other data: types and look-alikes do not", () => {
    assert.equal(isAllowedSubframeUrl("data:application/pdf;base64,JVBERi0="), true);
    assert.equal(isAllowedSubframeUrl("data:application/pdf,%25PDF"), true);
    assert.equal(isAllowedSubframeUrl("data:application/pdfx;base64,AA=="), false);
    assert.equal(isAllowedSubframeUrl("data:text/html;base64,PHNjcmlwdD4="), false);
    assert.equal(isAllowedSubframeUrl("data:image/svg+xml,<svg onload=alert(1)>"), false);
    assert.equal(isAllowedSubframeUrl("about:srcdoc"), false);
  });
});

describe("baasResponseHeaders", () => {
  it("text/html -> octet-stream + nosniff + sandbox CSP", () => {
    const h = baasResponseHeaders("text/html");
    assert.equal(h["content-type"], "application/octet-stream");
    assert.equal(h["x-content-type-options"], "nosniff");
    assert.equal(h["content-security-policy"], "sandbox; default-src 'none'");
  });
  it("application/json; charset=utf-8 kept", () => {
    const h = baasResponseHeaders("application/json; charset=utf-8");
    assert.equal(h["content-type"], "application/json; charset=utf-8");
  });
  it("application/problem+json kept", () => {
    const h = baasResponseHeaders("application/problem+json");
    assert.equal(h["content-type"], "application/problem+json");
  });
});

describe("inlineScriptHashes", () => {
  it("one inline and one src script -> exactly one hash matching node:crypto", () => {
    const body = "console.log(1);";
    const html = '<html><head><script src="a.js"></script><script>' + body + "</script></head></html>";
    const got = inlineScriptHashes(html);
    assert.equal(got.length, 1);
    const want = "'sha256-" + crypto.createHash("sha256").update(body, "utf8").digest("base64") + "'";
    assert.equal(got[0], want);
  });
});

describe("frameOriginsFrom", () => {
  it("drops evil/no-port/path/app, keeps 127.0.0.1:5000", () => {
    const got = frameOriginsFrom("https://evil.com:1,http://localhost,http://localhost:3002/path,app://osionos,http://127.0.0.1:5000");
    assert.deepEqual(got, ["http://127.0.0.1:5000"]);
  });
  it("defaults when empty/undefined", () => {
    assert.deepEqual(frameOriginsFrom(undefined), ["http://localhost:3002", "http://localhost:3003", "https://localhost:3007"]);
    assert.deepEqual(frameOriginsFrom(""), ["http://localhost:3002", "http://localhost:3003", "https://localhost:3007"]);
  });
});

describe("rendererCsp", () => {
  it("script-src has no unsafe-inline/unsafe-eval, has none guards, frame-src narrowed", () => {
    const policy = rendererCsp({ scriptHashes: ["'sha256-abc'"], frameOrigins: ["http://localhost:3002"] });
    const scriptSrc = policy.split(";").map((s) => s.trim()).find((s) => s.startsWith("script-src "));
    assert.ok(!scriptSrc.includes("'unsafe-inline'"));
    assert.ok(!scriptSrc.includes("'unsafe-eval'") || scriptSrc.includes("'wasm-unsafe-eval'"));
    assert.ok(!/\s'unsafe-eval'(\s|;|$)/.test(policy));
    assert.ok(policy.includes("object-src 'none'"));
    assert.ok(policy.includes("base-uri 'none'"));
    const frameSrc = policy.split(";").map((s) => s.trim()).find((s) => s.startsWith("frame-src "));
    assert.ok(!frameSrc.includes("'self'"));
    assert.ok(!frameSrc.includes("app:"));
    assert.ok(frameSrc.includes("http://localhost:3002"));
  });
});
