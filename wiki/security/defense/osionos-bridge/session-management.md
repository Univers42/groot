# Session Management — osionos-bridge (website-to-editor trust boundary)

> The bridge issues a single-use, 256-bit random handoff token (90 s TTL) that
> is exchanged exactly once for an HMAC-signed app-session token carrying a
> fixed issuer, audience, expiry, and per-workspace role scope — ensuring that
> no replayable credential crosses the website-to-editor boundary.

---

## What it is (the concept)

**Session management** is the discipline of minting, binding, transmitting, and
retiring credentials so that each authenticated session is cryptographically
distinct, cannot be impersonated, and expires automatically.  Two primitives are
relevant here: a **handoff token** (a short-lived transport credential for the
OAuth callback redirect) and an **app-session token** (the durable bearer
credential the editor uses on every authenticated request).  The handoff is
deliberately separate from the session so that the OAuth redirect URL — which
may appear in server logs or referrer headers — never carries a long-lived
secret.

---

## What it defends against

See [Session Hijacking / Session Fixation](../../attack/session-management.md).

An attacker who intercepts the OAuth redirect URL, logs a referrer header, or
replays a captured token could impersonate a user without knowing their
password.  In the osionos context this matters doubly: the bridge holds the
BaaS service-role key and proxies PostgREST/Kong on the user's behalf, so a
forged or replayed session grants full workspace read/write access.

---

## How osionos-bridge implements it

### Control 1 — One-time, short-TTL handoff token

**File:**
[`apps/osionos/app/scripts/bridge-api.mjs`](../../../../apps/osionos/app/scripts/bridge-api.mjs)

`randomToken()` (line 193-195) generates the transport credential:

```js
function randomToken() {
    return randomBytes(32).toString('base64url');
}
```

`createBridgeHandoff` (line 1080-1085) mints the token, stores the pending
session under it with a hard expiry of `now + config.handoffTtlMs`
(`DEFAULT_HANDOFF_TTL_MS = 90 * 1000`, line 81), and places the token
**only in the URL fragment** (`redirectUrl.hash = bridge_token=…`, line 1085)
so it is not sent to the server on subsequent navigations.

`consumeHandoffToken` (lines 1095-1110) enforces single-use and TTL:

```js
const record = handoffStore.get(token);
if (!record) throw Object.assign(new Error('Bridge handoff token is invalid.'), { status: 404 });
if (record.expiresAt <= now) {
    handoffStore.delete(token);
    throw Object.assign(new Error('Bridge handoff token has expired.'), { status: 410 });
}
handoffStore.delete(token);
```

A missing token yields `404`; an expired token yields `410`; a valid token is
deleted on first read — any subsequent attempt with the same value returns
`404`.

### Control 2 — HMAC-signed app-session token with bound claims

**File:**
[`apps/osionos/app/scripts/bridge-api.mjs`](../../../../apps/osionos/app/scripts/bridge-api.mjs)

`signAppSessionToken` (lines 372-391) produces
`osionos_v1.<base64url(payload)>.<HMAC-SHA256 base64url>`.  The payload binds:

| Claim | Value |
|---|---|
| `iss` | `'osionos-bridge'` (fixed issuer) |
| `aud` | `'osionos-app'` (fixed audience) |
| `sub` | user UUID |
| `workspace_ids` | authorized workspaces only |
| `roles` | per-workspace role map |
| `is_admin` | boolean, explicit |
| `jti` | `randomUUID()` per issuance |
| `iat` / `exp` | `exp = iat + config.sessionTtlSeconds` (`DEFAULT_SESSION_TTL_SECONDS = 3600`, line 82) |

The HMAC key is `OSIONOS_APP_SESSION_SECRET` (the env-var name; the value is
never logged or embedded).  If the secret is absent the function throws
immediately with HTTP 503 (line 373) — missing config fails closed, not open:

```js
if (!config.appSessionSecret)
    throw Object.assign(new Error('osionos app session secret is not configured.'), { status: 503 });
```

