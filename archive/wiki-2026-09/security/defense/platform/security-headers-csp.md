# Security Headers & Content Security Policy — platform / infrastructure (cross-cutting)

> The TLS reverse proxy enforces transport-level response headers on every request, and the Astro marketing site generates a strict per-page `<meta>` CSP with SHA-256 hashes — together these eliminate MIME-sniffing, referrer leakage, clickjacking, unwanted feature access, and HTTPS downgrade without relying on any individual upstream service.

## What it is (the concept)

**HTTP security response headers** are short, machine-readable directives added to every HTTP response that instruct the browser how to handle content, origins, and embedded capabilities. **Content Security Policy (CSP)** is the most expressive of these: it restricts which scripts, styles, images, and connections a page may load, using an allowlist of origins and/or **SHA-256 script/style hashes**. Complementary headers — **HSTS**, **X-Content-Type-Options**, **X-Frame-Options**, **Referrer-Policy**, and **Permissions-Policy** — each address one narrow attack surface at the transport or rendering layer. Together they form the browser-enforced perimeter that backs up server-side controls.

## What it defends against

See [Cross-Site Scripting (XSS)](../../attack/security-headers-csp.md).

In this app, the attack surface is real: the marketing site (`opposite-osiris`) authenticates users and issues session cookies; the editor (`osionos`) handles rich user-authored content. Without a strict CSP, injected scripts can exfiltrate session cookies or call the BaaS API on behalf of the victim. Without HSTS the browser could silently downgrade to HTTP after first visit, enabling a stripping MITM. Without `X-Frame-Options` / `frame-ancestors` the site is embeddable in an attacker-controlled iframe, enabling clickjacking of auth flows. `X-Content-Type-Options: nosniff` closes the vector where a browser mis-executes a JSON or image response as a script by sniffing its content instead of trusting the declared `Content-Type`.

## How platform implements it

**Layer 1 — TLS proxy (`infrastructure/tls/nginx.conf`, lines 55–63).**

The single `local-https-proxy` nginx container terminates TLS for every frontend service. The `:4322` server block (the only one that hosts a user-facing auth surface) adds these headers unconditionally, using `always` so they appear on proxied and error responses alike:

```nginx
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "DENY" always;
add_header Content-Security-Policy "frame-ancestors 'none'" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "accelerometer=(), autoplay=(), camera=(), display-capture=(), encrypted-media=(), fullscreen=(self), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), midi=(), payment=(), picture-in-picture=(), publickey-credentials-get=(), screen-wake-lock=(), sync-xhr=(self), usb=(), xr-spatial-tracking=()" always;
```

Because `nginx add_header` appends rather than replaces, and `opposite-osiris-web` emits its own `Permissions-Policy` (containing the unsupported `web-share` token that triggers a console warning), the proxy strips the upstream copy before appending its own:

```nginx
location / {
  proxy_hide_header Permissions-Policy;
  proxy_pass http://$track_binocle_upstream;
}
```

`Content-Security-Policy: frame-ancestors 'none'` is set here — and deliberately not in the `<meta>` CSP — because browsers ignore `frame-ancestors` in a `<meta>` element (the Astro config documents this explicitly at line 87–91 of `apps/opposite-osiris/astro.config.mjs`).

**Layer 2 — Astro `security.csp` (`apps/opposite-osiris/astro.config.mjs`, lines 81–108).**

For content-level script and style integrity, Astro's built-in CSP integration generates a per-page `<meta http-equiv="Content-Security-Policy">` at build time. It computes SHA-256 hashes for every inline script and style Astro itself emits (the hoisted module script, inlined CSS blocks), so `script-src` and `style-src` require only `'self'` plus exact hashes — no `'unsafe-inline'`:

```js
security: {
  csp: {
    directives: [
      "default-src 'self'",
      "base-uri 'self'",
      "object-src 'none'",
      "form-action 'self'",
      "trusted-types prismatica-static-markup",
      "require-trusted-types-for 'script'",
      // ...
    ],
    scriptDirective: { resources: ["'self'", 'https://challenges.cloudflare.com'] },
    styleDirective:  { resources: ["'self'"] },
  },
},
```

