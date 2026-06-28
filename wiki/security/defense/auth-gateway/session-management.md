# Session Management — auth-gateway (the auth BFF)

> The auth-gateway issues the refresh token exclusively through an `HttpOnly; Secure; SameSite=Lax; Path=/api/auth` cookie, strips it from every JSON response body, and rotates or invalidates it on every use — so client-side JavaScript can never read, persist, or replay the long-lived credential.

## What it is (the concept)

**Session management** is the discipline of creating, transporting, rotating, and destroying the credentials that represent an authenticated session after the password exchange is complete. In a BFF (Backend-For-Frontend) architecture the gateway — not the browser — owns the sensitive **refresh token**: it issues the token via a locked-down cookie, keeps it out of the JavaScript execution context, and enforces server-side validity on every use. The two complementary artifacts are the short-lived **access token** (returned in the JSON body, readable by JS, expires in minutes) and the long-lived **refresh token** (HttpOnly cookie only, opaque to JS, expires in 30 days).

## What it defends against

See [Session Hijacking / Session Fixation](../../attack/session-management.md).

In this application's threat model the primary vector is XSS stealing the refresh token from `localStorage` or a readable cookie, then silently obtaining fresh access tokens indefinitely. A secondary concern is a stale or server-invalidated refresh token continuing to work because the client never re-validates it. The gateway's controls address both: the cookie flags prevent JS read access entirely, and the rotation + fail-safe clearing ensure a compromised token is bounded by its first attempted reuse.

## How auth-gateway implements it

Three interlocking mechanisms, all in [`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs):

### 1 — HttpOnly + Secure + SameSite=Lax, path-scoped cookie

```js
// lines 158-163
function refreshCookie(token, maxAge = 60 * 60 * 24 * 30) {
    return `prismatica_refresh=${encodeURIComponent(token)}; HttpOnly; SameSite=Lax; Secure; Path=/api/auth; Max-Age=${maxAge}`;
}
function clearRefreshCookie() {
    return 'prismatica_refresh=; HttpOnly; SameSite=Lax; Secure; Path=/api/auth; Max-Age=0';
}
```

- **`HttpOnly`** — the browser never exposes this cookie to `document.cookie` or `fetch` response headers; XSS cannot read it.
- **`Secure`** — the browser refuses to transmit the cookie over plaintext HTTP.
- **`SameSite=Lax`** — the cookie is withheld on cross-site subresource and form-POST requests, blocking naive CSRF refresh-token harvesting.
- **`Path=/api/auth`** — the cookie is scoped to the single BFF path prefix; it is not sent on requests to any other origin path.
- **`Max-Age=2592000`** (30 days) for a live session; **`Max-Age=0`** on `clearRefreshCookie()` immediately expires the cookie server-side.

The cookie is set at login (line 917) and reissued at every successful refresh (line 1052). Logout (line 1057) and a failed refresh (line 1048) both emit the clearing cookie.

### 2 — Refresh token stripped from every JSON response body

```js
// lines 338-342
function sanitizeAuthPayload(payload) {
    const safePayload = { ...payload };
    delete safePayload.refresh_token;
    return safePayload;
}
```

`sanitizeAuthPayload` is the only path through which BaaS auth payloads are serialised to JSON. It is called unconditionally at login (line 918) and at every successful refresh (line 1052). This means the refresh token never appears in a response body that client-side JavaScript, browser DevTools network logs, or an intercepting proxy can observe.

### 3 — Refresh-token rotation with fail-safe cookie clearing

```js
// lines 1039-1052  (handleRefresh)
const refreshToken = decodeURIComponent(cookieValue(request, 'prismatica_refresh'));
if (!refreshToken) {
    json(response, 401, { message: 'No refresh session.' });
    return;
}
const result = await refreshAuthSession(refreshToken);
await audit(result.response.ok ? 'refresh_success' : 'refresh_failed', ...);
if (!result.response.ok) {
    json(response, 401, { message: 'Refresh session expired.' },
        { 'set-cookie': clearRefreshCookie() });
    return;
}
const nextRefreshToken = typeof result.payload.refresh_token === 'string'
    ? result.payload.refresh_token : refreshToken;
json(response, 200, sanitizeAuthPayload(result.payload),
    { 'set-cookie': refreshCookie(nextRefreshToken) });
```

On every call to `POST /api/auth/refresh`:

- The old cookie value is read server-side (never re-exposed).
- The BaaS `refreshSession` call rotates the token at the identity provider level.
- On success a **new** cookie is set, replacing the old token; the old token is now invalid at the BaaS.
- On failure (expired, revoked, or network error) the gateway returns 401 **and** clears the cookie, preventing silent re-use of an already-invalid token.
- Absence of the cookie is an immediate 401 — the gateway never falls back to a query-string or body token.

Both outcomes are durably logged via `audit('refresh_success' | 'refresh_failed', ...)`.

## How we know it is applied

The route is registered in the live handler map (line 1131):

```js
['POST /api/auth/refresh', handleRefresh],
```

The `routes` map is the sole dispatch table for the HTTP server (lines 1126-1137). Every request to `POST /api/auth/refresh` goes through `handleRefresh`; there is no alternative code path. The `set-cookie` header emitted by `refreshCookie()` / `clearRefreshCookie()` is observable in any HTTP client hitting the live gateway at `https://localhost:8787/api/auth/refresh`.

Additionally, `audit()` records `refresh_success` and `refresh_failed` events to the BaaS RPC `auth_record_audit_event`, giving an out-of-band audit trail of every rotation attempt (line 1046).

## Reference

The [OWASP Session Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html) codifies the cookie attribute requirements (`HttpOnly`, `Secure`, `SameSite`) and the token-rotation discipline that this gateway implements. It also covers the complementary concern of binding session lifetime to explicit logout — reflected here by `clearRefreshCookie()` being called in both `handleLogout` and the failure branch of `handleRefresh`.

## Residual risk / assumptions

- **Access token not revocable in-flight.** The short-lived access token is returned in the JSON body and is intentionally readable by client JS. If an access token is stolen (e.g., via XSS reading memory rather than cookies), it remains valid until it expires. The gateway has no mechanism to revoke an already-issued access token.
- **BaaS rotation fidelity.** Token rotation is only as strong as the upstream GoTrue/grobase session revocation. If the BaaS does not invalidate the previous refresh token immediately on rotation, a narrow replay window exists.
- **`SameSite=Lax` is not full CSRF protection.** Lax blocks cross-site POST but not same-site requests. CSRF on `POST /api/auth/refresh` is blocked only for cross-origin top-level navigations; full protection for non-idempotent endpoints depends on the CORS policy and any CSRF token layer applied elsewhere.
- **No device binding.** The refresh cookie is not bound to a client fingerprint (IP, User-Agent). If the raw cookie value were extracted from the browser cookie store (local compromise), it could be replayed from a different device until the BaaS session expires or is revoked server-side.
- **TLS termination is assumed.** `Secure` only prevents transmission over HTTP; the gateway trusts the upstream TLS layer (Caddy / Nginx). A misconfigured proxy that downgrades to HTTP would strip the `Secure` guarantee without the gateway detecting it.
