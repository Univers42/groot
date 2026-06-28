# CORS Origin Allowlist with Credentialed-Request Guard — osionos-bridge (website-to-editor trust boundary)

> The bridge reflects `Access-Control-Allow-Origin` only to origins that match a strict loopback/Tauri/app allowlist, preventing any external web origin from making credentialed cross-origin requests to the service-role-privileged proxy.

## What it is (the concept)

**Cross-Origin Resource Sharing (CORS)** is a browser-enforced protocol that restricts which origins may read responses from a different origin. The critical configuration surface is the `Access-Control-Allow-Origin` (ACAO) response header: if a server reflects the caller's `Origin` unconditionally, or uses a wildcard (`*`) alongside `Access-Control-Allow-Credentials: true`, the browser will forward the victim's session to any attacker-controlled site that issues the request. A **credentialed-request guard** pairs the ACAO allowlist with `Vary: Origin` to ensure that intermediate caches never serve a permissive ACAO header to an origin that should have received the restrictive fallback.

## What it defends against

See [CORS Misconfiguration](../../attack/cors-misconfiguration.md). In the osionos context, the bridge holds the BaaS **service-role key** and proxies PostgREST/Kong endpoints that bypass row-level security. An attacker who could trick a logged-in user's browser into making a cross-origin credentialed request to `https://localhost:4000` would receive a response the browser would ordinarily block — exposing workspace data, session tokens, or the ability to issue write mutations under the victim's identity. Because `Access-Control-Allow-Credentials: true` is required for the app's own session cookie/header flow, a wildcard ACAO is not an option; the allowlist is the only sound alternative.

## How osionos-bridge implements it

The mechanism is implemented entirely in [`apps/osionos/app/scripts/bridge-api.mjs`](../../../../apps/osionos/app/scripts/bridge-api.mjs).

**Per-request origin resolution — `requestOriginConfig` (lines 1335–1344):**

```js
function requestOriginConfig(config, request) {
    const origin = String(request.headers.origin ?? '');
    if (/^https?:\/\/(localhost|127\.0\.0\.1):\d+$/i.test(origin)
        || /^tauri:\/\/localhost$/i.test(origin)
        || /^https?:\/\/tauri\.localhost$/i.test(origin)
        || /^app:\/\/osionos$/i.test(origin)) {
        return { ...config, allowedOrigin: origin };
    }
    return config;
}
```

If the `Origin` header matches one of four patterns — `http(s)://localhost:<port>`, `http(s)://127.0.0.1:<port>`, `tauri://localhost`, `https://tauri.localhost`, or `app://osionos` — the function returns a per-request config object whose `allowedOrigin` is set to the literal request origin (safe reflection). Any other origin leaves `allowedOrigin` at the server's configured default (the bridge's own base URL), so no external origin is reflected.

**Response writers that propagate the per-request config:**

- `json()` (lines 1324–1332): sets `access-control-allow-origin: config.allowedOrigin`, `access-control-allow-credentials: true`, and `vary: Origin` on every JSON response.
- `writeOptionsResponse()` (lines 1505–1513): sets the same ACAO + credentials + `Vary: Origin` headers on every `OPTIONS` preflight, and restricts `access-control-allow-methods` to `GET, POST, PATCH, DELETE, OPTIONS` and `access-control-allow-headers` to the specific headers the app requires (`content-type`, `authorization`, `x-prismatica-bridge-timestamp`, `x-prismatica-bridge-signature`).
- `errorJson()` (line 1501–1502): delegates to `json()`, so error responses carry the same headers.

**Wiring — `createBridgeServer` (line 2635):**

```js
return createServer(async (request, response) => {
    let responseConfig = requestOriginConfig(config, request);
    // ...
    await handleBridgeRequest(request, response, { config: responseConfig, ... });
```

`requestOriginConfig` is the **first** call for every inbound request. The resolved `responseConfig` is then threaded through `handleBridgeRequest` and every downstream handler, so there is no code path that produces a response using a stale or global config object.

## How we know it is applied

The control is not aspirational: `requestOriginConfig` is called unconditionally inside the `createServer` callback at line 2635 — before any routing or handler dispatch — so every response (data, SSE, preflight, error) receives a CORS header derived from the allowlist evaluation. The `Vary: Origin` header on all responses means that a proxy or CDN in front of the bridge cannot cache a permissively-reflected ACAO and serve it to a different origin.

The bridge starts via `startBridgeServer` (line 2644), which listens on `0.0.0.0:${config.port}` (the Docker-internal port `4000`) — confirming this is the live production code path, not a test stub. The integration test suite (`npm run test:bridge`) exercises the website-to-editor auth handoff through this same server, so regressions in the CORS headers surface in CI.

## Reference

The [HTML5 Security Cheat Sheet — OWASP](https://cheatsheetseries.owasp.org/cheatsheets/HTML5_Security_Cheat_Sheet.html) documents the exact failure modes this control addresses: reflecting the `Origin` header without validation, omitting `Vary: Origin`, and permitting credentials with a wildcard ACAO. The osionos-bridge implementation maps directly onto the allowlisting pattern described there — explicit enumeration of trusted origins rather than pattern relaxation. The companion [Fetch Living Standard § CORS protocol](https://fetch.spec.whatwg.org/#http-cors-protocol) defines the browser-enforcement mechanics that make the allowlist effective.

## Residual risk / assumptions

- **Loopback port range is unrestricted.** The regex `^https?:\/\/(localhost|127\.0\.0\.1):\d+$` matches any port on loopback. On a shared developer machine, a malicious service bound to a loopback port could obtain a reflected ACAO. This is an accepted trade-off for development ergonomics; in production (no local stack exposed) no external service can bind a loopback port.
- **No enforcement outside the browser.** CORS is a browser policy. A server-to-server or `curl` request ignores ACAO headers entirely; the allowlist provides no protection against server-side request forgery or backend-to-backend calls. The bridge's HMAC timestamp/signature (`x-prismatica-bridge-timestamp`, `x-prismatica-bridge-signature`) headers are the defense-in-depth layer for non-browser callers.
- **Tauri and `app://` origins are trusted unconditionally.** The patterns `tauri://localhost`, `https://tauri.localhost`, and `app://osionos` match the Electron/Tauri desktop shell. If a malicious app registers one of these custom-scheme origins, it would receive a reflected ACAO. This is inherent to desktop-shell CORS and acceptable given that the desktop app is a first-party, locally-installed binary.
- **`allowedOrigin` default value is not shown here.** If the server's base `config.allowedOrigin` is misconfigured at startup (e.g., set to `*`), the fallback for non-matching origins would be a wildcard. The correctness of the guard depends on the deployment-time value of this config field, which is sourced from environment variables and not validated inside the allowlist function itself.
