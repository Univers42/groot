# CSRF Resistance — auth-gateway (the auth BFF)

> State-changing auth operations are protected from cross-site request forgery through a combination of `SameSite=Lax` path-scoped cookies and a bearer-token architecture that prevents cookie-only cross-site exploitation.

## What it is (the concept)

**Cross-Site Request Forgery (CSRF)** is an attack in which a malicious third-party page causes a victim's browser to issue a credentialed HTTP request to a target origin — silently carrying the victim's cookies — without the victim's knowledge or intent. The classic defense is a **synchronizer token** (a per-session secret that the server embeds in forms and validates on submission). A modern, simpler complement is the **`SameSite` cookie attribute**, which instructs the browser to suppress cookie delivery on cross-site requests. A **bearer-token model** goes further: the sensitive credential lives in JavaScript memory, is sent as an `Authorization` header, and is therefore structurally unreachable by a cross-site attacker who cannot read the page's memory.

## What it defends against

See [Cross-Site Request Forgery (CSRF)](../../attack/csrf.md).

In this application, the auth-gateway is the single point through which session tokens and workspace credentials are issued and refreshed. A successful CSRF attack against either the refresh or the session-provisioning endpoint would let an attacker silently rotate tokens or obtain a signed session on behalf of a logged-in user, achieving full account takeover without knowing the user's password.

## How auth-gateway implements it

Two complementary mechanisms work together:

**1. `SameSite=Lax` + `Path=/api/auth` on the refresh cookie**

[`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs) — the `refreshCookie` helper (line 158) emits:

```js
// line 159
return `prismatica_refresh=${encodeURIComponent(token)}; HttpOnly; SameSite=Lax; Secure; Path=/api/auth; Max-Age=${maxAge}`;
```

`SameSite=Lax` allows the cookie only on same-site navigations and top-level GET requests, blocking it on cross-site `fetch`/`XMLHttpRequest`/`form POST`. `Path=/api/auth` further constrains cookie scope so no other path in the same origin can inadvertently trigger it. `HttpOnly` prevents JavaScript exfiltration. The `clearRefreshCookie` helper (line 162) applies the same attributes on logout, preventing a logout CSRF from leaving a stale cookie on a different path.

**2. Bearer-token requirement on the privileged session endpoint**

[`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs) — `bearerToken` (lines 138–141) parses the `Authorization` header exclusively:

```js
// lines 138-141
function bearerToken(request) {
    const header = request.headers.authorization ?? '';
    const value = Array.isArray(header) ? header[0] : header;
    return value.toLowerCase().startsWith('bearer ') ? value.slice(7).trim() : '';
}
```

`handleOsionosSession` (lines 1060–1065) calls `bearerToken` immediately and rejects with `401` if the result is empty:

```js
// lines 1060-1064
async function handleOsionosSession(request, response) {
    const accessToken = bearerToken(request);
    if (!accessToken) {
        json(response, 401, { message: 'Missing bearer token.' });
        return;
    }
```

A cross-site attacker controlling a third-party page can cause the victim's browser to send cookies automatically, but cannot read JavaScript memory on a different origin. The access token, held only in application memory, is structurally inaccessible to the attacker; without it the session endpoint returns `401`.

## How we know it is applied

The protection is enforced at the code path level, not through optional middleware:

- Every token issuance and refresh flows through `refreshCookie`, which unconditionally stamps `SameSite=Lax; Secure; Path=/api/auth` — there is no alternate code path that issues a cookie without these attributes.
- `handleOsionosSession` is the sole handler for workspace-session provisioning; it calls `bearerToken` before any business logic and returns early on an empty result, making bearer presence a hard gate.
- `clearRefreshCookie` (line 162) applies the same `SameSite=Lax; Path=/api/auth` attributes on logout, preventing a CSRF-driven logout from setting an unscoped cookie.

These controls are not feature-flagged and carry no environment check; they are unconditional in the production code path.

## Reference

The [CSRF Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html) (OWASP) is the canonical reference for both token-based and `SameSite`-based mitigations. This gateway implements the cheat sheet's **"Defense in Depth: Use SameSite Cookie Attribute"** guidance alongside its **"Token-based Mitigation"** analogue via the bearer model — two independent layers that together satisfy the cheat sheet's recommendation to avoid relying on any single mechanism.

## Residual risk / assumptions

- **No synchronizer / double-submit token.** The defense relies entirely on `SameSite=Lax` and the bearer architecture. `SameSite=Lax` does not block same-site sub-domain requests; if another sub-domain under the same eTLD+1 is compromised, cross-sub-domain CSRF is still possible.
- **Browser support assumed.** `SameSite=Lax` is enforced by the browser. Clients using non-conforming or legacy user agents (some embedded WebViews, some proxies) may deliver cookies on cross-site requests regardless of the attribute.
- **Bearer tokens in memory only.** The bearer model's CSRF immunity holds only if access tokens are stored in JavaScript memory (not in cookies or `localStorage`). If any upstream client persists the token in a cookie-accessible store, that guarantee collapses.
- **Path scoping is not origin isolation.** `Path=/api/auth` prevents other same-origin paths from accidentally sending the cookie, but it is not a security boundary — browser security models do not treat `Path` as an isolation primitive between same-origin resources.
- **CSRF on logout.** The `handleLogout` endpoint (line 1055) clears the cookie but does not require a bearer token. A CSRF-triggered logout forces a sign-out but does not leak credentials; the residual risk is a session-termination denial-of-convenience rather than account takeover.
