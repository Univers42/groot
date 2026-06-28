# Cryptographic Failures — osionos (the block editor)

> The osionos bridge issues HMAC-SHA256-signed session tokens that the server re-verifies on every authenticated request using a constant-time comparison, so a session cannot be forged or tampered without possession of the server-side secret.

## What it is (the concept)

**Cryptographic failures** occur when an application relies on absent, broken, or misapplied cryptography to protect sensitive data or authentication material. The canonical fix for session tokens is a **Message Authentication Code (MAC)**: a keyed digest computed from the payload that allows the server to detect any mutation, because the attacker cannot recompute a valid digest without the secret key. **HMAC-SHA256** is the NIST-recommended construction. A separate hazard is the **timing side-channel**: naive string comparison short-circuits on the first differing byte, leaking information about how close a forgery attempt is to the correct value; the countermeasure is a **constant-time comparison** (`timingSafeEqual`) that always processes every byte before returning.

## What it defends against

See [Sensitive Data Exposure via Weak/Absent Cryptography](../../attack/cryptographic-failures.md).

In osionos's threat model the bridge is the trust boundary: it holds the BaaS service-role key and proxies PostgREST/Kong on behalf of authenticated users. A forged or tampered session token would grant an attacker an arbitrary identity and workspace scope — effectively full account takeover. Without a MAC, any client-visible token field (user id, workspace ids, role, expiry) could be altered and re-submitted. A timing oracle on the verification step would let an attacker iteratively guess or brute-force the signature offline.

## How osionos implements it

All cryptographic primitives are sourced exclusively from `node:crypto` (the Node.js built-in), never from userland re-implementations:

```js
// apps/osionos/app/scripts/bridge-api.mjs — line 16
import { createHash, createHmac, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
```

**Token issuance** (`signAppSessionToken`, line 372–391): the bridge builds a JSON payload carrying `iss`, `aud`, `sub`, `workspace_ids`, `roles`, `jti` (UUID), `iat`, and `exp`, encodes it as base64url, then signs with HMAC-SHA256 keyed by `OSIONOS_APP_SESSION_SECRET`. The resulting token has the form `osionos_v1.<encodedPayload>.<signature>` — the version prefix (`APP_SESSION_TOKEN_VERSION = 'osionos_v1'`, line 77) is a structural migration gate that allows future algorithm rotation.

```js
// bridge-api.mjs — lines 390–391
const signature = createHmac('sha256', config.appSessionSecret).update(encodedPayload).digest('base64url');
return { token: `osionos_v1.${encodedPayload}.${signature}`, ... };
```

**Token verification** (`verifyAppSessionToken`, line 394–429): on every authenticated request the bridge re-derives the expected signature and compares using `safeCompareText`, which wraps `timingSafeEqual` and always allocates equal-length buffers before the comparison — eliminating the timing side-channel:

```js
// bridge-api.mjs — lines 400–401
const expectedSignature = createHmac('sha256', config.appSessionSecret).update(encodedPayload).digest('base64url');
if (!safeCompareText(signature, expectedSignature)) throw ...  // 401
```

```js
// bridge-api.mjs — lines 204–207
function safeCompareText(left, right) {
  const leftBuffer  = Buffer.from(String(left  ?? ''), 'utf8');
  const rightBuffer = Buffer.from(String(right ?? ''), 'utf8');
  return leftBuffer.length === rightBuffer.length && timingSafeEqual(leftBuffer, rightBuffer);
}
```

The verification also enforces `iss === 'osionos-bridge'`, `aud === 'osionos-app'`, UUID-format `sub`, and numeric expiry — a structurally invalid token is rejected before the MAC check.

**Email pseudonymisation**: email addresses are never stored in plaintext in the BaaS identity table. Instead `emailHash` (line 229–230) produces an HMAC-SHA256 hex digest keyed by `OSIONOS_BRIDGE_EMAIL_HASH_SALT`, so a BaaS breach exposes only salted hashes.

```js
// bridge-api.mjs — line 230
return createHmac('sha256', config.emailHashSalt).update(email).digest('hex');
```

