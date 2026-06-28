# Constant-Time Signature Comparison — osionos-bridge (website-to-editor trust boundary)

> Every HMAC signature checked by the bridge — handoff, app-session, and LiveKit token — is compared with `crypto.timingSafeEqual`, removing the timing oracle that would otherwise let an attacker brute-force a valid signature one byte at a time.

## What it is (the concept)

A **timing side-channel** arises when a byte-by-byte string comparison returns early on the first mismatched byte: the response time leaks how many leading bytes of a guess are correct, turning a 2^256-space brute-force into at most 256 sequential guesses. **Constant-time comparison** eliminates that oracle by ensuring comparison time is independent of input content. Node's `crypto.timingSafeEqual` fulfills this guarantee; it operates on equal-length `Buffer` objects and must be paired with an **explicit length check** before the call, because unequal-length inputs would panic rather than return false.

## What it defends against

See [Sensitive Data Exposure via Weak/Absent Cryptography](../../attack/cryptographic-failures.md). In the osionos-bridge context the threat is **HMAC signature forgery by timing measurement**: an attacker who can make repeated unauthenticated requests to `/api/handoff`, the session-verification middleware, or `/api/rtc/token` and measure sub-millisecond response deltas could progressively recover the correct signature without knowing `OSIONOS_BRIDGE_SHARED_SECRET` or `OSIONOS_APP_SESSION_SECRET`. Because the bridge holds the BaaS service-role key, a forged session token would grant unauthenticated workspace access.

## How osionos-bridge implements it

The control is encapsulated in two private helpers in [`apps/osionos/app/scripts/bridge-api.mjs`](../../../../apps/osionos/app/scripts/bridge-api.mjs):

```js
// lines 197-208
function safeCompareHex(left, right) {
    if (!/^[a-f0-9]{64}$/i.test(left) || !/^[a-f0-9]{64}$/i.test(right)) return false;
    const leftBuffer = Buffer.from(left, 'hex');
    const rightBuffer = Buffer.from(right, 'hex');
    return leftBuffer.length === rightBuffer.length && timingSafeEqual(leftBuffer, rightBuffer);
}

function safeCompareText(left, right) {
    const leftBuffer = Buffer.from(String(left ?? ''), 'utf8');
    const rightBuffer = Buffer.from(String(right ?? ''), 'utf8');
    return leftBuffer.length === rightBuffer.length && timingSafeEqual(leftBuffer, rightBuffer);
}
```

`safeCompareHex` additionally validates the 64-hex shape before decoding, preventing a panic from a malformed input buffer. Both helpers guard an explicit `.length` check before passing to `timingSafeEqual` — the one requirement Node's API imposes on callers.

These helpers cover all three signature verification paths in the bridge:

- **Handoff HMAC** (line 361): `safeCompareHex(expected, signatureHeader)` — compares the SHA-256 HMAC over the bridge payload against the `x-prismatica-bridge-signature` header sent by the website.
- **App-session token** (line 401): `safeCompareText(signature, expectedSignature)` — verifies the `osionos_v1.<payload>.<sig>` token on every authenticated API call into the editor.
- **LiveKit JWT** ([`apps/osionos/app/scripts/bridge-rtc.mjs`](../../../../apps/osionos/app/scripts/bridge-rtc.mjs), line 118): direct `timingSafeEqual` call after an explicit length guard, verifying HS256 signatures on RTC token grants.

All three use `createHmac('sha256', secret)` from `node:crypto`; the secret values are referenced only via environment variable names (`OSIONOS_BRIDGE_SHARED_SECRET`, `OSIONOS_APP_SESSION_SECRET`, `LIVEKIT_API_SECRET`) and are never logged or embedded in source.

## How we know it is applied

The unit test suite at [`apps/osionos/app/tests/bridge/bridge-api.test.mjs`](../../../../apps/osionos/app/tests/bridge/bridge-api.test.mjs) exercises the rejection branch for both paths:

```js
// line 204-212 — handoff path
it('rejects tampered signatures and stale timestamps', () => {
    const signature = bridgeSignature(secret, timestamp, validateBridgePayload(payload));
    assert.throws(() => verifyBridgeRequest({
        headers: { ..., 'x-prismatica-bridge-signature': signature.replace(/.$/, '0') },
        ...
    }), /signature is invalid/);
});

// line 257-258 — app-session path
const replacement = token.endsWith('a') ? 'b' : 'a';
assert.throws(() => verifyAppSessionToken(token.slice(0, -1) + replacement, config, issuedAt + 1000), /signature is invalid/);
```

These tests run as `npm run test:bridge` (inside the `playground` Docker service), which is part of the CI quality gate. The gate must pass before any merge.

## Reference

[A02 Cryptographic Failures — OWASP Top 10:2021](https://owasp.org/Top10/2021/A02_2021-Cryptographic_Failures/) identifies the shift from "Sensitive Data Exposure" to a root-cause framing: weak or absent cryptographic primitives, not just their consequences. The OWASP guidance explicitly lists timing attacks under the failure modes addressed by this category, making constant-time comparison a direct mitigation for A02 rather than a peripheral hardening measure.

## Residual risk / assumptions

- The constant-time guarantee applies **after** the request reaches the Node process. A TLS termination layer that leaks response timing at the TCP level could partially restore the oracle — the stack terminates TLS at the `osionos-bridge` container itself, so this path is short, but network jitter on a loopback interface is not zero.
- `safeCompareText` relies on equal-length buffers to satisfy `timingSafeEqual`'s precondition; the explicit `.length` pre-check is load-bearing. Any refactor that separates the guard from the call would reintroduce a panic path.
- The control covers only the **bridge's own signature checks**. Upstream gotrue JWT verification (inside grobase/Kong) and downstream PostgREST RLS enforcement are outside the bridge's trust boundary and are not governed by this control.
- Secret rotation (changing `OSIONOS_BRIDGE_SHARED_SECRET` or `OSIONOS_APP_SESSION_SECRET`) is a manual operational step; there is no automated rotation gate. Compromised secrets are not mitigated by this control — only active forgery attempts are.
