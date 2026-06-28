# Server-Side Request Forgery (SSRF) / Open-Redirect Guard — opposite-osiris (marketing + auth website)

> After the osionos bridge returns a session redirect URL, opposite-osiris rejects and blocks any URL whose origin does not exactly match the configured osionos app origin — enforced independently at both the server (auth gateway) and the browser (client-side navigation guard).

## What it is (the concept)

**Server-Side Request Forgery (SSRF)** is an attack where an adversary causes a server to issue HTTP requests to an unintended destination — often an internal resource or an attacker-controlled host. A closely related variant, the **open redirect**, occurs when an application navigates (or forwards a user) to a URL supplied or influenced by an external party without validating that the destination is trusted. In the opposite-osiris session handoff flow the osionos bridge returns a `redirectUrl` that the gateway relays and the browser follows; if that URL can be manipulated it becomes a vector for **token theft** or **navigation to an attacker-controlled origin**.

## What it defends against

See [Server-Side Request Forgery (SSRF)](../../attack/ssrf.md).

During the cross-app session handoff — when a logged-in opposite-osiris user is redirected into the osionos block editor — the auth gateway contacts the osionos bridge and receives a `redirectUrl` in the response body. Without origin validation, a compromised bridge response or a network-level injection could supply an attacker URL, causing both the server and the browser to forward the authenticated user (and their session token) to an untrusted host.

## How opposite-osiris implements it

The protection is applied at two independent layers:

**Layer 1 — Server-side gateway check**
[`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs), line 1113:

```js
if (result.ok && config.osionosAppUrl && typeof body?.redirectUrl === 'string'
    && !body.redirectUrl.startsWith(config.osionosAppUrl)) {
    await audit('osionos_bridge_redirect_rejected', request, { email, status: result.status });
    json(response, 502, { message: 'osionos bridge returned an unexpected redirect target.' });
    return;
}
```

Before forwarding the bridge response to the browser, `handleOsionosSession` asserts that `body.redirectUrl` starts with `config.osionosAppUrl` (derived from `process.env.PUBLIC_OSIONOS_APP_URL` at line 69 with trailing slash stripped). A mismatch yields an audited `502` — the redirect never reaches the client.

**Layer 2 — Client-side origin equality check**
[`apps/opposite-osiris/src/scripts/main.ts`](../../../../apps/opposite-osiris/src/scripts/main.ts), lines 534–544 (`isTrustedOsionosRedirect`):

```ts
function isTrustedOsionosRedirect(redirectUrl: string): boolean {
    const expectedOrigin = String(import.meta.env.PUBLIC_OSIONOS_APP_URL ?? '').trim();
    if (!expectedOrigin) return false;
    try {
        return new URL(redirectUrl).origin === new URL(expectedOrigin).origin;
    } catch { return false; }
}
```

The browser independently parses both URLs with the `URL` constructor and compares `.origin` values (scheme + host + port). A malformed URL (parse error) returns `false`, as does any origin mismatch. This guard is invoked at line 1774 before `window.location.assign()` or equivalent navigation; a failure surfaces a user-visible error toast and an accessibility announcement instead of navigating (lines 1775–1782).

The two layers use deliberately different comparison strategies — prefix match on the server (`startsWith`) and parsed-origin equality in the browser (`new URL().origin`) — so neither alone is the single point of failure.

## How we know it is applied

Both checks are in the live code paths that execute on every session handoff:

- Gateway: `handleOsionosSession` is registered as `POST /api/auth/osionos-session` (line 1133 of `auth-gateway.mjs`) and the URL check at line 1113 executes before the response is forwarded.
- Browser: the call at line 1774 of `main.ts` is inside the authenticated session handler that runs after `authClient.osionosSession()` returns a successful response — `isTrustedOsionosRedirect` must return `true` or navigation is aborted.
- `config.osionosAppUrl` is populated from `PUBLIC_OSIONOS_APP_URL` (gateway line 69); the same env var seeds `import.meta.env.PUBLIC_OSIONOS_APP_URL` in the Astro/Vite build, so both layers share a single source of truth wired through `docker-compose.yml`.
- The server emits an audit event (`osionos_bridge_redirect_rejected`) on every rejection, producing a traceable log entry without exposing the bad URL to the client.

## Reference

[SSRF Prevention — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html)

The OWASP cheat sheet's primary recommendation for SSRF/open-redirect prevention is strict allowlist validation of any externally influenced URL before it is used for a request or navigation — exactly the pattern applied here. The dual-layer approach (server rejects before forwarding, client rejects before navigating) aligns with OWASP's defense-in-depth guidance, ensuring a bypass of either layer alone is insufficient.

## Residual risk / assumptions

- **`startsWith` vs. full origin equality (server layer):** the gateway uses a prefix comparison rather than parsed-origin equality. If `PUBLIC_OSIONOS_APP_URL` is set to a value like `https://app.example.com` an attacker-supplied URL `https://app.example.com.evil.com/...` would fail the check (since `.evil.com` is not a prefix match), but the defense relies on the env var being set to the correct, non-slash-terminated origin. A misconfigured or empty `PUBLIC_OSIONOS_APP_URL` disables the server check entirely (the `config.osionosAppUrl && ...` guard short-circuits to pass-through).
- **Client-side guard is defense-in-depth only:** if the server layer passes a malicious URL, the browser guard is the last line. JavaScript can be disabled or patched by a browser extension in an adversarial environment, making the server check the more reliable control.
- **Bridge is implicitly trusted:** the control validates the URL the bridge returns, not the bridge's identity. A fully compromised bridge (not just a manipulated response) could return any payload; mTLS or request signing between the gateway and bridge is not implemented.
- **No SSRF protection on outbound fetch from the gateway itself:** the gateway makes outbound calls to grobase (PostgREST/GoTrue) and the bridge. These destinations are configured via environment variables only; there is no IP-range or DNS-rebinding guard on those outbound requests.
