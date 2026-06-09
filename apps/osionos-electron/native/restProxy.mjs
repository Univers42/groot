// ===========================================================================
// osionos NATIVE edition — tiny /rest/v1 → PostgREST rewrite shim.
//
// The (unchanged) bridge calls `${OSIONOS_BAAS_URL}/rest/v1/<table>`; PostgREST
// serves tables at the root (`/<table>`). Kong does that rewrite in the Docker
// stack; the native edition drops Kong, so this ~loopback shim does it instead —
// strip the `/rest/v1` prefix and forward method/headers/body to PostgREST.
// Loopback only; no auth logic (PostgREST validates the JWT the bridge forwards).
//
// Pure Node http — no deps.
// ===========================================================================
import http from "node:http";

const PREFIX = "/rest/v1";

export function startRestProxy({ listenPort, postgrestUrl }) {
  const target = new URL(postgrestUrl);
  const server = http.createServer((req, res) => {
    // Strip the prefix; anything outside it is a 404 (nothing else is proxied).
    const path = req.url.startsWith(PREFIX) ? req.url.slice(PREFIX.length) || "/" : null;
    if (path === null) { res.writeHead(404).end(); return; }
    const upstream = http.request(
      { hostname: target.hostname, port: target.port, path, method: req.method, headers: { ...req.headers, host: target.host } },
      (up) => { res.writeHead(up.statusCode || 502, up.headers); up.pipe(res); },
    );
    upstream.on("error", () => { if (!res.headersSent) res.writeHead(502); res.end('{"error":"rest proxy upstream failed"}'); });
    req.pipe(upstream);
  });
  return new Promise((resolve) => server.listen(listenPort, "127.0.0.1", () => resolve(server)));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.env.REST_PROXY_PORT || 4010);
  startRestProxy({ listenPort: port, postgrestUrl: process.env.POSTGREST_URL || "http://127.0.0.1:3000" })
    .then(() => console.log(`[rest-proxy] :${port}${PREFIX}/* -> ${process.env.POSTGREST_URL || "http://127.0.0.1:3000"}`));
}
