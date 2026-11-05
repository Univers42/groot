// ADR 0039, T4: the app: handler dispatches on the host. app://osionos is the app (with its
// /__baas/ relay and its index fallback); app://terminal serves renderer/terminal/ and nothing
// else; any other host is a 404. Every 404 carries the terminal's narrow policy.
const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { resolveAppRequest, terminalCsp, createAppHandler } = require("../desktop-app-protocol");

const rendererDir = "/opt/osionos/renderer";
const files = new Set([
  "index.html", "assets/app.js", "terminal/index.html", "terminal/assets/index.js", "terminal-x/a",
].map((f) => path.join(rendererDir, f)));
const resolve = (url) => resolveAppRequest(url, { rendererDir, isFile: (f) => files.has(f) });
const notFound = { status: 404, policy: "terminal" };

describe("resolveAppRequest — app://terminal (T4)", () => {
  it("serves its own files with the terminal policy", () => {
    assert.deepEqual(resolve("app://terminal/index.html"), { status: 200, file: path.join(rendererDir, "terminal/index.html"), policy: "terminal" });
    assert.deepEqual(resolve("app://terminal/index.html?theme=light"), { status: 200, file: path.join(rendererDir, "terminal/index.html"), policy: "terminal" });
    assert.deepEqual(resolve("app://terminal/assets/index.js"), { status: 200, file: path.join(rendererDir, "terminal/assets/index.js"), policy: "terminal" });
  });
  for (const url of [
    "app://terminal/__baas/rest/v1/x",
    "app://terminal/missing.js",
    "app://terminal/..%2findex.html",
    "app://terminal/..%2fterminal-x/a",
    "app://terminal/%E0%A4%A",
    "app://terminal/",
    "app://terminal/assets",
    "app://terminal/assets/..%2f..%2findex.html",
  ]) it(`${url} is a 404 with the terminal policy`, () => assert.deepEqual(resolve(url), notFound));
});

describe("resolveAppRequest — other hosts (T4)", () => {
  for (const url of ["app://x/index.html", "app://osionos/terminal/index.html", "app://osionos/terminal/assets/index.js", "app://osionos/%74erminal/index.html", "app://osionos/terminal"]) {
    it(`${url} is a 404 with the terminal policy`, () => assert.deepEqual(resolve(url), notFound));
  }
  it("app://osionos keeps its relay, its files and its index fallback", () => {
    assert.deepEqual(resolve("app://osionos/__baas/rest/v1/x"), { relay: true });
    assert.deepEqual(resolve("app://osionos/assets/app.js"), { status: 200, file: path.join(rendererDir, "assets/app.js"), policy: "renderer" });
    const index = { status: 200, file: path.join(rendererDir, "index.html"), policy: "renderer" };
    assert.deepEqual(resolve("app://osionos/"), index);
    assert.deepEqual(resolve("app://osionos/some/route"), index);
    assert.deepEqual(resolve("app://osionos/..%2fsecret"), index);
    assert.deepEqual(resolve("app://osionos/%E0%A4%A"), index);
  });
});

describe("terminalCsp (T4)", () => {
  const policy = terminalCsp();
  const directive = (name) => policy.split(";").map((s) => s.trim()).find((s) => s.startsWith(name + " "));
  it("is narrower than the renderer's: no https:, wss: or loopback, no frames, only the app may frame it", () => {
    assert.equal(directive("script-src"), "script-src 'self' 'wasm-unsafe-eval'");
    assert.equal(directive("connect-src"), "connect-src 'self'");
    assert.equal(directive("img-src"), "img-src 'self' data: blob:");
    assert.equal(directive("frame-src"), "frame-src 'none'");
    assert.equal(directive("frame-ancestors"), "frame-ancestors app://osionos");
    assert.doesNotMatch(policy, /https:|wss:|localhost|127\.0\.0\.1| 'unsafe-eval'/);
  });
});

// The renderer picks the path and query of a /__baas/ request, and SonarCloud flags that as SSRF
// (jssecurity:S5144), which is why the fetch carries a NOSONAR. This is the proof behind it: the
// relay must keep working for every path the renderer may ask for, but never for another host.
// Caveat: WHATWG URL stands in for the Chromium parser behind net.fetch, so a URL the two read
// differently is not covered, and only the first hop is: net.fetch follows upstream redirects.
describe("createAppHandler — the /__baas/ relay stays on baasTarget's origin", () => {
  const HOSTILE = ["", "@", "/", "//", "\\", "..", "%2e%2e", "%2f", "%5c", ":", "evil.test", "%00", "%0d%0a", "%40", "?", "#"];
  const suffixes = HOSTILE.flatMap((a) => HOSTILE.flatMap((b) => HOSTILE.map((c) => a + b + c)));
  const relayThrough = async (baasTarget, url) => {
    const fetched = [];
    const net = { fetch: async (target) => { fetched.push(String(target)); return new Response("{}"); } };
    const handler = createAppHandler({ net, rendererDir, baasTarget, rendererPolicy: "", rendererCspHeader: "content-security-policy" });
    await handler({ url, method: "GET", headers: new Headers() });
    return fetched.filter((target) => !target.startsWith("file:"));
  };

  for (const baasTarget of ["http://127.0.0.1:8000", "https://grobase.tailnet.ts.net"]) {
    it(`no path of ${suffixes.length} reaches past ${baasTarget}`, async () => {
      let relayed = 0;
      for (const suffix of suffixes) {
        for (const target of await relayThrough(baasTarget, `app://osionos/__baas/${suffix}`)) {
          relayed++;
          assert.equal(new URL(target).origin, baasTarget, `${suffix} reached ${target}`);
        }
      }
      assert.ok(relayed > suffixes.length / 2, `only ${relayed} of ${suffixes.length} were relayed`);
    });
  }

  it("hands the path and query to the router unchanged", async () => {
    assert.deepEqual(await relayThrough("http://127.0.0.1:8000", "app://osionos/__baas/rest/v1/x?a=1&b=2"), ["http://127.0.0.1:8000/rest/v1/x?a=1&b=2"]);
  });
});
