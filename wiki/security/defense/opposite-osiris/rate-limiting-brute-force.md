# Rate Limiting and Brute-Force Protection — opposite-osiris (marketing + auth website)

> The auth gateway enforces four layered controls — per-IP sliding-window throttling, per-account
> login lockout, client-side backoff, and per-recipient email-bomb prevention — so that neither IP
> rotation nor distributed credential stuffing can reach the credential store at uncontrolled rates.

---

## What it is (the concept)

**Rate limiting** restricts how many requests a single origin (IP address, user account, or target
email address) may make within a fixed window; once the ceiling is hit the server returns
**HTTP 429 Too Many Requests** with a **Retry-After** header. **Brute-force protection** extends
that concept to authentication flows specifically: failed attempts increment a per-account counter
and, after a configurable threshold, **lock the account** for a cooldown period regardless of how
many source IPs an attacker controls. Together these controls impose a hard cost on automated
credential-testing campaigns.

---

## What it defends against

See [Brute Force and Credential Stuffing](../../attack/rate-limiting-brute-force.md).

In the context of opposite-osiris, the threat is concrete: the site's `/api/auth/login`,
`/api/auth/register`, `/api/auth/recover`, and `/api/auth/availability` endpoints are public
(no session required) and backed by a real BaaS credential store. Without throttling an adversary
can exhaust password dictionaries, enumerate valid usernames via response-timing differences, or
weaponize the newsletter confirmation flow to bomb a victim's inbox. The controls below prevent all
three attack patterns.

---

## How opposite-osiris implements it

### 1 — Per-IP sliding-window rate limits on every auth/newsletter endpoint