**Cryptographically random handoff tokens**: OAuth/SSO handoff tokens are generated with `randomBytes(32).toString('base64url')` (256-bit entropy, line 193–194), not from `Math.random()`.

## How we know it is applied

`verifyAppSessionToken` is called at **30 distinct call sites** in `apps/osionos/app/scripts/bridge-api.mjs` — every route that mutates or reads user-scoped data calls it as the first guard. The helper `requireWorkspaceAccess` (line 761–779) layers a BaaS membership check on top of the MAC check, so neither can be bypassed alone.

The bridge test suite (`apps/osionos/app/tests/bridge/bridge-api.test.mjs`) includes a dedicated acceptance test:

```js
// bridge-api.test.mjs — lines 248–259
it('verifies app-scoped session tokens and rejects invalid ones', () => {
  const verified = verifyAppSessionToken(token, config, issuedAt + 1000);
  assert.equal(verified.userId, subject);
  const replacement = token.endsWith('a') ? 'b' : 'a';
  assert.throws(() => verifyAppSessionToken(token.slice(0, -1) + replacement, config, issuedAt + 1000), /signature is invalid/);
  assert.throws(() => verifyAppSessionToken(token, config, issuedAt + 3_700_000), /expired/);
});
```

A separate test asserts that neither `APP_SESSION_SECRET` nor `OSIONOS_BRIDGE_SHARED_SECRET` leak into any `VITE_*` environment variable exposed to the browser bundle (line 478), closing the secret-leakage path through the build system.

The secret is required at startup: `signAppSessionToken` throws `status: 503` if `config.appSessionSecret` is empty (line 373), preventing silent degradation to an unsigned mode.

## Reference

**A02 Cryptographic Failures — OWASP Top 10:2021**
<https://owasp.org/Top10/2021/A02_2021-Cryptographic_Failures/>

OWASP A02 covers the full spectrum from cleartext transmission to broken algorithms to missing integrity protection on authentication material. The osionos control directly addresses the integrity-failure sub-category: an unsigned or weakly signed session token is the most exploitable manifestation of A02 in stateless API authentication, because it converts every route into an unauthenticated endpoint for anyone who can mutate the token fields.

**Corroborating reference:** NIST SP 800-107 Rev.1 — *Recommendation for Applications Using Approved Hash Algorithms* confirms HMAC-SHA256 as an approved MAC construction for authentication tokens.

## Residual risk / assumptions

- **Secret strength and rotation**: the control's entire guarantee rests on the secrecy and entropy of `OSIONOS_APP_SESSION_SECRET`. If that value is guessable (short, dictionary-derived) or leaked (e.g., committed to git), all issued tokens are forgeable. No in-process key-rotation or revocation mechanism exists — a secret compromise requires a bridge restart with a new secret, invalidating all live sessions.
- **DM content is not encrypted in transit between clients and server**: the E2E WebCrypto module at `apps/osionos/app/src/shared/chat/e2e/crypto.ts` (P-256 ECDH → HKDF-SHA256 → AES-256-GCM) is fully implemented but is not imported by the DM send/receive flow. Message plaintext reaches the bridge and is stored in the BaaS unencrypted. Session-token integrity does not substitute for content encryption.
- **Email hashes are one-way but not anonymous**: HMAC-SHA256 with a known salt reduces the email hash to a keyed construction. If `OSIONOS_BRIDGE_EMAIL_HASH_SALT` is leaked, dictionary attacks against the hashes are feasible for common email addresses.
- **Token expiry is enforced in software, not hardware**: the `exp` check (`exp <= Math.floor(now / 1000)`, line 422) is a server-side validation; it does not prevent a stolen token from being used before expiry. There is no token revocation list.
- **Scope is limited to the bridge trust boundary**: the bridge sits between the frontend and grobase/Kong. TLS between the browser and the bridge is managed by the root-compose WAF/mkcert setup — if TLS is stripped upstream of the bridge (e.g., a misconfigured proxy), this control provides no protection.
