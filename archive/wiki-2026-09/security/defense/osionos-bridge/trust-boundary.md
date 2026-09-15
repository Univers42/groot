# Website-to-Editor Trust Boundary — osionos-bridge

> The bridge enforces that only the authenticated website (opposite-osiris) may assert a user identity to the editor (osionos), by requiring every cross-boundary session request to carry an HMAC-SHA256 signature computed over a canonicalized payload with a shared secret that neither client possesses.

## What it is (the concept)

A **trust boundary** is a line in a system where the level of trust in data or principals changes — crossing it without verification is the root cause of **privilege escalation** and **identity injection** attacks. In a multi-application architecture, services on opposite sides of a boundary must authenticate one another, not merely the end user. **Signed assertions** enforce this: the sender commits to the exact payload by producing a message authentication code (MAC) that the receiver re-derives and compares before acting on any identity claim.

## What it defends against

See [Privilege Escalation via Trust-Boundary Crossing](../../attack/trust-boundary.md).

In this stack, the website (opposite-osiris) performs GoTrue authentication and then hands off a verified user identity to the editor (osionos) via `POST /api/auth/bridge/session` on the bridge. Without a signed assertion, any process that can reach port 4000 could inject an arbitrary `subject`, `email`, or `provider` and receive a valid editor session token for any user. The HMAC control closes this window entirely: forgery requires the `OSIONOS_BRIDGE_SHARED_SECRET`, which no client-facing component holds.

## How osionos-bridge implements it

All logic lives in [`apps/osionos/app/scripts/bridge-api.mjs`](../../../../apps/osionos/app/scripts/bridge-api.mjs).

**Canonical payload serialization** — `stableStringify` (lines 180–183) produces a deterministic, key-sorted JSON representation of the payload before it is signed, ensuring that two objects with the same fields in different key orders produce the same digest and cannot be used to introduce ambiguity:

```js
// line 180-182
.sort((left, right) => left.localeCompare(right))
.map((key) => JSON.stringify(key) + ':' + stableStringify(value[key]));
return '{' + entries.join(',') + '}';
```

**HMAC-SHA256 signature construction** — `bridgeSignature` (lines 185–187) binds the timestamp to the canonical payload under the shared secret:

```js
export function bridgeSignature(secret, timestamp, payload) {
    return createHmac('sha256', secret).update(`${timestamp}.${stableStringify(payload)}`).digest('hex');
}
```

**Verification with fail-closed secret guard, timestamp skew check, timing-safe comparison, and replay protection** — `verifyBridgeRequest` (lines 351–369) is the complete trust-boundary enforcement function:

- **Line 352** — throws HTTP 503 immediately if `secret` is falsy (bridge never opens without a configured secret).
- **Lines 355–358** — rejects requests whose `X-Prismatica-Bridge-Timestamp` header is not a finite integer or falls outside the allowed skew window (`DEFAULT_TIMESTAMP_SKEW_MS`), returning HTTP 401.
- **Lines 360–362** — recomputes the expected HMAC and compares using `safeCompareHex`, which delegates to Node's `crypto.timingSafeEqual` (line 201) after validating both values are 64-character lowercase hex strings, eliminating timing-oracle attacks.
- **Lines 364–368** — enforces per-`jti` replay protection: each assertion's unique identifier is stored in an in-memory `replayStore` map; a duplicate `jti` within the skew window returns HTTP 409.

**Route wiring** — `handleBridgeSession` (lines 2476–2485) makes `verifyBridgeRequest` the unconditional first action on the `POST /api/auth/bridge/session` route; no session is created unless the function returns successfully:

```js
async function handleBridgeSession(request, response, config, handoffStore, replayStore, fetchImpl) {
    const rawPayload = await readJson(request);
    const payload = verifyBridgeRequest({
        headers: request.headers,
        payload: rawPayload,
        secret: config.sharedSecret,
        ...
    });
    json(response, 200, await createBridgeHandoff({ payload, config, handoffStore, fetchImpl }), config);
}
```

## How we know it is applied

The test suite at [`apps/osionos/app/tests/bridge/bridge-api.test.mjs`](../../../../apps/osionos/app/tests/bridge/bridge-api.test.mjs) provides direct behavioral proof across three cases (lines 181, 186, 204):

- **Line 181** — `'canonicalizes signed payloads with stable key ordering'`: asserts that `stableStringify({ b: 2, a: 1 })` equals `'{"a":1,"b":2}'`.
- **Line 186** — `'accepts a valid HMAC bridge assertion'`: constructs a correctly signed request and asserts the returned `subject` and `email` match the payload.
- **Line 204** — `'rejects tampered signatures and stale timestamps'`: mutates the last character of a valid signature and asserts a `/signature is invalid/` error; separately asserts rejection of a timestamp 600 seconds in the past.

The gate runs via:

```
"test:bridge": "bash scripts/docker-run.sh test-bridge"
# scripts/docker-run.sh line 37 (inside container):
test-bridge) exec node --test tests/bridge/*.test.mjs "$@" ;;
# line 93-94 (host dispatch):
test-bridge) ... run --rm --no-deps playground bash scripts/docker-run.sh test-bridge
```

`npm run test:bridge` is therefore a Docker-isolated, deterministic pass/fail gate that must be green before any bridge change is merged.

## Reference

The OWASP [Threat Modeling Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Threat_Modeling_Cheat_Sheet.html) prescribes identifying trust boundaries as a mandatory step in data-flow decomposition, precisely because inter-process handoffs are where attacker-controlled data crosses from low-trust to high-trust components. This control implements that boundary at the HTTP layer rather than assuming network topology alone provides isolation — a correct application of the STRIDE principle that **spoofing** and **tampering** threats must be addressed at each trust zone crossing, not just at the perimeter.

## Residual risk / assumptions

- **Secret distribution is out of scope for this control.** If `OSIONOS_BRIDGE_SHARED_SECRET` is leaked (e.g., via an environment variable dump, a misconfigured secrets manager, or a compromised CI artifact), an attacker can mint valid assertions. The secret must be rotated immediately if exposure is suspected; the bridge fails closed (503) with no secret configured.
- **Replay protection is in-memory and per-process.** The `replayStore` is not persisted or shared across bridge process restarts or horizontal replicas. A `jti` used in one process instance is invisible to another. In practice the stack runs a single bridge container, but multi-instance deployments require an external store (Redis, etc.) to make replay protection effective.
- **The control protects the bridge endpoint only.** It does not govern direct grobase/Kong API calls from the editor client, which are gated by the app-session token (`osionos_v1.` prefix) returned after a successful handoff — that token's integrity is a separate control (`signAppSessionToken`, line 372+).
- **Timestamp skew is configurable.** `timestampSkewMs` defaults to `DEFAULT_TIMESTAMP_SKEW_MS`; if that constant is widened, the replay-protection window grows proportionally, easing timing attacks on jti reuse.
