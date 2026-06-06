# opposite-osiris security review (auth entrypoint)

Code-grounded threat assessment of opposite-osiris — the **website + auth API
gateway** that is the entrypoint to everything (accounts, sessions, the osionos
bridge). Reviewed 2026-06-06 against the source at the pre-removal snapshot
(`apps/opposite-osiris/scripts/auth-gateway.mjs`, `src/hooks/useAuth.ts`,
`src/scripts/main.ts`, the SDK pages, the CSP in `astro.config.mjs`, and
`infrastructure/tls/nginx.conf`).

> Reality check: there is no "bullet-proof". The goal is **defense in depth** —
> no single bug = full compromise, and the blast radius of each weakness is
> bounded. The gateway is already well-built; the findings below are about
> closing the gaps that remain, in priority order.

## What is already strong (keep it)
- **Auth BFF pattern**: the browser never holds the service-role key; private
  secrets are runtime-injected from Vault, never baked into images.
- **Refresh token** is `HttpOnly; Secure; SameSite=Lax; Path=/api/auth` and is
  stripped from the JSON body (`sanitizeAuthPayload`). The access token is the
  only thing returned to JS.
- **Enumeration-safe recovery**: `/recover` always returns the same 200.
- **Turnstile** on register/login/recover; **per-IP rate limiting** with
  escalating `retry-after`; password policy (8+, mixed classes); request body
  capped at 32 KB.
- **HMAC-signed** osionos bridge requests (timestamp + stable-stringified body).
- **Email**: templates HTML-escaped; CRLF stripped from `From`; recipient is a
  regex-validated address (header-injection safe); SMTP TLS uses
  `rejectUnauthorized: true`.
- **Strong CSP** (Astro `security.csp`: hashed, no `unsafe-inline`,
  `object-src 'none'`, `base-uri 'self'`, `trusted-types`) + edge hardening
  headers (HSTS, `X-Frame-Options: DENY`, `frame-ancestors 'none'`,
  Referrer-Policy, locked Permissions-Policy). This is the main reason the
  localStorage finding below is MEDIUM not HIGH.

---

## Findings (by severity)

### HIGH-1 — Rate limiting is bypassable via spoofed client IP
`clientIp()` (auth-gateway.mjs:97) trusts `cf-connecting-ip` / `x-forwarded-for`
and takes the **left-most** value (`.split(',')[0]`). The proxies in front
(`opposite-osiris-web` nginx, `local-https-proxy`) **append** to XFF
(`$proxy_add_x_forwarded_for`), so the left-most value is **client-controlled**.
An attacker rotates `X-Forwarded-For: <random>` per request → every request lands
in a fresh rate-limit bucket → **all throttling is defeated** (brute-force login,
registration spam, newsletter email-bombing, and unbounded `Map` growth = memory
DoS). This directly undermines the throttling you rely on.

**Treat:** derive the client IP from a *trusted* hop — take the **right-most**
XFF entry, or the Nth-from-right based on a known proxy-hop count, or read a
header only your edge proxy sets and which it overwrites (not appends). Never
trust `cf-connecting-ip` unless Cloudflare is actually in front and the origin is
locked to Cloudflare. Bound the rate-limit maps (see MEDIUM-3).

### MEDIUM-1 — Access token stored in `localStorage` (XSS-exfiltratable)
`main.ts:467` persists the access token via `writeStorage` →
`localStorage.setItem` (main.ts:262). Any XSS can read it and impersonate the
user for the token lifetime (call the BaaS, mint an osionos bridge session). The
refresh token is safely HttpOnly, so localStorage is not even needed.

