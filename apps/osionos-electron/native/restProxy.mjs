// ===========================================================================
// osionos NATIVE edition — loopback prefix-routing shim (replaces Kong).
//
// The gateway's @mini-baas SDK and the bridge call a single base URL with Kong's
// path conventions: `/rest/v1/*` (data → PostgREST) and `/auth/v1/*` (auth →
// gotrue). Kong does that routing in the Docker stack; the native edition drops
// Kong, so this ~loopback shim strips the prefix and forwards to the right local
// service. Loopback only; the upstreams validate the JWT the caller forwards.
//
// Pure Node http — no deps.
// ===========================================================================
import http from "node:http";

// routes: [{ prefix: "/rest/v1", target: "http://127.0.0.1:33001" }, ...]
export function startRestProxy({ listenPort, routes }) {
  const compiled = routes.map((r) => ({ prefix: r.prefix, target: new URL(r.target) }));
  const server = http.createServer((req, res) => {
    const url = req.url || "/";
    const route = compiled.find((r) => url === r.prefix || url.startsWith(`${r.prefix}/`) || url.startsWith(`${r.prefix}?`));
    if (!route) { res.writeHead(404).end('{"error":"no route"}'); return; }
    const path = url.slice(route.prefix.length) || "/";
    const t = route.target;
    const upstream = http.request(
      { hostname: t.hostname, port: t.port, path, method: req.method, headers: { ...req.headers, host: t.host } },
      (up) => { res.writeHead(up.statusCode || 502, up.headers); up.pipe(res); },
    );
    upstream.on("error", () => { if (!res.headersSent) res.writeHead(502); res.end('{"error":"rest proxy upstream failed"}'); });
    req.pipe(upstream);
  });
  return new Promise((resolve) => server.listen(listenPort, "127.0.0.1", () => resolve(server)));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.env.REST_PROXY_PORT || 4010);
  startRestProxy({ listenPort: port, routes: [
    { prefix: "/rest/v1", target: process.env.POSTGREST_URL || "http://127.0.0.1:33001" },
    { prefix: "/auth/v1", target: process.env.GOTRUE_URL || "http://127.0.0.1:9999" },
  ] }).then(() => console.log(`[rest-proxy] :${port} /rest/v1->postgrest /auth/v1->gotrue`));
}
