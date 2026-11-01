"use strict";
// Where the app runs: which edition is hardened, and which BaaS it talks to (desktop-guards.js).
const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const { editionOf, cspHeaderName, webSecurityFor, baasTargetOf, isLoopbackUrl } = require("../desktop-guards");

describe("edition hardening", () => {
  it("editionOf: native wins over local", () => {
    assert.equal(editionOf({ isNative: true, localCompose: "/x/docker-compose.local.yml" }), "native");
  });
  it("editionOf: set localCompose is local", () => {
    assert.equal(editionOf({ isNative: false, localCompose: "/x/docker-compose.local.yml" }), "local");
  });
  it("editionOf: empty string and undefined are full", () => {
    assert.equal(editionOf({ isNative: false, localCompose: "" }), "full");
    assert.equal(editionOf({ isNative: false, localCompose: undefined }), "full");
  });
  it("cspHeaderName: full enforces, local and native stay report-only", () => {
    assert.equal(cspHeaderName("full"), "content-security-policy");
    assert.equal(cspHeaderName("local"), "content-security-policy-report-only");
    assert.equal(cspHeaderName("native"), "content-security-policy-report-only");
  });
  it("webSecurityFor: full is true, local and native are false", () => {
    assert.equal(webSecurityFor("full"), true);
    assert.equal(webSecurityFor("local"), false);
    assert.equal(webSecurityFor("native"), false);
  });
  it("unknown edition fails closed to report-only and false", () => {
    assert.equal(cspHeaderName("beta"), "content-security-policy-report-only");
    assert.equal(webSecurityFor("beta"), false);
  });
});

describe("baas target", () => {
  it("baasTargetOf: launch env wins, then the baked URL, then the local Kong", () => {
    assert.equal(baasTargetOf("https://env.example/", "https://baked.example"), "https://env.example");
    assert.equal(baasTargetOf("", "https://baas.example.ts.net/"), "https://baas.example.ts.net");
    assert.equal(baasTargetOf(undefined, undefined), "http://127.0.0.1:8000");
  });
  it("baasTargetOf: localhost is coerced to IPv4 (Kong binds 127.0.0.1 only)", () => {
    assert.equal(baasTargetOf("http://localhost:8000", ""), "http://127.0.0.1:8000");
  });
  it("isLoopbackUrl: the local Kong is loopback, a tailnet grobase is not", () => {
    assert.equal(isLoopbackUrl("http://127.0.0.1:8000"), true);
    assert.equal(isLoopbackUrl("http://[::1]:8000"), true);
    assert.equal(isLoopbackUrl("https://baas.example.ts.net"), false);
  });
  it("isLoopbackUrl: an unparsable target counts as local, so the suite still boots as before", () => {
    assert.equal(isLoopbackUrl("not a url"), true);
  });
});