`require-trusted-types-for 'script'` enforces the Trusted Types API, requiring all DOM-sink injections to pass through the named `prismatica-static-markup` policy — a second-order XSS defence.

**Wiring (`docker-compose.yml`, lines 5–7).**

The nginx config is mounted read-only into the container — no runtime mutation is possible:

```yaml
local-https-proxy:
  image: public.ecr.aws/docker/library/nginx:1.27-alpine
  volumes:
    - ./infrastructure/tls/nginx.conf:/etc/nginx/nginx.conf:ro
```

## How we know it is applied

**nginx config test in the healthcheck.** The `local-https-proxy` service health probe runs `nginx -t` on a 5-second interval (`docker-compose.yml` line 19). If the header directives are syntactically broken, this probe fails and compose marks the container unhealthy before any traffic reaches it.

**Headless Chromium CSP gate (`apps/grobase/vendor/grobase-website/scripts/audit/csp-check.mjs`).** The grobase marketing site ships an automated audit script that launches headless Chromium (via puppeteer), loads each page, and fails the build on any `securitypolicyviolation` event, any console error, or a `<meta>` CSP that is missing, lacks hashes, or contains `'unsafe-inline'`:

```js
// fails on:
//   - any securitypolicyviolation event
//   - any console error
//   - a meta CSP that is missing, lacks hashes, or contains 'unsafe-inline'
```

This gate is wired into `make grobase-audit` (`infrastructure/makes/grobase.mk` line 16) and runs inside Docker — it proves the grobase marketing site's CSP is both present and non-trivial in a real browser engine. It does **not** run against `opposite-osiris`; see the residual risk section below.

## Reference

The [Content Security Policy Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Content_Security_Policy_Cheat_Sheet.html) (OWASP, 2024) covers directive semantics, the distinction between `<meta>` and HTTP-header delivery, and the recommended migration path from `'unsafe-inline'` to hash-based policies. This implementation follows the cheat sheet's guidance exactly: hashes replace `'unsafe-inline'` in `script-src`, `frame-ancestors` is delivered as an HTTP header (not `<meta>`), and `object-src 'none'` closes the plugin-based bypass.

## Residual risk / assumptions

- **osionos (`:3001`) and all other frontends receive no security headers from the proxy.** The `:4322` server block is the only one that adds `HSTS`, `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, and `Permissions-Policy`. The editor, bridge, mail, and calendar services are unprotected at the proxy layer and must rely on their own application-level headers — which are not verified here.
- **The `<meta>` CSP covers `opposite-osiris` only.** Astro's `security.csp` runs at build time for one app. `osionos` (React/Vite) and the other frontends do not have an equivalent audited CSP.
- **HSTS applies to a self-signed local CA.** In production, a real CA-signed certificate and `Strict-Transport-Security` preloading would be required for full HSTS guarantees. The 31536000 / `includeSubDomains` value is correct but the preload flag is absent — the domain is not in the HSTS preload list.
- **`frame-ancestors 'none'` vs. `X-Frame-Options: DENY` — both are set for defense-in-depth**, but older browsers that ignore CSP will respect only `X-Frame-Options`. This dual-header approach is correct and intentional.
- **`proxy_hide_header` only suppresses `Permissions-Policy`.** Other upstream headers that might weaken the proxy's policy (e.g., a downstream `Content-Security-Policy` that is more permissive) are not stripped. If `opposite-osiris-web` ever emits its own `X-Frame-Options: SAMEORIGIN`, nginx would deliver both headers and browsers would use the more restrictive one — but this is an untested assumption.
- **The CSP headless Chromium gate runs against the grobase marketing site**, not `opposite-osiris`. The `astro.config.mjs` comment references `scripts/audit/csp-check.mjs`, but that file lives under `apps/grobase/vendor/grobase-website/`. Whether an equivalent automated CSP verification gate exists for `opposite-osiris` production builds is not confirmed.