[`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs)
defines a `rateLimit()` helper (lines 166-174) that calls `store.incrWithTtl()` to atomically
increment a Redis key and check it against the per-action ceiling:

```js
// lines 79-80 — per-action ceilings (requests per 60-second window, per IP)
const RATE_LIMITS = { login: 8, register: 12, recover: 12, newsletter: 12, availability: 30 };
const RATE_WINDOW_SEC = 60;
```

On excess the function returns an escalating `Retry-After` value (`baseRetry + Math.min((count -
limit) * 2, 30)`) that grows with every additional overage, discouraging sustained hammering. Each
protected handler calls `rateLimit(ip, action)` and, if it returns a non-null value, immediately
returns `HTTP 429` with a `retry-after` header before touching the credential store.

The backing store uses Redis (keyed by `rl:<action>:<ip>`) and falls back to a bounded in-memory
map when Redis is unreachable, so the control survives transient network blips without opening the
gate.

### 2 — Per-account login lockout (IP-rotation-resistant)

After repeated failed logins, the gateway locks the targeted account rather than only the source
IP — making IP rotation useless. The lockout logic in `auth-gateway.mjs` (lines 882-898):

```js
const lockKey = `lock:login:${keyHash(email)}`;   // sha256 of email — no plaintext in store
const failKey = `fail:login:${keyHash(email)}`;
// … after failures >= loginLockoutThreshold (default 10):
await store.set(lockKey, '1', config.loginLockoutSec);  // default 900 s
await store.del(failKey);
// subsequent attempts while locked:
json(response, 429, { message: 'Too many failed attempts for this account…' },
     { 'retry-after': String(Math.ceil(lockRemainingMs / 1000)) });
```

Thresholds are tunable via environment variables `AUTH_LOGIN_LOCKOUT_THRESHOLD`,
`AUTH_LOGIN_LOCKOUT_WINDOW_SEC`, and `AUTH_LOGIN_LOCKOUT_SEC` — the deployed default is
threshold = 10, window = 900 s, lockout = 900 s. A successful login clears the failure counter,
so legitimate users are not locked by a failed attempt after they remember their password.
The lockout key stores only `sha256(email)`, never the plaintext address.

### 3 — Client-side exponential backoff that honors `Retry-After`

[`apps/opposite-osiris/src/hooks/useAuth.ts`](../../../../apps/opposite-osiris/src/hooks/useAuth.ts)
wraps every gateway call in `fetchWithBackoff()` (lines 180-202):

```ts
const retryAfter = Number(response.headers.get('retry-after'));
const baseDelay = Number.isFinite(retryAfter) && retryAfter > 0
  ? retryAfter * 1000
  : 400 * 2 ** attempt;                        // exponential fallback
await delay(Math.min(baseDelay + randomJitter(150), 5000));  // capped at 5 s
```

`randomJitter` draws from `crypto.getRandomValues()`, so simultaneous clients do not produce a
synchronized retry thunderstorm. The default `maxRetries` is `3`; after that the raw 429 is
returned to the caller. On receiving it,
[`apps/opposite-osiris/src/scripts/main.ts`](../../../../apps/opposite-osiris/src/scripts/main.ts)
(lines 1687-1694) shows a user-facing "temporarily blocked" mascot notification rather than silently
retrying again.

### 4 — Per-recipient newsletter cap and deliverable-domain gate

The newsletter subscribe handler in `auth-gateway.mjs` applies two distinct guards before sending
any confirmation email:

1. **Domain deliverability check** (lines 212-223): resolves MX, A, and AAAA records (with a
   3.5 s timeout, result cached in Redis) and rejects `422` for domains with no live DNS evidence.

2. **Per-target throttle** (lines 979-986):

   ```js
   const targetCount = await store.incrWithTtl(
     `rl:newsletter-target:${keyHash(email)}`, NEWSLETTER_TARGET_WINDOW_SEC
   );
   if (targetCount > NEWSLETTER_TARGET_LIMIT)   // default 3 per hour
     json(response, 429, { message: 'Too many confirmation emails…' });
   ```

   This cap is keyed by `sha256(target email)` and enforced even when the request comes from a
   different source IP, so an attacker cannot cycle proxies to flood a victim's inbox using the
   site's transactional-mail relay.

---

## How we know it is applied

The controls are wired into the deployed container at two levels:

**Docker Compose env wiring** —
[`docker-compose.yml`](../../../../docker-compose.yml) lines 369-371 inject `REDIS_URL` into the
`auth-gateway` container so the rate-limit and lockout counters are shared across restarts and
survive container recycles:

```yaml
# Shared, restart-surviving rate-limit / lockout / anti-replay state.
# Falls back to a bounded in-memory store if Redis is unreachable.
REDIS_URL: ${AUTH_GATEWAY_REDIS_URL:-redis://mini-baas-redis:6379}
```

**Live integration tests** —
[`apps/opposite-osiris/scripts/security/10-gateway-hardening.mjs`](../../../../apps/opposite-osiris/scripts/security/10-gateway-hardening.mjs)
sends up to 40 real requests to the running gateway and asserts:
- `/availability` returns `HTTP 429` with a `retry-after` header within 40 requests (lines 100-115).
- Repeated newsletter subscribes for the same address trip a per-target `429` whose message
  references "address" or "inbox" — not a generic IP-level rate limit (lines 147-168).

[`apps/opposite-osiris/scripts/security/11-gateway-failclosed.mjs`](../../../../apps/opposite-osiris/scripts/security/11-gateway-failclosed.mjs)
(lines 169-217) spawns the real gateway process with `AUTH_LOGIN_LOCKOUT_THRESHOLD=3`, hammers
account A until locked (`429` with "too many failed attempts for this account"), then immediately
checks account B from the same connection — asserting it receives a plain `401`, proving the lock is
strictly per-account and not per-IP.

---

## Reference

The OWASP [Authentication Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html)
details why per-account lockout must be decoupled from per-IP throttling: IP-only controls are
trivially bypassed by botnets, while account-keyed lockout imposes a fixed cost regardless of
attacker infrastructure diversity. The same sheet recommends the `Retry-After` response header and
generic error messages (no credential-field disclosure) — both of which the gateway implements.

---

## Residual risk and assumptions

- **In-memory fallback is single-node.** If Redis is unreachable and multiple `auth-gateway`
  replicas are running, each replica holds a separate in-memory counter, effectively multiplying
  every rate-limit ceiling by the replica count. The current deployment is single-replica; scaling
  out without Redis would degrade this control.
- **IP spoofing via `X-Forwarded-For`** is mitigated by `AUTH_TRUSTED_PROXY_HOPS` (set to `2` in
  compose, matching the `local-https-proxy → opposite-osiris-web → gateway` chain), but that
  configuration must be kept in sync if the proxy topology changes.
- **Client-side backoff is advisory, not enforcement.** A custom or headless client ignores
  `fetchWithBackoff` entirely; the server-side 429 is the authoritative enforcement layer.
- **Account lockout is a denial-of-service surface.** A targeted attacker who knows a victim's
  email can deliberately trigger the 900 s lockout. There is currently no CAPTCHA escalation path
  or out-of-band unlock mechanism beyond waiting for the window to expire or using password reset.
- **Per-target newsletter cap does not protect non-registered addresses from a single IP within
  the per-IP window.** An attacker with fresh IPs can still send up to `NEWSLETTER_TARGET_LIMIT`
  (default 3) confirmation emails to a victim within an hour before the per-target key triggers.
