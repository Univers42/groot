# CORS Locked to a Single Configured Origin, Never Wildcard-with-Credentials — opposite-osiris (marketing + auth website)

> The auth gateway's preflight handler returns `Access-Control-Allow-Origin` set to the exact configured site URL with `Access-Control-Allow-Credentials: true`, and never reflects arbitrary or wildcard origins — preventing any cross-origin actor from reading credentialed API responses.

---

## What it is (the concept)

**Cross-Origin Resource Sharing (CORS)** is a browser mechanism that controls which origins may read responses to cross-origin requests. A **CORS misconfiguration** occurs when a server either reflects the caller's `Origin` header unconditionally, uses a **wildcard** (`*`) alongside `Access-Control-Allow-Credentials: true`, or applies an overly broad allowlist. A correctly implemented **origin allowlist** restricts access to a finite, explicitly enumerated set of trusted origins, ensuring the browser refuses to hand credentialed response bodies to any other party.

---

## What it defends against

See [CORS Misconfiguration](../../attack/cors-misconfiguration.md).

In the opposite-osiris context the auth gateway issues session cookies and JWT tokens through its `/api/auth/*` routes. A misconfigured CORS policy would allow an attacker-controlled page to make credentialed cross-origin requests to those endpoints and read the responses — leaking session data, user metadata, or MFA state. Because the gateway enforces a single fixed origin, a malicious site on any other origin receives a preflight denial and the browser blocks the read.

---

## How opposite-osiris implements it

**1. Preflight handler — `apps/opposite-osiris/scripts/auth-gateway.mjs` (line 1143-1147)**

The Node.js HTTP server intercepts every `OPTIONS` request and writes a hardcoded 204 response whose `Access-Control-Allow-Origin` value is sourced exclusively from `config.siteUrl`:

```js
// auth-gateway.mjs:1143-1144
if (request.method === 'OPTIONS') {
    response.writeHead(204, {
        'access-control-allow-origin': config.siteUrl,
        'access-control-allow-credentials': 'true',
        'access-control-allow-methods': 'GET, POST, OPTIONS',
        'access-control-allow-headers': 'content-type, authorization'
    });
```

`config.siteUrl` is resolved at startup from the environment variable `PUBLIC_SITE_URL` with a safe local fallback (line 56):

```js
// auth-gateway.mjs:56
siteUrl: process.env.PUBLIC_SITE_URL ?? 'http://localhost:4322',
```

No request-supplied `Origin` header is ever echoed back. The allowed methods and headers are a fixed, minimal allowlist — no wildcard token is present anywhere in the response.

**2. Environment injection — `docker-compose.yml` (line 345)**

`PUBLIC_SITE_URL` is set per-environment at container start:

```yaml
PUBLIC_SITE_URL: https://localhost:${OPPOSITE_OSIRIS_HOST_PORT:-4322}
```

This means the live allowed origin is always the exact TLS URL of the opposite-osiris frontend, not a pattern or prefix match.

---

## How we know it is applied

`apps/opposite-osiris/scripts/security/01-cors.mjs` is a runnable live-stack assertion that fires three independent checks against the real gateway:

| Check | Assertion |
|---|---|
| `allowed preflight policy` | Confirms the allowed origin is echoed exactly, credentials are `true`, and each required method/header is present |
| `disallowed origin is not echoed` | Sends a preflight from an attacker-controlled origin and asserts `Access-Control-Allow-Origin` is **not** reflected |
| `no wildcard with credentials` | Asserts that a credentialed response never carries `Access-Control-Allow-Origin: *` |

Key assertions from the script (lines 36, 58, 68):

```js
assert.equal(response.headers.get('access-control-allow-origin'), config.allowedOrigin);
// ...
assert.notEqual(response.headers.get('access-control-allow-origin'), config.disallowedOrigin);
// ...
assert.notEqual(response.headers.get('access-control-allow-origin'), '*');
```

These checks target the live BaaS gateway (`restUrl('/users')`) using `fetchWithTimeout`, so a passing run confirms both the auth gateway's own preflight responses and the upstream BaaS CORS policy simultaneously.

---

## Reference

The OWASP HTML5 Security Cheat Sheet documents the exact browser behaviour exploited by CORS misconfigurations, including the prohibition on pairing `*` with `Access-Control-Allow-Credentials: true` and the risk of origin reflection patterns. Consulting it clarifies precisely which header combinations the browser will and will not enforce, which informed the three-check structure in `01-cors.mjs`.

**OWASP HTML5 Security Cheat Sheet** — Cross-Origin Resource Sharing section:
<https://cheatsheetseries.owasp.org/cheatsheets/HTML5_Security_Cheat_Sheet.html>

---

## Residual risk / assumptions

- **Non-OPTIONS requests are not filtered here.** The gateway's preflight handler returns correct CORS headers, but actual GET/POST responses do not independently echo `Access-Control-Allow-Origin`. This is acceptable because browsers will not expose a response body without a matching preflight grant, but any future middleware that adds permissive CORS headers to real responses would bypass this control.
- **The allowed origin is a single string, not a parsed set.** If `PUBLIC_SITE_URL` is misconfigured (e.g., set to `*` or an attacker-controlled value at deploy time), the gateway will faithfully reflect that value. The security property depends on correct environment injection at build/run time.
- **BaaS CORS is asserted, not enforced, by this app.** `01-cors.mjs` checks that the upstream grobase gateway (Kong) also refuses wildcard-with-credentials, but opposite-osiris cannot enforce that policy — it can only detect drift.
- **No CORS policy on the Astro SSR layer itself.** The static/SSR frontend (served by Docker on port 4322) relies on the auth gateway's CORS for API routes. Browser-level cross-origin access to the Astro-rendered HTML pages is not restricted by the same mechanism.
