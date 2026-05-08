# Prismatica Frontend CTF Security Audit — 2026-05-04

Scope: `opposite-osiris/src` frontend pages, components, client scripts, public media assets, checked-in SVG assets, and local CSP/dev server hardening.

## Executive summary

The highest-risk frontend pattern was inline SVG rendering through Astro `set:html` fed by raw `?raw` SVG imports. SVG is an active document format and can carry JavaScript through `<script>`, event attributes, `foreignObject`, embedded external media, and executable URL protocols. This is now protected by a narrow SVG sanitizer and a CTF regression suite.

A second hardening item was media path construction. Public media paths were constant today, but raw path concatenation would be dangerous if reused for uploads or user-controlled media. This is now replaced with an allowlisted same-origin asset URL builder.

A third hardening item was CSP/Trusted Types. Production CSP is now stricter for images/media/workers and declares a named Trusted Types policy. The previous generic `default` Trusted Types policy was replaced by an app-scoped policy.

## Findings and repairs

### F-001 — Raw SVG injection through `set:html`

- Area: `src/components/svg/CharacterIllustration.astro`
- Original pattern: raw SVG imports (`?raw`) were rendered directly with `set:html`.
- Why it matters: if a future downloaded/uploaded/replaced SVG contains active markup, inline rendering can execute it in the page origin.
- Repair: added `src/lib/svg-security.mjs` and sanitize every raw SVG with `sanitizeSvgMarkup()` before it reaches `set:html`.
- Regression tests: `scripts/security/ctf/01-xss-sinks.mjs`, `scripts/security/ctf/02-svg-upload-xss.mjs`.

### F-002 — SVG asset corpus lacked an executable-content guard

- Area: `src/assets/**/*.svg`, `public/**/*.svg`.
- Original pattern: no automated test blocked checked-in SVG files containing `<script>`, event handlers, `foreignObject`, executable `href`, or embedded active content.
- Why it matters: design SVGs are often copied from external tools and are easy to replace during normal content work.
- Repair: CTF tests scan the full SVG corpus and run all legitimate SVG files through the sanitizer.
- Regression tests: `scripts/security/ctf/02-svg-upload-xss.mjs`.

### F-003 — Media URLs were built by raw string concatenation

- Area: `src/components/sections/MediaAssetsSection.astro`.
- Original pattern: `BASE_URL + assets/ + fileName`.
- Why it matters: if this helper is reused with upload/user data, path traversal, external protocols, or executable data URLs could enter image/media sinks.
- Repair: added `src/lib/media-security.mjs` with `safePublicAssetPath()` to reject traversal, protocols, nested paths, NUL bytes and unsupported extensions.
- Regression tests: `scripts/security/ctf/03-media-url.mjs`.

### F-004 — Production CSP allowed unnecessary image schemes and lacked Trusted Types policy directives

- Area: `src/layouts/Layout.astro`.
- Original pattern: production `img-src` allowed `data:` and `blob:` and the policy lacked Trusted Types directives.
- Why it matters: permissive image schemes can widen SVG/media abuse paths; Trusted Types reduces DOM XSS impact around HTML sinks.
- Repair: production CSP now uses `img-src 'self'`, `media-src 'self'`, `worker-src 'self'`, `manifest-src 'self'`, `frame-ancestors 'self'`, `trusted-types prismatica-static-markup`, and `require-trusted-types-for 'script'`.
- Regression tests: `scripts/security/ctf/04-csp-hardening.mjs`.

### F-005 — Trusted Types policy name was generic

- Area: `src/scripts/main.ts`.
- Original pattern: `trustedTypes.createPolicy('default', ...)`.
- Why it matters: a broad default policy is harder to audit and can conflict with a restrictive CSP policy list.
- Repair: renamed to `trustedTypes.createPolicy('prismatica-static-markup', ...)`, matching the CSP allowlist.
- Regression tests: `scripts/security/ctf/01-xss-sinks.mjs`, `scripts/security/ctf/04-csp-hardening.mjs`.

## CTF laboratory

Run the whole lab:

```sh
npm run test:security:ctf
```

Run one category:

```sh
node scripts/security/ctf/run-all.mjs --category=svg-upload-xss
```

Categories:

- `xss-sinks`: static DOM sink inventory and Trusted Types checks.
- `svg-upload-xss`: malicious SVG payload laboratory and SVG asset corpus scan.
- `media-url`: path traversal/protocol injection checks for media asset URLs.
- `csp`: production/development CSP and Trusted Types hardening checks.

## Remaining production recommendations

- Serve equivalent CSP, HSTS, `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`, and `Cross-Origin-*` headers from the production hosting layer, not only meta tags.
- If user uploads are added later, store uploaded SVG as downloads or sanitize server-side before storage; do not inline user-provided SVG.
- Keep SVG upload/media tests required in CI before merging design asset updates.
