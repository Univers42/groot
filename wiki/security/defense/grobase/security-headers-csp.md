# Security Response Headers — grobase (the BaaS backend)

> Kong's global `response-transformer` plugin injects a hardened set of HTTP response headers on every proxied response and strips server-identity headers, reducing the attack surface for clickjacking, MIME-sniffing, referrer leakage, and feature abuse across all BaaS API consumers.

## What it is (the concept)

**HTTP security response headers** are directives sent by a server that instruct the browser (or API client) to enforce constraints on how a response may be rendered, loaded, or referenced. Applied at the **gateway layer**, they create a single enforcement point that covers every upstream service without requiring per-service implementation. **`X-Frame-Options`**, **`Strict-Transport-Security`** (HSTS), **`X-Content-Type-Options`**, **`Permissions-Policy`**, and the Cross-Origin family (`COOP`, `CORP`) form the modern baseline; banner-stripping (`Server`, `X-Powered-By`, `Via`) removes version-disclosure vectors that DAST tools such as OWASP ZAP flag explicitly.

Note: **Content-Security-Policy (CSP)** is deliberately not added at the Kong gateway — CSP requires per-origin, per-resource-type tuning and is left to each frontend application. The headers documented here are the complementary, gateway-layer controls.

## What it defends against

See [Cross-Site Scripting (XSS)](../../attack/security-headers-csp.md). In the grobase context the specific mitigations are:

- **Clickjacking** — `X-Frame-Options: DENY` prevents any page from embedding a BaaS-proxied API response or documentation frame inside a hostile iframe, blocking UI-redress attacks against authenticated sessions.
- **MIME-sniffing** — `X-Content-Type-Options: nosniff` stops browsers from overriding the declared `Content-Type`, reducing the risk of a stored-file or API-response being executed as a script.
- **Referrer leakage** — `Referrer-Policy: strict-origin-when-cross-origin` limits the URL fragment sent to third-party endpoints, protecting tenant identifiers embedded in query strings.
- **Server version disclosure** — removing `Server`, `X-Powered-By`, and `Via` closes the reconnaissance vector flagged by OWASP ZAP as "Server Leaks Version Information" and "In Page Banner Info Leak".

## How grobase implements it

All header injection and removal is declared as a **global Kong plugin** in
[`apps/grobase/infra/docker/services/kong/conf/kong.yml`](../../../../apps/grobase/infra/docker/services/kong/conf/kong.yml)
(lines 63–84). Because the plugin is not scoped to a route or service, it applies to every response that passes through Kong's proxy — including PostgREST (`/rest/v1`), GoTrue (`/auth/v1`), the data-plane router (`/query/v1`), and the storage router (`/storage/v1`).

The `add.headers` stanza (verified, lines 70–77):

```yaml
- X-Content-Type-Options:nosniff
- X-Frame-Options:DENY
- Referrer-Policy:strict-origin-when-cross-origin
- Permissions-Policy:accelerometer=(), autoplay=(), camera=(), display-capture=(), encrypted-media=(), fullscreen=(self), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), midi=(), payment=(), picture-in-picture=(), publickey-credentials-get=(), screen-wake-lock=(), sync-xhr=(self), usb=(), web-share=(), xr-spatial-tracking=()
- Cross-Origin-Opener-Policy:same-origin
- Cross-Origin-Resource-Policy:same-site
- Strict-Transport-Security:max-age=63072000; includeSubDomains; preload
```

The `remove.headers` stanza (lines 80–84) strips `Server`, `X-Powered-By`, and `Via`.

A second, independent control in
[`apps/grobase/orchestrators/compose/base/gateway.yml`](../../../../apps/grobase/orchestrators/compose/base/gateway.yml)
sets `KONG_HEADERS: "off"` (line 54) on the Kong container itself. This environment variable suppresses Kong's own `Via` and `Server` identity disclosures at the NGINX level, independent of the plugin layer — both controls are required to achieve complete suppression.

## How we know it is applied

The plugin is declared at the **top-level `plugins:` list** in `kong.yml` with no `route`, `service`, or `consumer` key — Kong applies top-level plugins globally to all traffic. The inline comment on line 65 ties each added header directly to a named OWASP ZAP DAST finding:

```yaml
# Add hardening headers — covers OWASP ZAP findings:
#  • Permissions-Policy (Low: header not set)
#  • Cross-Origin-* round out the modern set
#  • HSTS bumped to 2y + preload
```

This comment is evidence the plugin was introduced in response to a live DAST scan, not aspirationally. The `KONG_HEADERS: "off"` env var is part of the declarative compose definition and takes effect on every `docker compose up` of the `mini-baas` stack — it is not an optional runtime flag.

## Reference

The [Content Security Policy Cheat Sheet (OWASP)](https://cheatsheetseries.owasp.org/cheatsheets/Content_Security_Policy_Cheat_Sheet.html) situates CSP within the broader family of browser-enforced security headers and explains why a layered approach — gateway-level response headers alongside per-application CSP — is necessary for complete coverage. The cheat sheet's treatment of `X-Frame-Options`, HSTS, and the Cross-Origin header family maps directly to the controls deployed here; the grobase implementation follows those recommendations at the reverse-proxy layer rather than repeating them in every upstream service.

## Residual risk / assumptions

- **No CSP at the gateway.** `Content-Security-Policy` is not injected by Kong. Each frontend (`opposite-osiris`, `osionos`, `auth-gateway`) must define its own CSP; a misconfigured or absent CSP in any frontend is not compensated by these gateway headers.
- **HTTP-only clients bypass HSTS.** HSTS's `preload` directive is effective only after the first HTTPS connection; a client that reaches Kong over plain HTTP on first contact does not receive the header. The `docker-compose.prod.yml` overlay should enforce redirect-to-HTTPS before Kong accepts cleartext connections in production.
- **Header injection is additive, not conditional.** The `response-transformer` plugin adds headers even when an upstream already sets the same header — Kong does not de-duplicate. A conflicting value from an upstream service results in two header instances, and the effective browser-applied value depends on the field's parsing rule (last-wins vs. first-wins).
- **Admin API exclusion.** The global plugin applies to the **proxy port** (`:8000`). Kong's admin API (`:8001`), which is bound to `0.0.0.0` in development and must be network-restricted in production via `KONG_ADMIN_LISTEN` scoping or a firewall rule, does not benefit from these headers.
- **Plugin config is file-based (DB-less mode).** Any runtime change to `kong.yml` requires a container restart or a `kong reload` — there is no live admin-API mutation path for these headers, which is a strength (config drift is impossible) but means remediation requires a redeploy.