**Treat:** keep the access token **in memory only** (module variable). On page
load / refresh, call the existing `POST /api/auth/refresh` (HttpOnly cookie) to
re-mint a short-lived access token. This removes the persistent XSS token-theft
target while keeping UX. (The strong CSP lowers XSS likelihood — but this is the
classic "one XSS = account takeover" amplifier; don't rely on the CSP alone.)

### MEDIUM-2 — Username/email enumeration via unthrottled `/availability`
`handleAvailability` (auth-gateway.mjs:846) returns whether an email/username is
registered, with **no rate limit and no Turnstile** (unlike every other auth
route). Combined with HIGH-1 this is a fast account-enumeration oracle — and it
contradicts the deliberately enumeration-safe `/recover`.

**Treat:** rate-limit it (it's the one route that skips `protectedAction`),
debounce server-side, and consider returning availability only after a Turnstile
or only for the form's own session. Accept that some enumeration is inherent to a
"username taken?" UX — at least throttle it hard.

### MEDIUM-3 — Rate limiting / anti-replay state is in-process memory
`buckets`, `signInNoticeBuckets`, `mailDomainCache` are plain `Map`s in one Node
process. They **don't survive restart, don't share across replicas, and never
evict** (unbounded → memory DoS, amplified by HIGH-1). You already run Redis —
the gateway doesn't use it.

**Treat:** move rate-limit + sign-in-notice counters to **Redis** with TTLs;
cap/evict the DNS cache. This makes throttling real under restarts/scaling.

### MEDIUM-4 — No per-account brute-force lockout
Throttling is per-IP only. A distributed attacker (botnet, or via HIGH-1) can
brute-force a single account. GoTrue/bcrypt slows hashing but doesn't lock.

**Treat:** add a per-account failure counter (Redis) with temporary lockout /
exponential backoff, plus the existing "failed sign-in" email alert.

### MEDIUM-5 — Anti-abuse can silently fail OPEN via config
- `TURNSTILE_BYPASS_LOCAL=true` makes `verifyTurnstile` return `true` for an
  empty/`localhost-turnstile-token` (auth-gateway.mjs:216). If it leaks into prod,
  Turnstile is fully bypassed.
- `AUTH_REQUIRE_EMAIL_VERIFICATION=false` routes registration through
  `handleDevConfirmedRegistration` → **confirmed accounts with no email
  verification** for any address.

**Treat:** **fail closed** — at startup, if the site origin is a non-localhost
`https://` host, refuse to boot (or hard-disable) when `TURNSTILE_BYPASS_LOCAL`
is true or `AUTH_REQUIRE_EMAIL_VERIFICATION` is false. Make prod the safe default.

### LOW-1 — Newsletter subscribe is an email-bombing amplifier
`POST /api/newsletter/subscribe` sends a confirmation email to any submitted
address (per-IP rate-limited only). With HIGH-1, an attacker floods a victim's
inbox. **Treat:** per-target (email) rate limiting + the IP fix.

### LOW-2 — Bridge HMAC needs replay protection on the consumer
The gateway signs `timestamp.payload` with the shared secret and includes a
`jti`. Replay safety depends on **osionos-bridge** rejecting stale timestamps and
reusing `jti`. **Treat:** verify the bridge enforces a short timestamp window +
single-use `jti` (audit `scripts/bridge-api.mjs`).

### LOW-3 — Minor info disclosure / open-redirect
- `humanAuthMessage` passes GoTrue `error_description/msg` to the client — keep it
  generic for auth failures.
- `main.ts:1714` does `location.assign(osionosBridge.redirectUrl)` with a
  server-provided (trusted) URL; low risk, but validate it starts with the known
  osionos origin before assigning, as defense in depth.
- Confirm/reset tokens travel in the URL (standard for email links); the CSP +
  `Referrer-Policy: strict-origin-when-cross-origin` limit leakage.

---

## How this relates to the BaaS services (the real boundary)
opposite-osiris is the front of a chain: **website → auth-gateway → Kong → GoTrue
/ PostgREST / Postgres**, plus the **osionos-bridge**. Most data-security does NOT
live in this app — it lives in the BaaS:

- **Postgres RLS is the actual data wall** behind the public anon key. The anon
  key is *meant* to be public; if RLS policies are wrong, the anon key reads/writes
  data directly through PostgREST regardless of how perfect the gateway is. **This
  is the single highest-leverage thing to audit next** — every table reachable via
  Kong/PostgREST must have correct, tested RLS.
- **Service-role key = god mode.** It lives only in the gateway (good). Treat the
  gateway as a high-value target: minimal surface, runtime-injected secret,
  no secrets in the image (verified). An RCE in the gateway = full DB.
- **Kong** should enforce per-route auth, CORS, and request-size/rate limits as a
  second layer — don't let the gateway's in-process limiter be the only throttle.
- **GoTrue** owns password hashing (bcrypt), email OTP, and token signing — keep
  it patched; confirm JWT expiry is short and refresh rotation is on.
- **Vault** is the secret source of truth; **Fly account access = Vault root**
  (root token + unseal keys are readable via `fly ssh` on the Vault machine).
  Protect the Fly account (2FA, scoped tokens) — see
  [vault-security-model](../vault-security-model.md).

---

## Prioritized remediation roadmap
1. **HIGH-1** trusted client-IP derivation (unblocks real throttling). 
2. **MEDIUM-3** move rate-limit/anti-replay state to Redis (bounded, shared).
3. **MEDIUM-1** access token in memory + refresh-on-load (kill the localStorage target).
4. **MEDIUM-5** fail-closed startup guards for Turnstile/email-verification in prod.
5. **MEDIUM-4 / MEDIUM-2 / LOW-1** per-account lockout + throttle `/availability` + per-target newsletter limit.
6. **Audit BaaS RLS policies** (highest data-security leverage) and confirm Kong
   enforces auth/CORS/rate limits as a second layer.
7. **LOW-2** confirm bridge replay protection; **LOW-3** generic auth errors +
   validate redirect origin.

## Re-test after each change
```bash
docker compose --profile testing run --rm playground-simulation   # full account -> osionos must still pass
# plus: targeted checks — XFF-rotation no longer bypasses 429; availability is throttled;
# prod-like env refuses TURNSTILE_BYPASS_LOCAL=true.
```

See also: [externalizing-an-app-to-docker-images](../operations/externalizing-an-app-to-docker-images.md),
[vault-security-model](../vault-security-model.md), [SECURITY.md](../SECURITY.md).
