# Clickjacking Defense — platform / infrastructure (cross-cutting)

> The TLS reverse-proxy emits `X-Frame-Options: DENY` and `Content-Security-Policy: frame-ancestors 'none'` on every response it serves, unconditionally blocking any browser from embedding this application inside an `<iframe>`.

## What it is (the security concept)

**Clickjacking** (also called a **UI-redress attack**) is a technique where an attacker loads a
legitimate page inside a transparent or invisible `<iframe>` overlaid on a decoy page, tricking a
user into clicking on UI elements they cannot see. Two complementary HTTP response headers defend
against it: **`X-Frame-Options`** (legacy, widely supported) signals that the browser must refuse
to render the response inside any frame; **`Content-Security-Policy: frame-ancestors`** is the
modern successor — it specifies which origins are permitted to embed the document, and its
`'none'` value means no origin at all. Both must be delivered as HTTP headers; only
`frame-ancestors` is ignored when set via an HTML `<meta>` tag.

## What it defends against

See [Clickjacking (UI Redress Attack)](../../attack/clickjacking.md).

An attacker hosting a malicious page could silently embed the opposite-osiris marketing and auth
surfaces inside an `<iframe>`, then position transparent buttons over the decoy page to steal
clicks — for example, to trigger an account action or OAuth consent without the user's awareness.
The auth-landing flow is the highest-value target: a single invisible click on a pre-filled
"Authorize" button can hand over a session.

## How the platform implements it

The control lives entirely in the shared TLS reverse-proxy that fronts **all** frontend services.
It is not delegated to individual application frameworks, so it cannot be accidentally omitted
when a new frontend is wired in through the proxy's port block.

**[`infrastructure/tls/nginx.conf`](../../../../infrastructure/tls/nginx.conf)** — the nginx
virtual-host block for the opposite-osiris website (port 4322) declares:

```nginx
# infrastructure/tls/nginx.conf — lines 57, 61
add_header X-Frame-Options "DENY" always;
add_header Content-Security-Policy "frame-ancestors 'none'" always;
```

The inline comment at lines 50–54 records the design rationale:

> _"transport/clickjacking/sniffing defenses the proxy must add because the website does not pass
> through Kong (which only fronts /api). `always` makes nginx emit them even on proxied/error
> responses."_

The `always` flag ensures the headers are appended even when nginx generates its own error
responses (4xx/5xx), not only on successful 2xx passes through to the upstream. The
`frame-ancestors` header is added as a single-directive CSP so it does not interfere with the
application's own strict `<meta>` CSP (which governs scripts, styles, and other fetch directives
but cannot set `frame-ancestors`).

**[`docker-compose.yml`](../../../../docker-compose.yml)** — the `local-https-proxy` service
mounts this configuration read-only and exposes it as the sole TLS termination point for every
frontend port:

```yaml
# docker-compose.yml — lines 4–7
local-https-proxy:
  image: public.ecr.aws/docker/library/nginx:1.27-alpine
  volumes:
    - ./infrastructure/tls/nginx.conf:/etc/nginx/nginx.conf:ro
```

Every browser request to any port served by `local-https-proxy` transits this nginx config,
so the framing headers are injected at the transport boundary before the response reaches the
client.

## How we know it is applied

The nginx config is mounted `:ro` into the live container by `docker-compose.yml` (line 7).
The `always` directive means nginx appends the headers regardless of upstream response code,
making suppression by the proxied app impossible. The `make healthcheck` target (wired into
`make all`) verifies the stack is up; confirming the headers requires a live `curl -I
https://localhost:4322` against the running proxy — both `X-Frame-Options: DENY` and the
`Content-Security-Policy` line will appear in the response.

Additionally, the Semgrep SAST gate (`make baas-security-scan`) runs over the infrastructure
layer and would surface any accidental removal of these `add_header` lines during a future edit,
providing a CI-level regression guard.

## Reference

The [OWASP Clickjacking Defense Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Clickjacking_Defense_Cheat_Sheet.html)
documents `X-Frame-Options` and `Content-Security-Policy: frame-ancestors` as the two
authoritative mechanisms, notes their complementary coverage across browser generations, and
recommends deploying both for defense-in-depth — which is exactly the posture this proxy
implements. The cheat sheet also makes clear that `frame-ancestors` supersedes `X-Frame-Options`
in CSP-aware browsers, so retaining both ensures coverage for legacy clients that do not
implement CSP Level 2.

## Residual risk / assumptions

- **Only the opposite-osiris frontend (port 4322) carries these headers.** The other services
  proxied by `local-https-proxy` — osionos editor (:3001), osionos-bridge (:4000),
  auth-gateway (:8787), mail (:3002), calendar (:3003) — do not have equivalent
  `add_header X-Frame-Options` or `frame-ancestors` directives in their virtual-host blocks. If
  any of those surfaces is frameable, a clickjacking path through them is not closed at the proxy
  layer.
- **Browser enforcement.** The defense is entirely client-side: it depends on the victim's browser
  honoring `X-Frame-Options`/CSP. Very old or compromised browsers may ignore these headers.
- **Direct upstream access.** If an attacker can reach `opposite-osiris-web:8080` directly
  (inside the Docker network), they bypass the proxy and receive responses without the framing
  headers. The mitigation relies on the Docker network isolation ensuring no external path to
  the upstream exists.
- **`frame-ancestors` and `X-Frame-Options` do not protect against other UI-redress techniques**
  (e.g., drag-and-drop cross-origin data exfiltration or pointer-events CSS tricks) that do not
  rely on `<iframe>` embedding.
