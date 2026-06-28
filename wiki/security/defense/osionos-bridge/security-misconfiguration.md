# Security Misconfiguration Hardening — osionos-bridge (website-to-editor trust boundary)

> The bridge normalizes every upstream BaaS error status through a fixed three-class mapping, caps error text at 160 characters, and stamps `Cache-Control: no-store` on all JSON and SSE responses, so raw internal state never reaches a browser cache or an attacker watching the wire.

## What it is (the concept)

**Security misconfiguration** is the failure to apply secure settings to a system component — leaving it in a state that leaks internal structure, exposes default credentials, or discloses more error detail than an external caller needs. In a proxy or trust-boundary service the most common form is **information leakage**: forwarding upstream HTTP status codes, stack traces, or full error bodies verbatim to clients. A second form is **improper caching**: letting authenticated JSON responses be stored by intermediary proxies or browser caches, which can expose session-bearing payloads to later, unauthorized retrievals.

## What it defends against

See [Security Misconfiguration Exploitation](../../attack/security-misconfiguration.md).

An attacker probing the bridge can use raw upstream status codes to fingerprint internal auth states — distinguishing "no JWT presented" (401) from "JWT valid but authorization denied" (403) lets them probe the permission model. Equally, a full upstream error body can leak table names, PostgREST grammar, or grobase internals. If an authenticated response is cached by a shared reverse proxy or browser cache, a second user on the same machine or network segment can retrieve it without credentials.

## How osionos-bridge implements it

All three mechanisms live in `apps/osionos/app/scripts/bridge-api.mjs`.

**Status code normalization — `responseStatusForBaasFailure` (lines 296–300):**

```js
function responseStatusForBaasFailure(status) {
    if (status === 401 || status === 403) return 403;
    if (status === 404) return 404;
    return 502;
}
```

Both upstream BaaS call wrappers apply this mapping unconditionally on every non-OK upstream response. `baasRest` (line 470) uses it for PostgREST/Kong calls; `baasQueryPost` (line 497) uses it for the internal query-router. The result is a three-class vocabulary: permission failure → 403, resource absent → 404, everything else (5xx, unexpected 4xx, network failure) → 502. No raw upstream code reaches the client.

**Error text truncation — `baasRest` (line 471) and `baasQueryPost` (line 498):**

```js
throw Object.assign(
  new Error(`BaaS request failed with ${response.status}: ${text.slice(0, 160)}`),
  { status }
);
```

Both wrappers read the raw upstream body as text then truncate to 160 characters before embedding it in the thrown error. The global error handler (`errorJson`, line 1502) forwards `error.message` to the client, so the maximum upstream detail a client can receive is 160 characters of (already-normalized) error text — not a full PostgREST or Kong response body.

**`Cache-Control: no-store` on all responses — `json()` (line 1327) and SSE handler (line 1440):**

```js
function json(response, status, body, config) {
    response.writeHead(status, {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
        'access-control-allow-origin': config.allowedOrigin,
        ...
    });
    response.end(JSON.stringify(body));
}
```

`json()` is the sole JSON response-writing primitive in the file. Every route handler (success and error paths), the global catch block at `createBridgeServer` (line 2639), and the `errorJson` fallback (line 1502) all pass through it. SSE streaming responses (line 1440) independently set the same header. There is no code path that writes an HTTP response body without setting `no-store`.

## How we know it is applied

The proof is structural, not aspirational. `createBridgeServer` (line 2613) wraps the entire request lifecycle in a single try/catch:

```js
return createServer(async (request, response) => {
    let responseConfig = requestOriginConfig(config, request);
    try {
        await handleBridgeRequest(request, response, { config: responseConfig, ... });
    } catch (error) {
        if (!response.headersSent) errorJson(response, error, responseConfig);
    }
});
```

`errorJson` calls `json()`, which always sets `cache-control: no-store`. Because `json()` is the only function that calls `response.writeHead` + `response.end` for JSON bodies (confirmed by grepping the file: every non-SSE, non-OPTIONS terminal write is a `json(response, ...)` call), the header is applied universally — including on the uncaught-error path. The bridge test suite at `tests/bridge/bridge-api.test.mjs` imports `createBridgeServer` and exercises the route dispatcher (page list, read, create, patch, delete), which means the test-gated `npm run test:bridge` gate exercises the same `json()` path on every response.

## Reference

[A05 Security Misconfiguration — OWASP Top 10:2021](https://owasp.org/Top10/2021/A05_2021-Security_Misconfiguration/) identifies forwarding raw server errors and leaving default configurations in place as the primary attack surface. In a BaaS proxy the risk is concrete: each extra byte of upstream detail handed to a client is a probe the attacker does not have to make themselves.

## Residual risk / assumptions

- **Error message content is not sanitized, only truncated.** The first 160 characters of an upstream error body can still contain partial table names, column identifiers, or PostgREST filter grammar if grobase returns verbose errors. The 160-char limit reduces but does not eliminate this.
- **`no-store` applies to the bridge's own HTTP responses only.** If an intermediary (e.g., the Kong gateway at port 8000) forwards a response to a browser without this header, caching can still occur on the Kong→browser leg; this control does not govern that leg.
- **Status normalization in `queryRouterStatus` (lines 302–306) adds a 503 class** for query-router-specific patterns (engine not mounted, data-plane forward failures). This function delegates to `responseStatusForBaasFailure` for all other cases, so the mapping contract holds; but the 503 branch is pattern-matched against the raw body before truncation — a sufficiently long match text could momentarily hold the full body in memory before the slice is applied in the caller.
- **The test suite exercises happy and auth-failure paths but does not assert response headers.** The `cache-control: no-store` guarantee rests on code inspection and the single-writer invariant, not on an automated assertion that would fail if the header were removed.
