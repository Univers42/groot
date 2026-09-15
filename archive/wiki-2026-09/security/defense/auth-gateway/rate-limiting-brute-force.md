# Rate Limiting and Brute-Force Lockout — auth-gateway (the auth BFF)

> auth-gateway enforces four layered controls — per-IP sliding-window throttling, per-account login lockout, spoof-resistant IP derivation, and a server-side CAPTCHA gate — that together make online credential guessing and scripted credential stuffing economically infeasible against this stack.

## What it is (the concept)

**Rate limiting** bounds the number of requests a client can issue in a sliding time window; once the cap is reached, the server returns **HTTP 429 Too Many Requests** with a `Retry-After` header. **Brute-force lockout** is a complementary, account-scoped control: after a threshold of consecutive failed credential attempts the account is placed in a **temporary lockout** state regardless of source IP. Together they make exhaustive online password search impractical: volume is capped at the IP layer, persistence is blocked at the account layer, and automation is blocked by a **CAPTCHA gate**.

## What it defends against

See [Brute Force & Credential Stuffing](../../attack/rate-limiting-brute-force.md).

In this app context, auth-gateway is the single chokepoint for every credential-bearing action (`/api/auth/login`, `/api/auth/register`, `/api/auth/recover`). Without these controls, an attacker could replay a leaked credential list against the login endpoint until a valid pair is found, or flood the recover endpoint to enumerate registered addresses. The IP throttle limits throughput; the account lockout stops slow, distributed attacks that spread across many source IPs.

## How auth-gateway implements it

### 1. Per-IP, per-action sliding-window rate limiter

