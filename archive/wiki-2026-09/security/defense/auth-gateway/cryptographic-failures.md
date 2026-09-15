# Cryptographic Failures — auth-gateway (the auth BFF)

> The auth-gateway guarantees that every session-handoff request it sends to the osionos bridge is cryptographically authenticated: the request body is signed with HMAC-SHA256 over a deterministic serialisation of the payload keyed by a shared secret, and each token carries a unique `jti` and a millisecond timestamp, making forgery and replay attacks computationally infeasible.

---

## What it is (the concept)

**Cryptographic failures** occur when an application transmits sensitive data — identities, tokens, session material — without adequate integrity protection, allowing an attacker to forge, modify, or replay that data undetected. The relevant primitive here is an **HMAC** (**Hash-based Message Authentication Code**): a keyed digest that proves both the **authenticity** (only the key-holder can produce it) and the **integrity** (any bit-flip in the payload invalidates the digest) of a message. Pairing an HMAC with a **timestamp** and a per-call **jti** (JWT ID, here a random UUID) adds **anti-replay** protection: a captured request cannot be re-submitted later or twice.

---

## What it defends against

See [Sensitive Data Exposure via Weak/Absent Cryptography](../../attack/cryptographic-failures.md).

In this application the threat is cross-service session forgery: the osionos bridge accepts a POST that mints a workspace session for a user. Without a verifiable signature, any network actor reachable to the bridge URL could fabricate an identity payload (`subject`, `email`) and gain an authenticated workspace session as an arbitrary user. The gateway's HMAC scheme ensures the bridge will only honour requests that originate from the one process holding `OSIONOS_BRIDGE_SHARED_SECRET`.

---

## How auth-gateway implements it

All relevant logic lives in [`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs).

### 1 — Deterministic payload serialisation (`stableStringify`, lines 123–130)

Before signing, the payload is serialised with a custom function that sorts object keys lexicographically and recurses into nested structures:

```js
function stableStringify(value) {
    if (value === null || typeof value !== 'object') return JSON.stringify(value);
    if (Array.isArray(value)) return `[${value.map(stableStringify).join(',')}]`;
    const entries = Object.keys(value)
        .sort((left, right) => left.localeCompare(right))
        .map((key) => JSON.stringify(key) + ':' + stableStringify(value[key]));
    return '{' + entries.join(',') + '}';
}
```

Key-order stability is mandatory: if the bridge re-serialises in a different key order before verifying, the digest would never match. Using a bespoke function rather than `JSON.stringify` (whose key-order is engine-defined) eliminates that class of interoperability bug.

### 2 — HMAC-SHA256 signature (`bridgeSignature`, lines 132–136)

```js
function bridgeSignature(timestamp, payload) {
    return createHmac('sha256', config.osionosBridgeSecret)
        .update(`${timestamp}.${stableStringify(payload)}`)
        .digest('hex');
}
```

The signed string is `<epoch-ms>.<stableStringify(payload)>`. Binding the timestamp inside the digest means an attacker cannot strip or alter the timestamp without invalidating the signature.

### 3 — Per-call `jti` and timestamp in the payload (lines 1088–1103)

```js
const payload = {
    provider: 'prismatica',
    subject,          // verified grobase user UUID
    email,            // verified, normalised to lowercase
    name: ...,
    jti: randomUUID(),
};
const timestamp = String(Date.now());
```

`jti` is a `crypto.randomUUID()` value, unique per invocation; `timestamp` is the Unix epoch in milliseconds. Both are included in the signed material and sent as the `x-prismatica-bridge-timestamp` header. If the bridge enforces a timestamp window and deduplicates `jti` values it has processed, replayed or duplicated requests are rejected without needing to crack the key.

### 4 — Identity verified before signing (lines 1071–1085)

The gateway calls `userClient.auth.getUser()` against the grobase BaaS using the caller's bearer token before constructing the payload. The `subject` and `email` placed in the signed payload are therefore grobase-validated, not caller-supplied.

### 5 — Secret sourced from environment, never hard-coded (line 68)

```js
osionosBridgeSecret: process.env.OSIONOS_BRIDGE_SHARED_SECRET ?? '',
```

The key is read exclusively from the environment variable `OSIONOS_BRIDGE_SHARED_SECRET`. A guard at line 1066 returns HTTP 503 immediately if the variable is absent, so the endpoint never silently signs with an empty key.

---

## How we know it is applied

The signature is attached on **every** call to the bridge in `handleOsionosSession` (line 1103):

```js
'x-prismatica-bridge-signature': bridgeSignature(timestamp, payload),
```

`OSIONOS_BRIDGE_SHARED_SECRET` is injected at runtime via the `env_file` directive in the root Docker Compose configuration, sourced from `./.env.local` (which `make all` derives from grobase's self-generated secrets or vault42). The 503 guard (line 1066–1069) ensures the service refuses to operate without the key present, making a misconfigured deploy immediately visible rather than silently degraded.

---

## Reference

[A02 Cryptographic Failures — OWASP Top 10:2021](https://owasp.org/Top10/2021/A02_2021-Cryptographic_Failures/)

This category covers not only the use of broken algorithms but also the complete absence of cryptographic protection on sensitive data in transit between trusted services. The auth-gateway's HMAC scheme addresses precisely the sub-case where an internal, non-public endpoint (the osionos bridge) would otherwise accept unauthenticated identity claims from any caller on the same network segment.

---

## Residual risk / assumptions

- **Bridge-side verification is out of scope here.** The gateway produces a valid signature; whether the bridge actually validates `x-prismatica-bridge-signature`, enforces a timestamp skew window, and deduplicates `jti` values is a separate control in `apps/osionos` — this document makes no claim about that side.
- **Secret rotation is manual.** `OSIONOS_BRIDGE_SHARED_SECRET` is a long-lived symmetric key. If it is compromised, every past signed request becomes forgeable; there is no built-in key-version or rotation mechanism.
- **Network trust assumption.** The HMAC protects message integrity; it does not encrypt the payload. The `subject` and `email` fields are transmitted in plaintext in the POST body. TLS between the gateway and the bridge is the assumed transport-layer protection against eavesdropping; if TLS terminates before the bridge, the payload is visible on the wire.
- **Timestamp drift.** The gateway stamps requests with `Date.now()` on the server; clock skew between containers is possible. If the bridge applies a tight skew window (e.g., ±30 s), NTP misconfiguration could cause valid requests to be rejected.
