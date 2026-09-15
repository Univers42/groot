# CORS Scoped to Single Website Origin — auth-gateway (the auth BFF)

> The auth-gateway answers every CORS preflight with `Access-Control-Allow-Origin` fixed to the
> single opposite-osiris website origin (`PUBLIC_SITE_URL`), never reflecting the caller's `Origin`
> header and never emitting a wildcard — preventing any third-party site from making credentialed
> cross-origin requests to auth endpoints.

## What it is (the security concept)

**Cross-Origin Resource Sharing (CORS)** is the browser mechanism that decides whether a
cross-origin script may read a response. A server that controls which origins it allows by returning
a static, pre-configured value in `Access-Control-Allow-Origin` is applying an **origin allowlist**.
The complement — returning whatever `Origin` the caller sends — is **origin reflection**, the
canonical misconfiguration. Pairing `Access-Control-Allow-Credentials: true` with a wildcard (`*`)
is separately illegal in the CORS spec and signals an unsafe configuration at a glance.

## What it defends against

See [CORS Misconfiguration](../../attack/cors-misconfiguration.md).

An attacker who tricks a logged-in user into visiting a malicious page can use `fetch()` with
`credentials: 'include'` to send the user's session cookie to auth endpoints. If the gateway
reflected any `Origin` or answered with `*`, the browser would hand the response body — tokens,
session data, profile details — to the attacker's script. Because the auth-gateway holds session
cookies and acts as the auth BFF for the whole product, a CORS bypass here is equivalent to session
hijacking.

## How auth-gateway implements it

**Single entry point for all CORS policy — `auth-gateway.mjs` lines 1143-1147.**

The HTTP server's request handler intercepts every `OPTIONS` request before it reaches any route:

```js
// apps/opposite-osiris/scripts/auth-gateway.mjs  lines 1143-1147
if (request.method === 'OPTIONS') {
    response.writeHead(204, {
        'access-control-allow-origin':      config.siteUrl,
        'access-control-allow-credentials': 'true',
        'access-control-allow-methods':     'GET, POST, OPTIONS',
        'access-control-allow-headers':     'content-type, authorization',
    });
    response.end();
    return;
}
```

`config.siteUrl` is sourced exclusively from the environment variable `PUBLIC_SITE_URL`
(line 56: `siteUrl: process.env.PUBLIC_SITE_URL ?? 'http://localhost:4322'`). The value is never
derived from, nor compared to, the incoming `Origin` header — no reflection path exists in the
codebase. A `grep` of the entire file finds `access-control-allow-origin` in exactly one location.

**Allowed origin pinned at compose up-time — `docker-compose.yml` line 345.**

```yaml
PUBLIC_SITE_URL: https://localhost:${OPPOSITE_OSIRIS_HOST_PORT:-4322}
```

The environment variable is injected into the auth-gateway container at startup, fixing the allowed
origin to the opposite-osiris website. Changing it requires a compose restart with a different
`.env.local` value — there is no runtime knob.

**Method and header allowlist is minimal.** Only `GET`, `POST`, and `OPTIONS` are declared; only
`content-type` and `authorization` are allowed as request headers. Cookies, custom tracking headers,
and unsafe method verbs (`PUT`, `DELETE`, `PATCH`) are not listed and will be blocked at the
preflight stage.

## How we know it is applied

**Important scope note:** the security suite does not directly probe the auth-gateway's own
`/api/auth/*` paths. The assertions below run against the BaaS (Kong) REST endpoint
(`restUrl('/users')`); they verify BaaS CORS invariants, not auth-gateway CORS. See Residual risk
for the open gap.

`apps/opposite-osiris/scripts/security/01-cors.mjs` sends preflights to `restUrl('/users')` as
part of `npm run test:security`
(`package.json` line 28: `"test:security": "node scripts/container-only.mjs node scripts/security/run-all.mjs"`).
It checks three BaaS CORS invariants:

1. **`allowed preflight policy`** — asserts the configured allowed origin receives
   `access-control-allow-origin` equal to `config.allowedOrigin` and
   `access-control-allow-credentials: true`. It also verifies Supabase-specific methods (`PUT`,
   `PATCH`, `DELETE`) and headers (`x-supabase-api-version`) that are specific to Kong, not the
   auth-gateway.
2. **`disallowed origin is not echoed`** — sends a preflight with `Origin: http://evil.example.com`
   (the default `config.disallowedOrigin`) and asserts the response does not echo it:
   ```js
   assert.notEqual(response.headers.get('access-control-allow-origin'), config.disallowedOrigin);
   ```
3. **`no wildcard with credentials`** — asserts that when credentials are enabled, the ACAO header
   is never `*`:
   ```js
   assert.notEqual(response.headers.get('access-control-allow-origin'), '*');
   ```

`run-all.mjs` imports `01-cors.mjs` as the first category (`'cors'`) and exits with code 1 on any
failure, making it suitable as a CI gate. `package.json` line 42 also exposes
`"baas:verify:cors": "node scripts/container-only.mjs node scripts/verify-cors.mjs"` for a focused
standalone CORS probe against the BaaS (Kong) REST endpoint.

The auth-gateway's own CORS response (line 1144 of `auth-gateway.mjs`) is enforced in code but has
no equivalent automated integration test that sends an `OPTIONS` request to `/api/auth/` and
asserts the response headers.

## Reference

The OWASP HTML5 Security Cheat Sheet
([HTML5 Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/HTML5_Security_Cheat_Sheet.html))
dedicates a section to CORS, covering the exact scenarios this control addresses: credentialed
responses, wildcard prohibition, and the dangers of dynamic origin reflection. The guidance maps
directly to the three assertions in `01-cors.mjs`, which were structured to verify each
OWASP-recommended invariant in an automated, testable way.

## Residual risk / assumptions

- **Preflight-only scope.** The `Access-Control-Allow-Origin` header is emitted solely in the
  `OPTIONS` branch. Actual `GET` and `POST` responses do not carry ACAO. The browser SOP blocks
  cross-origin reads of those responses without ACAO, so the protection holds — but any future
  handler that calls `response.writeHead` with a reflected origin would bypass it silently.
- **`PUBLIC_SITE_URL` trust.** The control is only as strong as the configured value. If
  `PUBLIC_SITE_URL` is set to a wide domain (e.g., `https://*.example.com`) or left unset on a
  production deployment (falling back to `http://localhost:4322`), the policy degrades. No runtime
  validation of the value's format is performed.
- **Gateway reachability assumption.** The auth-gateway is expected to sit behind the nginx TLS
  reverse proxy (compose topology) and not be directly reachable from the internet. CORS is a
  browser control; a non-browser client ignores it entirely, so network-level access controls remain
  necessary complements.
- **`01-cors.mjs` target.** The security suite's CORS checks probe the BaaS (Kong) REST endpoint
  (`restUrl('/users')`), not the auth-gateway's own `/api/auth/*` paths. There is no automated live
  assertion that sends an `OPTIONS` request directly to the auth-gateway and verifies the response
  headers. A dedicated integration test against `https://localhost:8787/api/auth/` would close this
  gap.
