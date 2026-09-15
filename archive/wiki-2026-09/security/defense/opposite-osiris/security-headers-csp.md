# Content Security Policy — opposite-osiris (marketing + auth website)

> Every page built by opposite-osiris carries a per-page `<meta>` Content-Security-Policy with SHA-256 hashes for every inline script and style Astro emits, ensuring that any injected script without a matching hash is blocked at parse time.

## What it is (the concept)

A **Content Security Policy (CSP)** is a browser security mechanism delivered via an HTTP response header or an HTML `<meta>` tag that constrains which resource origins and inline content the browser is permitted to execute or load. In the **hash-based** variant used here, the browser computes a SHA-256 digest of each inline `<script>` and `<style>` block and compares it against the hashes listed in the policy; any inline content whose digest is absent is blocked, regardless of its position in the DOM. The key vocabulary: **directive** (a named restriction, e.g. `script-src`), **source expression** (`'self'`, `'nonce-…'`, `'sha256-…'`), **Trusted Types** (a browser API that prevents unsafe DOM sinks from receiving attacker-controlled strings).

## What it defends against

See [Cross-Site Scripting (XSS)](../../attack/security-headers-csp.md).

XSS is the primary threat: an attacker who can inject markup into a page (via a reflected query parameter, stored payload, or DOM manipulation) cannot execute that markup as code because no injected `<script>` will carry a recognised SHA-256 hash. In the opposite-osiris context the attack surface includes the auth landing form, newsletter sign-up, and any user-visible query-string reflection (e.g. error messages forwarded to the Turnstile widget). Beyond XSS, `object-src 'none'` eliminates legacy plugin execution vectors, and `base-uri 'self'` closes **base-tag hijacking**, where an attacker inserts a `<base href="…">` to redirect all relative URLs to an attacker-controlled origin.

## How opposite-osiris implements it

**Astro's `security.csp` framework feature** — configured in [`apps/opposite-osiris/astro.config.mjs`](../../../../apps/opposite-osiris/astro.config.mjs) lines 81–108 — is the authoritative production source. On every `astro build` Astro computes SHA-256 hashes for each inline `<script>` and `<style>` block it emits and injects them into a `<meta http-equiv="Content-Security-Policy">` tag per page. No manual hash maintenance is required.

The directive set (lines 83–101):

```js
security: {
  csp: {
    directives: [
      "default-src 'self'",
      "base-uri 'self'",
      "object-src 'none'",
      "form-action 'self'",
      "img-src 'self'",   "media-src 'self'",  "worker-src 'self'",
      "manifest-src 'self'", "font-src 'self'",
      "connect-src 'self' https:",
      "trusted-types prismatica-static-markup",
      "require-trusted-types-for 'script'",
    ],
    scriptDirective: { resources: ["'self'", 'https://challenges.cloudflare.com'] },
    styleDirective:  { resources: ["'self'"] },
  },
},
```

Notable points:
- `'unsafe-inline'` and `'unsafe-eval'` are **absent** from production `script-src` and `style-src`.
- `https://challenges.cloudflare.com` is the sole external script origin, required by the Cloudflare Turnstile CAPTCHA widget.
- `connect-src 'self' https:` allows outbound fetch/XHR to any HTTPS endpoint while blocking plain-HTTP and WebSocket exfiltration.
- `trusted-types prismatica-static-markup` + `require-trusted-types-for 'script'` enforce **Trusted Types**, requiring all DOM sink assignments (e.g. `innerHTML`) to pass through the named policy object rather than accepting a raw string.
- `frame-ancestors` is intentionally **omitted** from the `<meta>` (browsers ignore `frame-ancestors` in `<meta>` and log a console error); clickjacking protection is enforced at the HTTP layer via `X-Frame-Options: DENY` and a `Content-Security-Policy: frame-ancestors 'none'` response header set by the TLS proxy (noted in the `astro.config.mjs` comment at line 87–91).

**Development-mode relaxation** is isolated in [`apps/opposite-osiris/src/layouts/Layout.astro`](../../../../apps/opposite-osiris/src/layouts/Layout.astro) lines 42–56, 83. When `import.meta.env.DEV` is true, Layout.astro emits its own `<meta>` CSP with `'unsafe-inline'`, `'unsafe-eval'`, and `ws://localhost:*` to accommodate Vite's HMR. This gate is explicit:

```astro
{isDev && <meta http-equiv="Content-Security-Policy" content={developmentCsp} />}
```

The production build path never hits this branch; Astro's `security.csp` owns the `<meta>` in built output.

## How we know it is applied

`pnpm verify:csp` (npm script line 35 of `package.json`, wired to [`apps/opposite-osiris/scripts/verify-csp.mjs`](../../../../apps/opposite-osiris/scripts/verify-csp.mjs)) fetches a live page from the running container, parses every `<meta>` tag, extracts the `http-equiv="Content-Security-Policy"` value, and asserts that the policy is present and well-formed. The script defaults to `https://localhost:4322/` and accepts a `CSP_VERIFY_URL` environment variable for CI or remote targets. This is an active runtime probe — it fails fast if the built output does not carry a CSP `<meta>`.

A secondary observable signal: [`Layout.astro` line 82](../../../../apps/opposite-osiris/src/layouts/Layout.astro) emits `<meta name="prismatica-csp-mode" content="production">` (or `"development"`) on every page, providing a machine-readable indicator of which policy regime is active without exposing the policy content itself.

## Reference

The [Content Security Policy Cheat Sheet (OWASP)](https://cheatsheetseries.owasp.org/cheatsheets/Content_Security_Policy_Cheat_Sheet.html) is the canonical reference for directive semantics, source-expression grammar, and the hash-vs-nonce trade-off. It is particularly relevant here because the opposite-osiris approach — SHA-256 hashes computed at build time, no nonce, no `'unsafe-inline'` — is the deployment model OWASP recommends for static or SSG sites where response-time nonce injection is unavailable.

Corroborating: the W3C CSP Level 3 specification defines how browsers handle `frame-ancestors` in `<meta>` (they must ignore it), which is the precise reason the proxy-level HTTP header is the correct enforcement point for clickjacking rather than the Astro `security.csp` config.

## Residual risk / assumptions

- **`<meta>` vs. header delivery**: A CSP delivered via `<meta>` is processed after the HTML parser has already begun; a very fast parser or a pre-speculative-load fetch may issue requests before the `<meta>` is encountered. An HTTP `Content-Security-Policy` response header (set before the body) would be strictly stronger. The proxy does set `frame-ancestors` as a header, but the full hash-based policy is meta-only.
- **`connect-src 'self' https:`** is intentionally broad — it permits any outbound HTTPS fetch, not just to known API origins. This is a pragmatic trade-off for the Turnstile integration and any future CDN assets; a tighter allowlist (e.g. `connect-src 'self' https://challenges.cloudflare.com https://api.example.com`) would shrink the exfiltration surface.
- **Trusted Types enforcement** requires browser support (Chromium-based browsers only as of this writing; Firefox has it behind a flag). Safari users receive no Trusted Types protection; the CSP source restrictions still apply, but DOM-sink misuse is not blocked at the API level.
- **The `audit:csp` npm script** (line 23 of `package.json`) references `scripts/audit/csp-check.mjs`, which does not exist in the repository (confirmed absent). That gate is non-functional; only `verify:csp` / `verify-csp.mjs` is confirmed live.
- The policy does not cover server-side rendering paths or serverless edge functions if those are introduced; the `security.csp` config applies to the Astro build output only.
