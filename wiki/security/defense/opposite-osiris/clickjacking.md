# Clickjacking Defense — opposite-osiris (marketing + auth website)

> The nginx edge layer and static-host fallback both emit framing-denial headers on every response, including error bodies, ensuring no browser will render the auth landing or sign-in pages inside a third-party iframe.

## What it is (the concept)

**Clickjacking** (also called a **UI-redress attack**) is a technique where an attacker embeds a legitimate page inside a hidden or transparent `<iframe>` and overlays it with a decoy UI, causing victims to interact with the real page without realising it. Two complementary HTTP response headers stop this: **`X-Frame-Options`**, a legacy directive that instructs the browser to refuse iframe rendering, and the **`Content-Security-Policy: frame-ancestors`** directive, its modern, more expressive replacement. Neither can be set via a `<meta>` tag — browsers ignore `frame-ancestors` in `<meta>` CSP, so the defense must live at the HTTP header layer.

## What it defends against

See [Clickjacking (UI Redress Attack)](../../attack/clickjacking.md).

For opposite-osiris the risk is concrete: the site is the auth entry point for the entire Track Binocle platform. An attacker who tricks a logged-in user into clicking inside a framed copy of the sign-in or account-management page could silently trigger credential submission, OAuth grants, or session-linked actions. The marketing pages carry CSRF tokens and cookie-scoped sessions, making them worth protecting even beyond the login form.

## How opposite-osiris implements it

Two independent enforcement points deliver the defense, covering the container deployment path and the static-host fallback path separately.

**1. nginx container — primary delivery path**

[`apps/opposite-osiris/docker/services/web/default.conf.template`](../../../../apps/opposite-osiris/docker/services/web/default.conf.template) (lines 28–29) configures the nginx server block:

```nginx
add_header X-Frame-Options "DENY" always;
add_header Content-Security-Policy "frame-ancestors 'none'" always;
```

The inline comment (lines 23–25) documents the design decision explicitly: *"frame-ancestors only works as an HTTP header, so we add it here … `always` covers error bodies."* The `always` modifier is critical — without it nginx omits the headers from 4xx/5xx responses, which attackers can exploit by framing an error page whose overlay is indistinguishable from the real UI. `frame-ancestors 'none'` is stricter than `DENY`: it prohibits framing by any origin, including the site itself.

This template is rendered into `/etc/nginx/conf.d/default.conf` at container start by the official nginx envsubst mechanism (`NGINX_ENVSUBST_FILTER=^OO_`), so every response from the running `opposite-osiris-web` container carries these headers.

**2. `public/_headers` — static-host fallback**

[`apps/opposite-osiris/public/_headers`](../../../../apps/opposite-osiris/public/_headers) (lines 7–14) is the Netlify/Cloudflare Pages-compatible header file that applies when the site is deployed to a CDN edge rather than the Docker stack:

```
/*
  Content-Security-Policy: frame-ancestors 'self'
  X-Frame-Options: DENY
```

The file's opening comment explains the intentional separation: the full fetch-directive CSP (with SHA-256 hashes for inline scripts) is emitted per page as a `<meta>` by Astro's `security.csp` integration; only the directives that `<meta>` cannot enforce — `frame-ancestors` and the other transport/framing headers — are placed here. This prevents the header CSP from conflicting with the hashed meta policy.

Note that this path uses `frame-ancestors 'self'` (same-origin framing allowed) rather than `'none'`. The nginx container path is stricter; the static-host path is a deployment-specific trade-off documented in the file header.

## How we know it is applied

**Live runtime assertion** — [`apps/opposite-osiris/scripts/security/05-headers.mjs`](../../../../apps/opposite-osiris/scripts/security/05-headers.mjs) (lines 30–35) fetches the running site and asserts the header is present:

```js
{
  name: 'frame protection header present',
  description: 'Checks the gateway resists clickjacking through DENY or SAMEORIGIN frame policy.',
  run: async () => {
    const response = await fetchWithTimeout(config.url);
    assert.ok(['deny', 'sameorigin'].includes(response.headers.get('x-frame-options')?.toLowerCase() ?? ''),
      'X-Frame-Options is not DENY or SAMEORIGIN');
    return passed('X-Frame-Options is DENY or SAMEORIGIN.');
  },
},
```

**Static regression gate** — [`apps/opposite-osiris/scripts/security/ctf/04-csp-hardening.mjs`](../../../../apps/opposite-osiris/scripts/security/ctf/04-csp-hardening.mjs) (lines 61–65) reads `public/_headers` directly and asserts both that the CSP is present and that it carries `frame-ancestors 'self'`:

```js
{
  name: 'Production static headers carry frame-ancestors',
  run: () => {
    const headers = readProjectFile('public/_headers');
    assert.ok(headers.includes('Content-Security-Policy:'), 'production static CSP header missing');
    assert.ok(headers.includes("frame-ancestors 'self'"), 'production static CSP header missing frame-ancestors');
  },
},
```

The same file also asserts that `frame-ancestors` is **absent** from every `<meta>` CSP string, enforcing the architectural rule that only HTTP headers may carry this directive.

**Container wiring** — [`docker-compose.yml`](../../../../docker-compose.yml) (lines 397–400) pulls and runs `dlesieur/opposite-osiris-web:latest`, the image that bakes the template at start:

```yaml
opposite-osiris-web:
  image: ${OPPOSITE_OSIRIS_WEB_IMAGE:-dlesieur/opposite-osiris-web:latest}
```

The image is fronted by `local-https-proxy` at `:4322`; the nginx layer at `:8080` is always the innermost response origin, so its `add_header` directives are authoritative for the Docker deployment path.

## Reference

The [OWASP Clickjacking Defense Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Clickjacking_Defense_Cheat_Sheet.html) defines the canonical defense hierarchy: `frame-ancestors` is the preferred modern directive because it supports fine-grained origin lists, while `X-Frame-Options` is retained for compatibility with older browsers that predate CSP Level 2. Deploying both in tandem — as opposite-osiris does — maximises coverage across the browser matrix without relying on either directive alone.

## Residual risk / assumptions

- **Scope is the nginx layer only.** If `local-https-proxy` (the outermost TLS terminator at `:4322`) were misconfigured to strip or override response headers before forwarding, the framing headers would not reach the browser. The current compose wiring does not modify upstream headers from the nginx inner layer.
- **Static-host path is `frame-ancestors 'self'`, not `'none'`.** The `_headers` file permits same-origin framing. If any page on the same origin is compromised (e.g., via XSS), it could embed the auth page in an iframe. The Docker/nginx path applies the stricter `'none'` and is the primary deployment target.
- **`05-headers.mjs` tolerance.** The live test accepts `SAMEORIGIN` in addition to `DENY`. A deployment that accidentally weakened the directive to `SAMEORIGIN` would still pass the gate. The stricter static check in `04-csp-hardening.mjs` only applies to the `_headers` file, not the live service response.
- **No JavaScript frame-busting.** The implementation relies entirely on HTTP headers. JavaScript-based frame-busting (e.g., `window.top !== window.self` checks) is not used and is not needed given the header approach, but this means there is no client-side fallback if a very old browser ignores both headers.
- **Electron / desktop builds.** The `CLAUDE.md` notes that desktop builds must use `127.0.0.1`, not `localhost`. `X-Frame-Options: DENY` still applies in Electron's Chromium renderer, but the origin model differs from a standard browser context and has not been explicitly tested in this defense gate.
