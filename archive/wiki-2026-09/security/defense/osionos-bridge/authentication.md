# Authentication — osionos-bridge (website-to-editor trust boundary)

> The bridge enforces two distinct authentication layers — signed handoff assertion verification with replay rejection, and HMAC-based bearer-token verification with issuer/audience/expiry/scope checks — so that neither a captured handoff nor a forged session token can obtain workspace access.

## What it is (the concept)

**Authentication** is the process of verifying that a presented credential was genuinely issued by the expected authority and has not been tampered with, replayed, or expired. In the bridge context there are two credential types: the short-lived **bridge assertion** (a signed, timestamped handoff from the website), and the resulting **app-session token** (an HMAC-signed bearer token the editor presents on every subsequent request). Both credentials carry a **jti** (JWT ID) or equivalent integrity field; both are verified with **timing-safe comparison** to prevent side-channel leakage. The bridge acts as the sole issuer and verifier of the app-session token, which is intentionally distinct from the grobase/gotrue JWT.

## What it defends against

See [Credential Theft / Broken Authentication](../../attack/authentication.md).

Capturing and replaying a valid handoff assertion — or forging a bearer token — would allow an attacker to impersonate an authenticated user and gain workspace access without ever holding the user's credentials. In this app, the website and the block editor run as separate origins with a shared-secret boundary; any gap in that boundary (stale assertion reuse, token forgery, audience confusion) would directly expose BaaS service-role operations performed by the bridge on behalf of the user.

## How osionos-bridge implements it

### Layer 1 — handoff replay defense (`verifyBridgeRequest`)

[`apps/osionos/app/scripts/bridge-api.mjs`](../../../../apps/osionos/app/scripts/bridge-api.mjs) exports `verifyBridgeRequest` (line 351), which enforces three independent guards in order:

1. **Timestamp skew window** — the `X-Prismatica-Bridge-Timestamp` header value must satisfy `Math.abs(now - timestamp) <= timestampSkewMs` where `DEFAULT_TIMESTAMP_SKEW_MS = 5 * 60 * 1000` (line 80). Any assertion outside ±5 minutes is rejected with HTTP 401.
2. **Signature integrity** — `bridgeSignature(secret, timestamp, normalizedPayload)` is recomputed and compared via `safeCompareHex`, which delegates to Node's `timingSafeEqual` (lines 199–201), preventing timing-based secret guessing.
3. **jti deduplication** — `pruneExpiringMap(replayStore, now)` evicts expired entries; `replayStore.has(jti)` returns HTTP 409 if the jti was already seen; then `replayStore.set(jti, { expiresAt: now + timestampSkewMs })` records it (lines 364–368). `validateBridgePayload` (line 341) requires the jti to match `UUID_REGEX` before any other check runs.

The `replayStore` is allocated once per server instance at `createBridgeServer` (line 2616) and threaded into every `handleBridgeSession` call (line 2483), so the store is global and not bypassable by opening a new request path.

### Layer 2 — app-session token verification (`verifyAppSessionToken`)

[`apps/osionos/app/scripts/bridge-api.mjs`](../../../../apps/osionos/app/scripts/bridge-api.mjs) exports `verifyAppSessionToken` (line 394), applied at the top of every authenticated handler. The verification chain is:

```js
// lines 396–430 (condensed)
const [version, encodedPayload, signature, extra] = token.split('.');
if (version !== 'osionos_v1' || extra !== undefined) → 401
if (!safeCompareText(signature, expectedSignature))  → 401  // timing-safe
if (payload.iss !== 'osionos-bridge' || payload.aud !== 'osionos-app') → 401
if (!UUID_REGEX.test(payload.sub)) → 401
if (exp <= Math.floor(now / 1000)) → 401  // 'expired'
if (workspaceIds.length === 0)     → 401  // no UUID workspace_ids
```

`safeCompareText` (lines 204–208) converts both sides to `Buffer` and calls `timingSafeEqual`, so a wrong-length or wrong-content signature cannot be timed. A token signed with a different secret, mutated in transit, aimed at the wrong audience (`aud !== 'osionos-app'`), expired, or lacking a valid workspace scope is rejected before any data access.

`verifyAppSessionToken` is called at the entry point of every authenticated handler: `requireWorkspaceAccess` (line 763), `ownerOrWorkspaceAccess` (line 825), and more than a dozen direct handler calls at lines 1637, 1653, 1674, 1683, 1703, 1747, 1777, 1800, 1810, 1900, 1927, 1943, 2217, 2273, 2284.

## How we know it is applied

**Unit tests in [`apps/osionos/app/tests/bridge/bridge-api.test.mjs`](../../../../apps/osionos/app/tests/bridge/bridge-api.test.mjs) demonstrate live rejection paths:**

```js
// line 204 — timestamp guard
assert.throws(() => verifyBridgeRequest({
  headers: { 'x-prismatica-bridge-timestamp': String(now - 600_000), … },
  …
}), /timestamp is outside/);

// line 221 — jti deduplication
verifyBridgeRequest(request);                            // first call: accepted
assert.throws(() => verifyBridgeRequest(request), /replay rejected/);

// line 257–259 — token tamper + expiry
assert.throws(() => verifyAppSessionToken(token.slice(0,-1) + replacement, config, …), /signature is invalid/);
assert.throws(() => verifyAppSessionToken(token, config, issuedAt + 3_700_000), /expired/);
```

These tests run under `npm run test:bridge`, which is the gate executed in CI for the bridge surface. The `replayStore` singleton allocation at `createBridgeServer` (line 2616) guarantees the in-process deduplication store is live for the server's lifetime, not just during test execution.

## Reference

The [Authentication Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html) (OWASP) establishes the standard for multi-factor credential integrity: it prescribes comparing credentials with constant-time functions and enforcing short credential lifetimes to reduce the replay window — both properties the bridge satisfies through `timingSafeEqual` and the ±5-minute skew window. OWASP maps the failure mode to **A07:2021 Identification and Authentication Failures**, the category directly mitigated here.

## Residual risk / assumptions

- **`OSIONOS_BRIDGE_SHARED_SECRET` and `OSIONOS_APP_SESSION_SECRET`** must be present and non-empty at server start; the bridge throws HTTP 503 if either is absent but does not verify their entropy — a short or guessable secret degrades both layers simultaneously.
- The `replayStore` is **in-process and not shared across bridge replicas**. A horizontally scaled deployment (multiple bridge containers) would allow the same jti to be accepted once per replica; a shared cache (Redis, etc.) would be required to close that gap.
- The timestamp window (±5 min) is fixed by constant; clock skew between the website and bridge containers larger than 5 minutes will produce false 401s, creating pressure to widen the window.
- App-session tokens are **opaque bearer tokens**, not revocable before `exp`. Signing-secret rotation invalidates all live tokens immediately (users are logged out), but a token issued seconds before rotation and valid for up to `DEFAULT_SESSION_TTL_SECONDS` (3600 s) cannot be individually revoked.
- The replay store evicts entries after `timestampSkewMs` (5 min), which is also the acceptance window. An attacker who replays a jti within the same 5-minute window is blocked; beyond 5 minutes the jti is evicted — but the assertion's timestamp is also stale, so the timestamp check provides the second barrier. The two controls are complementary, not redundant.
