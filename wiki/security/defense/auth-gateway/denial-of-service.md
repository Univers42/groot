# Denial of Service — auth-gateway (the auth BFF)

> The auth-gateway enforces bounded, TTL-scoped counters for every rate-limit, lockout, and
> anti-replay decision, and adds a per-recipient cap on the newsletter subscribe endpoint to
> prevent IP-rotation–based email-bomb amplification; a Redis outage degrades gracefully to
> the memory store and never causes a fail-open.

## What it is (the concept)

**Denial of Service (DoS)** describes any attack that exhausts a resource — CPU, memory, network
bandwidth, or external service quota — so that legitimate users cannot be served.  In an auth
Backend-for-Frontend (BFF), the two highest-risk surfaces are the **rate-limit / lockout state
store** (which must be bounded to prevent memory exhaustion) and **email-sending endpoints** (which
can be weaponised as an amplifier to flood a victim's inbox regardless of the attacker's source
IP).  The mitigations here apply **application-layer resource controls** rather than
network-layer packet filtering.

## What it defends against

See [Denial of Service (DoS/DDoS)](../../attack/denial-of-service.md).

An attacker targeting the auth-gateway can either (1) exhaust the Node.js process heap by
generating unbounded state entries — rotating IPs to bypass per-IP counters — or (2) weaponise
the newsletter double-opt-in flow to spam a victim's inbox with confirmation emails by making many
subscribe requests from different source addresses.  Both vectors abuse the fact that naive
in-memory counters grow without bound and that email dispatch is cheap for the attacker but
costly for the victim.

## How auth-gateway implements it

### 1 — Per-recipient newsletter throttle (email-bomb prevention)

[`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs)
defines two constants at lines 81–82:

```js
const NEWSLETTER_TARGET_LIMIT = Number(process.env.AUTH_NEWSLETTER_TARGET_LIMIT ?? 3);
const NEWSLETTER_TARGET_WINDOW_SEC = 3600;
```

Inside `handleNewsletterSubscribe`, before the opt-in email is dispatched, a per-recipient counter
is incremented in the store (lines 979–986):

```js
// Per-target cap: stop the newsletter from being used as an email-bomb
// amplifier against a victim's inbox, independent of source IP rotation.
const targetCount = await store.incrWithTtl(
  `rl:newsletter-target:${keyHash(email)}`, NEWSLETTER_TARGET_WINDOW_SEC);
if (targetCount > NEWSLETTER_TARGET_LIMIT) {
  await audit('newsletter_target_throttled', request, { email });
  json(response, 429, { message: 'Too many confirmation emails were requested for this address. Please check your inbox or try again later.' });
  return;
}
```

The key is keyed on `sha256(email)`, so IP rotation cannot circumvent it.  Default ceiling is
**3 requests per hour per address**, overrideable via `AUTH_NEWSLETTER_TARGET_LIMIT`.

### 2 — Bounded state store with transparent Redis fallback

[`apps/opposite-osiris/scripts/auth/store.mjs`](../../../../apps/opposite-osiris/scripts/auth/store.mjs)
ships two backends behind a single `createStore` facade (line 283):

- **`MemoryStore`** — bounded at `maxEntries = 50_000` (line 39) with LRU-style `#evict()` (line
  56) and a periodic `sweep()` (line 64) that prunes expired entries.  Even with no Redis and
  unlimited attacker-controlled keys, heap growth is capped.
- **`RedisStore`** — a zero-dependency RESP client (no transitive npm packages) used when
  `REDIS_URL` is set; provides shared, restart-surviving counter state across replicas.

The `viaRedisOr` wrapper (lines 287–295) prefers Redis when connected and falls through to the
memory store on any Redis error — with an explicit design constraint stated in the file header:

```
State stores NEVER fail auth open.
```

`createStore` is instantiated once at gateway startup in
[`auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs) line 78:

```js
const store = createStore({ redisUrl: config.redisUrl, logger: console });
```

and backs every rate-limit, account-lockout, anti-replay, and newsletter-throttle call in the
process.

Redis is wired in
[`docker-compose.yml`](../../../../docker-compose.yml) line 371:

```yaml
REDIS_URL: ${AUTH_GATEWAY_REDIS_URL:-redis://mini-baas-redis:6379}
```

pointing at the grobase stack's existing Redis instance, so no additional infrastructure is
required.

## How we know it is applied

**Newsletter per-target test** —
[`apps/opposite-osiris/scripts/security/10-gateway-hardening.mjs`](../../../../apps/opposite-osiris/scripts/security/10-gateway-hardening.mjs)
lines 147–167 contain an integration test titled:

```
newsletter subscribe is per-target throttled
```

> Description: "Repeated subscribe for the SAME email is capped per-target (429), blocking
> email-bomb amplification."

The assertion verifies that the 429 response body references `address` or `inbox` (confirming
the per-target code path, not the per-IP path).

**Store unit tests** —
[`apps/opposite-osiris/scripts/security/unit/store.mjs`](../../../../apps/opposite-osiris/scripts/security/unit/store.mjs)
covers eviction, TTL sweep, and RESP client parsing for both the `MemoryStore` and `RedisStore`
backends.

**Live wiring** — `store` is the sole state backend referenced by every throttle call in
`auth-gateway.mjs`; there is no alternative code path that bypasses it.

## Reference

[Denial of Service — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Denial_of_Service_Cheat_Sheet.html)

The OWASP DoS Cheat Sheet emphasises that application-layer resource controls — input validation,
rate limiting, and bounded data structures — are the primary defence when network-layer mitigations
are unavailable or insufficient.  The auth-gateway's combination of per-IP and per-recipient
counters, a capped memory store, and Redis-backed shared state maps directly to its recommended
layered approach.

## Residual risk / assumptions

- **Per-IP throttling is not documented here** — it exists (`rl:<ip>` keys in `auth-gateway.mjs`)
  but is a separate control; this document covers only the DoS-specific controls (memory bounds
  and email-bomb cap).
- The `maxEntries = 50_000` cap is a process-level default.  With many simultaneous Node.js
  replicas and no shared Redis, each process holds up to 50 000 independent entries; an attacker
  can still exhaust total cluster memory if enough replicas are spawned without Redis.
- Redis connectivity depends on the grobase `mini-baas` network being reachable; if that network
  is partitioned for an extended period, all replicas fall back to isolated in-process memory
  stores, losing cross-replica rate-limit coordination until Redis reconnects.
- The `AUTH_NEWSLETTER_TARGET_LIMIT` default of 3 per hour is generous enough to accommodate a
  user who retypes a wrong address; lowering it tightens the window but risks false positives for
  legitimate retries.
- No CAPTCHA or proof-of-work gate precedes the newsletter endpoint; the per-target and per-IP
  counters are the sole admission control before the email is dispatched.
