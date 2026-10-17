// Run: docker run --rm -v "$PWD:/w" -w /w node:22-alpine node --test proxy.deny-log.test.mjs
// Not COPYed into the image (Dockerfile copies proxy.mjs only).
import test from "node:test";
import assert from "node:assert/strict";
import net from "node:net";

// localhost is an allowed git host here so the address-revalidation path is reachable offline.
process.env.IDE_EGRESS_GIT_HOSTS = "localhost";
const { server, setLogWriter } = await import("./proxy.mjs");

const lines = [];
setLogWriter((line) => lines.push(line));
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const { port } = server.address();
test.after(() => server.close());

async function send(raw) {
  lines.length = 0;
  const reply = await new Promise((resolve) => {
    const sock = net.connect(port, "127.0.0.1", () => sock.write(raw));
    let got = "";
    sock.on("data", (d) => { got += d; });
    sock.on("close", () => resolve(got));
  });
  return { reply, out: lines.join("") };
}

const cases = [
  ["ESC in host", "CONNECT \x1b[31mx:443 HTTP/1.1\r\n\r\n", "[ide-egress] DENY <invalid>:443 host\n"],
  ["IP literal", "CONNECT 1.2.3.4:443 HTTP/1.1\r\n\r\n", "[ide-egress] DENY 1.2.3.4:443 host\n"],
  ["disallowed host", "CONNECT example.com:443 HTTP/1.1\r\n\r\n", "[ide-egress] DENY example.com:443 host\n"],
  ["bad port", "CONNECT github.com:80 HTTP/1.1\r\n\r\n", "[ide-egress] DENY github.com:80 port\n"],
  ["bad request", "GET /secret?token=abc HTTP/1.1\r\nAuthorization: Bearer xyz\r\n\r\n", "[ide-egress] DENY <invalid>:- bad-request\n"],
  ["denied address", "CONNECT localhost:443 HTTP/1.1\r\n\r\n", "[ide-egress] DENY localhost:443 address\n"],
];
for (const [name, raw, want] of cases) {
  test(`one exact DENY line: ${name}`, async () => {
    const { out } = await send(raw);
    assert.equal(out, want);
    assert.ok(!out.includes("\x1b"));
  });
}

test("denied-address line never carries the resolved IP", async () => {
  const { out } = await send("CONNECT localhost:443 HTTP/1.1\r\n\r\n");
  assert.ok(!/127\.0\.0\.1|::1/.test(out), out);
});
