# Rate Limiting & Brute-Force Protection — osionos-bridge (website-to-editor trust boundary)

> The bridge enforces a per-authenticated-user token-bucket rate limit on every mutating chat, reaction, and media-upload endpoint, and delegates credential-based brute-force protection entirely to the hardened auth-gateway.

## What it is (the concept)

**Rate limiting** is a traffic-control mechanism that caps how many requests a single client can make within a time window. A **token bucket** is one common algorithm: each client starts with a fixed **burst capacity** of tokens; each request consumes one token; the bucket **refills at a steady rate** (`refillPerSec`) up to the capacity ceiling. When tokens run out, the server rejects new requests with HTTP **429 Too Many Requests** and tells the client when to retry via a `Retry-After` hint.

**Brute-force protection** applies the same principle to credential guessing: by enforcing a strict rate cap on login/register attempts (or by counting failures and imposing a **lockout**), an attacker who submits many guesses per second is slowed to the point that the credential space becomes computationally unreachable.

## What it defends against

See [Brute Force & Credential Stuffing](../../attack/rate-limiting-brute-force.md).

In the osionos-bridge context the primary risk is an authenticated workspace member flooding chat channels or the media-upload endpoint: a single user could drown other members' feeds, exhaust BaaS PostgREST write quotas, or drive Rust realtime publish volume beyond what the single-process bridge can sustain. Because every mutating route is authenticated (session token required), the bucket is keyed on `session.userId`, not IP, giving per-account fairness rather than per-host fairness.

## How osionos-bridge implements it

### Core algorithm — `bridge-ratelimit.mjs`

[`apps/osionos/app/scripts/bridge-ratelimit.mjs`](../../../../apps/osionos/app/scripts/bridge-ratelimit.mjs) is a self-contained, dependency-free (Node built-ins only) token-bucket module. The exported `takeToken(key, { capacity, refillPerSec })` function:

1. Looks up (or creates) a `{ tokens, updatedAt }` bucket in a module-level `Map` keyed by an arbitrary string.
2. Refills tokens proportionally to elapsed wall-clock time, clamped at `capacity` (`Math.min`).
3. Throws an HTTP 429 error with a computed `retrySec` when `tokens < 1`, then decrements by one on success.

```js
// bridge-ratelimit.mjs lines 46-52
bucket.tokens = Math.min(capacity, bucket.tokens + elapsedSec * refillPerSec);
bucket.updatedAt = now;
if (bucket.tokens < 1) {
    const retrySec = Math.ceil((1 - bucket.tokens) / refillPerSec);
    throw httpError(`Too many requests — slow down and retry in ${retrySec}s.`, 429);
}
bucket.tokens -= 1;
```

Idle buckets are pruned after 5 minutes (every 500 operations) so a long-lived process does not accumulate unbounded memory for inactive users.

### Call sites — `bridge-chat.mjs` and `bridge-chat-media.mjs`

[`apps/osionos/app/scripts/bridge-chat.mjs`](../../../../apps/osionos/app/scripts/bridge-chat.mjs) enforces two separate limits, each keyed on the authenticated user's ID:

| Route | Key prefix | Capacity | Refill rate |
|-------|-----------|----------|-------------|
| `POST /api/chat/messages` (message send) | `msg:` | 20 tokens | 5 req/s |
| `POST /api/chat/messages/:id/reactions` (reactions) | `react:` | 30 tokens | 10 req/s |

```js
// bridge-chat.mjs line 303
takeToken(`msg:${session.userId}`, { capacity: 20, refillPerSec: 5 });

// bridge-chat.mjs line 429
takeToken(`react:${session.userId}`, { capacity: 30, refillPerSec: 10 });
```

[`apps/osionos/app/scripts/bridge-chat-media.mjs`](../../../../apps/osionos/app/scripts/bridge-chat-media.mjs) applies a tighter limit on the upload handler (line 110):

```js
// bridge-chat-media.mjs line 110
takeToken(`upload:${session.userId}`, { capacity: 5, refillPerSec: 0.5 });
```

A capacity of 5 with a 0.5 req/s refill means a user can burst up to 5 uploads then is held to one upload every two seconds — appropriate for a collaborative document context where media uploads are expected to be infrequent.

### Auth/credential brute-force — delegation to the auth-gateway

The bridge does **not** implement its own credential lockout. Login and register requests are proxied server-side to the hardened `auth-gateway` service. [`apps/osionos/app/scripts/bridge-api.mjs`](../../../../apps/osionos/app/scripts/bridge-api.mjs) lines 2512–2515 document this explicitly:

```js
// bridge-api.mjs lines 2512-2515
// Proxy the app's login/register to the hardened auth-gateway (server-side, so the
// gateway's website-only CORS does not apply), then mint + return the osionos
// session the app already consumes ({ user, accessToken, refreshToken }). Reuses
// the gateway hardening (lockout/policy) + its register-time workspace creation.
```

Credential-rate enforcement (account lockout, policy) is therefore owned entirely by the `auth-gateway` (Go control-plane), which is the correct architectural boundary: the bridge is a trust-boundary proxy, not an identity provider.

## How we know it is applied

The rate-limiting logic is exercised by a dedicated unit-test suite at [`apps/osionos/app/tests/bridge/bridge-ratelimit.test.mjs`](../../../../apps/osionos/app/tests/bridge/bridge-ratelimit.test.mjs), run via `npm run test:bridge` (Docker-first, inside the `playground` service). The four test cases prove the invariants that matter in production:

```js
it('allows up to capacity then throws 429', ...)
it('refills over time at refillPerSec', ...)
it('never refills above capacity', ...)
it('keeps independent buckets per key', ...)
```

The fourth test — independent buckets per key — is the most security-relevant: it confirms that one user exhausting their budget does not affect another user's bucket, and conversely that a key collision between routes (e.g. `msg:` vs `react:`) cannot grant extra tokens.

The `takeToken` calls sit **inline in the request path**, before any database access, so a throttled request is rejected before any write is attempted.

## Reference

The [Authentication Cheat Sheet — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html) defines the standard controls for brute-force resistance: account lockout, rate limiting by IP or identity, and CAPTCHA layering. The bridge's design maps directly onto OWASP's recommendation to combine burst-rate limiting (the token bucket) with upstream lockout policy (the auth-gateway) rather than duplicating lockout logic inside each application component.

## Residual risk / assumptions

- **Single-process only.** The `Map` is module-level, meaning buckets are not shared across multiple bridge instances. The module header documents this explicitly and states that swapping the `Map` for a Redis-backed shared bucket is the prescribed horizontal-scaling path. Scaling the bridge to multiple replicas without that change would allow users to exceed their per-process limit by distributing requests across instances.
- **Authenticated actions only.** Rate limiting is applied after the session is validated. Unauthenticated endpoints (the auth proxy routes `/api/auth/login` and `/api/auth/register`) are not rate-limited by the bridge; that responsibility is entirely delegated to the auth-gateway. If the auth-gateway's lockout is misconfigured or unavailable, those routes are unprotected at the bridge layer.
- **In-memory state is ephemeral.** A bridge restart resets all buckets. A deliberate restart (crash-loop or container recycle) by an attacker with container access would reset the 429 state, though that threat requires a different class of privilege.
- **No IP-level throttle.** Because the limit is keyed on `session.userId`, pre-authentication flooding (e.g., hammering the handoff endpoint before a session exists) is not covered. Auth-gateway and upstream WAF/reverse-proxy controls are the expected mitigations for that surface.