`createUserSession` (line 974) calls `signAppSessionToken` for every issued
session; the resulting token is the sole bearer credential accepted by all
authenticated bridge routes.

---

## How we know it is applied

**Test gate** —
[`apps/osionos/app/tests/bridge/bridge-api.test.mjs`](../../../../apps/osionos/app/tests/bridge/bridge-api.test.mjs),
line 348:

```js
it('creates a one-time handoff token for the frontend', async () => {
    const handoffStore = new Map();
    const handoff = await createBridgeHandoff({ payload: validateBridgePayload(payload), config: testConfig(), handoffStore, now });
    const bridgeToken = new URL(handoff.redirectUrl).hash.replace('#bridge_token=', '');
    assert.equal(handoff.ok, true);
    assert.equal(handoffStore.size, 1);
    const imported = consumeHandoffToken(decodeURIComponent(bridgeToken), handoffStore, now + 1000);
    assert.equal(imported.session.userId, subject);
    assert.equal(handoffStore.size, 0);                                      // consumed
    assert.throws(() => consumeHandoffToken(decodeURIComponent(bridgeToken), handoffStore, now + 1000), /invalid/);  // second use fails
});
```

The test asserts: store size 1 after mint, size 0 after consume, and an
explicit `throws /invalid/` on a second consume attempt.  This runs as part of
`npm run test:bridge` (Docker-gated, wired through `scripts/docker-run.sh`).

**Server-wiring** — `createBridgeServer` (line 2613) creates `handoffStore` as
a single `new Map()` per server instance (line 2615):

```js
const handoffStore = options.handoffStore ?? new Map();
```

`createBridgeHandoff` writes to this map; `handleBridgeConsume` and
`handleAuthProxy` read-and-delete from the same reference.  There is no
secondary path for the store — the single-use guarantee cannot be bypassed by
calling an alternate route.

---

## Reference

The [OWASP Session Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html)
establishes the canonical requirements for session token entropy, binding,
expiry, and invalidation.  The bridge satisfies the entropy requirement with
`randomBytes(32)` (256 bits, well above the 128-bit minimum), the binding
requirement through HMAC-tied issuer/audience/expiry claims, and the
invalidation requirement through immediate delete-on-consume for handoff tokens
and a 1-hour hard expiry for app-session tokens.

OWASP maps this control family to
**A07:2021 — Identification and Authentication Failures**, the category
covering insufficient session randomness, missing expiry, and token reuse.

---

## Residual risk / assumptions

- **In-memory store only.** `handoffStore` is a plain `Map` — a bridge process
  restart (or a horizontally-scaled second instance) loses all in-flight tokens.
  Users mid-login on a restarted or unshared instance will receive a `404` and
  must retry.  In the current single-process deployment this is acceptable; a
  multi-replica deployment would require an external store (Redis, etc.).
- **Fragment delivery is browser-enforced.** The decision to put `bridge_token`
  in the URL fragment (not the query string) prevents server-side logging of the
  token, but relies on browser implementations not forwarding fragments in
  `Referer` headers (RFC 7231 §5.5.2 compliant browsers strip them).
- **`OSIONOS_APP_SESSION_SECRET` rotation is manual.** The bridge has no
  key-rotation or token-revocation mechanism beyond natural expiry.  A
  compromised secret requires restarting the bridge with a new secret, which
  invalidates all live sessions simultaneously.
- **App-session tokens are not revocable before expiry.** The 1-hour TTL is the
  only revocation mechanism.  A stolen app-session token is valid for up to 60
  minutes regardless of a server-side logout.
- **No cookie `HttpOnly`/`Secure` flags.** The app-session token is delivered
  to the React app via the URL fragment exchange and then stored in JavaScript
  memory (via the user store / `globalThis.__playgroundUserStore`).  It is not
  placed in a cookie, so cookie-based theft vectors do not apply; however, XSS
  in the editor process would expose the token directly.
