# Session Management — opposite-osiris (marketing + auth website)

> The refresh token is confined to an `HttpOnly; Secure; SameSite=Lax; Path=/api/auth` cookie and is never exposed to JavaScript; the short-lived access token lives only in memory and is never persisted to any browser storage.

## What it is (the concept)

**Session management** is the set of mechanisms that create, maintain, and destroy authenticated sessions in a way that prevents token theft or reuse by an attacker. A well-designed scheme separates **access tokens** (short-lived bearer credentials sent on every API call) from **refresh tokens** (long-lived credentials used only to reissue access tokens). The **`HttpOnly`** cookie flag blocks JavaScript from reading the refresh token; **`Secure`** prevents transmission over plain HTTP; **`SameSite`** restricts cross-site cookie inclusion; **`Path`** scoping limits which requests carry the cookie at all.

## What it defends against

See [Session Hijacking / Session Fixation](../../attack/session-management.md).

In this application, the primary risk vectors are XSS attacks that attempt to exfiltrate tokens from `localStorage` or `document.cookie`, and cross-site requests that attempt to replay a stolen refresh token against the `/api/auth` renewal endpoint. Because opposite-osiris is the public-facing auth surface (login, register, OAuth callbacks), a token leak here would compromise all downstream authenticated state in both the block editor and the bridge.

## How opposite-osiris implements it

**Cookie hardening — `apps/opposite-osiris/scripts/auth-gateway.mjs`**

The `refreshCookie` and `clearRefreshCookie` helpers are the single point of cookie construction in the auth gateway:

```js
// lines 158–163
function refreshCookie(token, maxAge = 60 * 60 * 24 * 30) {
    return `prismatica_refresh=${encodeURIComponent(token)}; HttpOnly; SameSite=Lax; Secure; Path=/api/auth; Max-Age=${maxAge}`;
}
function clearRefreshCookie() {
    return 'prismatica_refresh=; HttpOnly; SameSite=Lax; Secure; Path=/api/auth; Max-Age=0';
}
```

Every authenticated response (login, OAuth callback, token refresh) sets the cookie through `refreshCookie`; every logout or expiry clears it through `clearRefreshCookie`. There is no other code path that writes `prismatica_refresh`.

**Refresh-token stripping from response bodies — `apps/opposite-osiris/scripts/auth-gateway.mjs`**

The `sanitizeAuthPayload` function is applied to every JSON response returned by the `handleLogin` and `handleRefresh` handlers, removing the `refresh_token` field before it reaches the client:

```js
// lines 338–341
function sanitizeAuthPayload(payload) {
    const safePayload = { ...payload };
    delete safePayload.refresh_token;
    return safePayload;
}
```

This ensures that even if the upstream BaaS includes `refresh_token` in its JSON body, it is stripped server-side before the browser receives the response. Client JavaScript therefore never has access to the refresh token through any channel — neither the cookie (blocked by `HttpOnly`) nor the response body (removed by `sanitizeAuthPayload`).

**In-memory-only access token — `apps/opposite-osiris/src/scripts/main.ts`**

The access token is stored in a module-scoped variable and explicitly never written to `localStorage`, `sessionStorage`, or any cookie:

```ts
// lines 93–99
/**
 * The short-lived ACCESS token lives only in memory for the lifetime of the
 * page. It is never persisted to localStorage/sessionStorage/cookies, so an XSS
 * cannot read it from storage. The long-lived REFRESH token is held by the
 * server as an HttpOnly Secure cookie and drives rehydration on each page load.
 */
let accessToken: string | null = null;
```

Session rehydration on page load exchanges the `HttpOnly` refresh cookie for a new access token by posting to `/api/auth/refresh` with `credentials: 'include'` (lines 501–504 of the same file), so the refresh cookie is sent automatically by the browser without JavaScript ever reading it.

## How we know it is applied

The controls are structurally enforced, not advisory:

- `refreshCookie` / `clearRefreshCookie` are the **only** functions that produce a `Set-Cookie` header for `prismatica_refresh`; both always include `HttpOnly; Secure; SameSite=Lax; Path=/api/auth`. There is no alternate code path that omits these attributes.
- `sanitizeAuthPayload` is called unconditionally in `handleLogin` and `handleRefresh` before any `Response` containing auth data is returned. A refresh token cannot appear in a response body without passing through this function first.
- The `accessToken` variable in `main.ts` has no `localStorage.setItem` call anywhere in its scope; the only setter is `setAccessToken(token)` which assigns to the module-level `let` binding.

## Reference

The [OWASP Session Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html) defines authoritative guidance for cookie attributes, token lifecycle, and secure storage. opposite-osiris directly implements the cheat sheet's recommendations on `HttpOnly` + `Secure` + `SameSite` cookie flags, path-scoped refresh tokens, and keeping bearer tokens out of persistent browser storage.

## Residual risk / assumptions

- **In-memory access token survives XSS within the page lifetime.** If an XSS payload executes in the same page context before the tab is closed, it can call `getAccessToken()` directly (the function is module-private in TypeScript but compiled to a closure that a same-origin script could theoretically reach via prototype manipulation or if the bundle is not properly encapsulated). A Content Security Policy that blocks inline scripts is the complementary control; see [`security-headers-csp.md`](security-headers-csp.md).
- **`SameSite=Lax` does not block top-level navigations.** A CSRF attack that triggers a GET-based navigation to `/api/auth/*` would carry the refresh cookie. The `/api/auth` endpoints are POST-only, which mitigates this in practice, but an attacker-controlled redirect chain could theoretically be crafted.
- **`Path=/api/auth` scoping.** Any misconfiguration that adds a new auth endpoint outside `/api/auth` would receive the refresh cookie. The gateway's single-file architecture (`auth-gateway.mjs`) makes this easy to audit but is not enforced by a runtime policy.
- **No token rotation on every refresh.** If the refresh token is stolen out-of-band (e.g., network interception on non-HTTPS, compromised server), the `Max-Age=30d` window gives an attacker a long exploitation period. Rotation on use would reduce this window at the cost of additional state management.
- **Trust in the BaaS upstream.** `sanitizeAuthPayload` strips `refresh_token` from the body but trusts the upstream to return a correctly structured JSON object. A malformed or unexpected response field (e.g., `refresh_token` nested inside another key) would not be stripped.