[`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs) defines per-action request caps at lines 79-80:

```js
const RATE_LIMITS = { login: 8, register: 12, recover: 12, newsletter: 12, availability: 30 };
const RATE_WINDOW_SEC = 60;
```

`rateLimit(ip, action)` (lines 166-174) increments `rl:<action>:<ip>` in the shared store via `incrWithTtl` and returns a backoff value when the count exceeds the limit. The backoff grows with the degree of overage (`Math.min((count - limit) * 2, 30)` extra seconds) and is forwarded as the `Retry-After` response header.

`protectedAction` (lines 689-695) enforces this check before the request body is read, so the rate gate fires even before Turnstile verification:

```js
async function protectedAction(request, response, action, handler) {
  const ip = clientIp(request);
  const retryAfter = await rateLimit(ip, action);
  if (retryAfter) {
    json(response, 429, { message: 'Too many attempts. Please retry later.' },
      { 'retry-after': String(retryAfter) });
    return;
  }
  ...
}
```

### 2. Per-account login lockout

On each failed password check, `handleLogin` (lines 882-898) increments `fail:login:<sha256(email)>` in the store with a 900-second TTL. When the failure count reaches `AUTH_LOGIN_LOCKOUT_THRESHOLD` (default `10`, configured at line 73), the gateway writes `lock:login:<sha256(email)>` with a TTL of `AUTH_LOGIN_LOCKOUT_SEC` (default `900`) and deletes the counter:

```js
const lockKey = `lock:login:${keyHash(email)}`;
const failKey = `fail:login:${keyHash(email)}`;
const lockRemainingMs = await store.pttl(lockKey);
if (lockRemainingMs > 0) {
  json(response, 429, { message: 'Too many failed attempts…' },
    { 'retry-after': String(Math.ceil(lockRemainingMs / 1000)) });
  return;
}
```

The lock check runs before `signInWithPassword`, so a locked account never reaches the BaaS credential endpoint. Because the key is keyed on `keyHash(email)` — a truncated SHA-256 of the normalised address — the lockout is account-scoped, not connection-scoped: an attacker rotating source IPs cannot escape it.

### 3. Spoof-resistant client-IP derivation

[`apps/opposite-osiris/scripts/auth/net-ip.mjs`](../../../../apps/opposite-osiris/scripts/auth/net-ip.mjs) implements `deriveClientIp` (lines 49-75). It reads `AUTH_TRUSTED_PROXY_HOPS` and counts that many hops from the **right** of the `X-Forwarded-For` chain rather than trusting the attacker-controlled left-most value:

```js
if (trustedProxyHops <= 0) return remote || 'unknown';  // never trust XFF
const chain = forwardedChain(request?.headers?.['x-forwarded-for']);
const index = chain.length - trustedProxyHops;
// Chain shorter than configured: fall back to left-most (over-throttle, never fail-open)
if (index < 0) return chain[0];
return chain[index] ?? remote ?? 'unknown';
```

[`docker-compose.yml`](../../../../docker-compose.yml) sets `AUTH_TRUSTED_PROXY_HOPS: ${AUTH_TRUSTED_PROXY_HOPS:-2}` (line 368), matching the `local-https-proxy → opposite-osiris-web → gateway` hop count deployed in this stack. Without correct proxy-hop accounting, an attacker could prepend arbitrary IPs to the XFF header and land each request in a fresh per-IP bucket.

### 4. Cloudflare Turnstile CAPTCHA gate

`verifyTurnstile` (lines 225-232 of `auth-gateway.mjs`) performs a server-to-server `POST` to `https://challenges.cloudflare.com/turnstile/v0/siteverify` using `TURNSTILE_SECRET_KEY` (never exposed to the client) and the token the browser widget produced:

```js
async function verifyTurnstile(token, ip) {
  if (config.turnstileBypassLocal && (!token || token === 'localhost-turnstile-token')) return true;
  if (!config.turnstileSecret || !token) return false;
  const form = new URLSearchParams({ secret: config.turnstileSecret, response: token, remoteip: ip });
  const response = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', ...);
  return payload?.success === true;
}
```

`protectedAction` invokes `verifyTurnstile` immediately after the rate check (lines 697-702); a failed verification returns `403 Anti-abuse verification failed.` and emits a `login_turnstile_failed` audit event. The bypass flag `TURNSTILE_BYPASS_LOCAL` is blocked on public origins by the startup guard (see below).

## How we know it is applied

**Startup guard (`apps/opposite-osiris/scripts/auth/guards.mjs`, lines 51-72):** `collectStartupViolations` aborts the process on a public HTTPS origin if any of the following are true: `TURNSTILE_BYPASS_LOCAL` is set, `TURNSTILE_SECRET_KEY` is absent, or `AUTH_TRUSTED_PROXY_HOPS` is `<= 0`. This makes misconfiguration a hard boot failure rather than a silent degradation:

```js
if (config.turnstileBypassLocal) violations.push('TURNSTILE_BYPASS_LOCAL is true on a public https origin …');
if (!config.turnstileSecret)     violations.push('TURNSTILE_SECRET_KEY is missing …');
if (Number(config.trustedProxyHops ?? 0) <= 0)
  violations.push('AUTH_TRUSTED_PROXY_HOPS must be >= 1 in production …');
```

**Integration test — per-IP throttle and spoofed-XFF resistance (`apps/opposite-osiris/scripts/security/10-gateway-hardening.mjs`):** The suite asserts a `429` with a `retry-after` header appears within 40 burst `/availability` requests (line 112-113), and that 40 requests each carrying a unique random `X-Forwarded-For` value still trigger a `429` (lines 85-96) — proving the IP-derivation mechanism cannot be evaded by header rotation.

**Integration test — per-account isolation (`apps/opposite-osiris/scripts/security/11-gateway-failclosed.mjs`, line 170):** The test `'per-account lockout is per-account not per-IP'` boots the real gateway process with `AUTH_LOGIN_LOCKOUT_THRESHOLD=3`, drives account A to lockout, then sends a login for account B from the same connection and asserts account B still receives a normal `401` rather than the account-A `429`.

## Reference

The [Authentication Cheat Sheet — OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html) specifies account-lockout thresholds, backoff strategies, and the requirement that lockout state must survive process restarts — criteria this implementation meets through its shared Redis store (`REDIS_URL` wired in `docker-compose.yml`). OWASP explicitly recommends combining IP throttling with account-level lockout because neither mechanism alone is sufficient against distributed attacks; auth-gateway implements both as independent layers.

## Residual risk / assumptions

- **Redis is a single point of failure for all controls.** If the store is unavailable, `incrWithTtl` may throw or return stale state; depending on how `createStore` handles errors the gateway could fail open and bypass rate limiting. No circuit-breaker fallback is visible in the current implementation.
- **Per-IP throttling degrades behind a shared egress NAT.** Legitimate users sharing one public IP (corporate proxy, mobile carrier NAT) will exhaust a common bucket. The 30-request availability cap (`RATE_LIMITS.availability = 30`) is the most likely source of false positives.
- **Turnstile relies on Cloudflare's external SaaS.** A Cloudflare outage or API change affecting `challenges.cloudflare.com/turnstile/v0/siteverify` would cause all `protectedAction` calls to return `403` (fail-closed per line 227: `if (!config.turnstileSecret || !token) return false`), effectively denying service to legitimate users until the dependency recovers.
- **Account lockout does not apply to OAuth / SSO flows.** Only the `handleLogin` password path increments `fail:login:*`; social-login or magic-link paths are not locked out by this mechanism.
- **`AUTH_TRUSTED_PROXY_HOPS` must be correctly set for the deployed topology.** If the hop count is wrong (e.g., an extra reverse proxy is added without updating the env var), the gateway will either over-throttle a shared upstream IP or under-throttle by reading a forged XFF entry. Miscounting is a deployment misconfiguration, not a code defect, and is not caught by CI.
