# Cryptographic Failures — opposite-osiris (marketing + auth website)

> HMAC-SHA256 with a per-request timestamp and random JTI ensures that only the
> auth gateway — which possesses the shared secret — can issue valid session-handoff
> requests to the osionos bridge, and that any captured request cannot be replayed.

## What it is (the concept)

**Cryptographic failures** occur when an application uses no cryptography, or uses it
incorrectly — for example by relying on an unsigned, tamper-able token or by omitting
replay protection. **HMAC (Hash-based Message Authentication Code)** is a symmetric
primitive that combines a secret key with a hash function (here SHA-256) to produce a
**message authentication code**: a short tag that proves both the identity of the sender
and the integrity of the message. A **replay attack** is defeated by binding the MAC to
a **timestamp** and a **jti (JWT ID / unique nonce)** so that an identical payload
re-submitted later carries a different or expired signature.

## What it defends against

See [Sensitive Data Exposure via Weak/Absent Cryptography](../../attack/cryptographic-failures.md).

In this application context, the auth gateway must hand a verified user identity over to
the osionos bridge after the BaaS session is validated. Without a cryptographic control
an attacker on the internal Docker network — or who intercepts the request — could forge
an arbitrary identity or replay a legitimately-captured handoff to impersonate another
user. The HMAC binding prevents forgery; the timestamp + jti prevent replay.

## How opposite-osiris implements it

All signing logic lives in
[`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs).

**Deterministic payload serialisation** (`stableStringify`, lines 123-130) sorts object
keys before serialising, so the byte string fed into the HMAC is identical on both sides
regardless of insertion order:

```js
// lines 123-130
function stableStringify(value) {
    if (value === null || typeof value !== 'object') return JSON.stringify(value);
    if (Array.isArray(value)) return `[${value.map(stableStringify).join(',')}]`;
    const entries = Object.keys(value)
        .sort((left, right) => left.localeCompare(right))
        .map((key) => JSON.stringify(key) + ':' + stableStringify(value[key]));
    return '{' + entries.join(',') + '}';
}
```

**MAC generation** (`bridgeSignature`, lines 132-136) signs the string
`${timestamp}.${stableStringify(payload)}` with HMAC-SHA256, keyed on
`config.osionosBridgeSecret` (`process.env.OSIONOS_BRIDGE_SHARED_SECRET`, line 68):

```js
// lines 132-136
function bridgeSignature(timestamp, payload) {
    return createHmac('sha256', config.osionosBridgeSecret)
        .update(`${timestamp}.${stableStringify(payload)}`)
        .digest('hex');
}
```

**Session handoff** (`handleOsionosSession`, lines 1060-1106) enforces a three-stage
pipeline before any bridge call:

1. **BaaS token validation** — `userClient.auth.getUser()` (line 1074) re-checks the
   caller's bearer token against the live BaaS; an expired or forged token stops the
   flow at 401 before any secret is used.
2. **Secret guard** — if `config.osionosBridgeSecret` is empty the handler returns 503
   immediately (lines 1066-1068), preventing an unsigned call from reaching the bridge.
3. **Signed, time-stamped, jti-bound POST** — a `randomUUID()` (line 1093) is included
   in the payload, and `x-prismatica-bridge-timestamp` plus `x-prismatica-bridge-signature`
   are attached to the outgoing request (lines 1102-1103):

```js
// lines 1093-1105 (abridged)
jti: randomUUID(),
// ...
'x-prismatica-bridge-timestamp': timestamp,
'x-prismatica-bridge-signature': bridgeSignature(timestamp, payload),
```

## How we know it is applied

The control is wired into the live runtime via
[`docker-compose.yml`](../../../../docker-compose.yml) (lines 330-338):

```yaml
# Server-only secrets (SERVICE_ROLE_KEY, OSIONOS_BRIDGE_SHARED_SECRET,
# TURNSTILE_SECRET_KEY, SMTP) are injected at RUNTIME via env_file below.
auth-gateway:
  image: ${AUTH_GATEWAY_IMAGE:-dlesieur/prismatica-auth-gateway:latest}
  env_file:
    - path: ./.env.local
      required: false
```

`OSIONOS_BRIDGE_SHARED_SECRET` is never hard-coded in the image; it is injected at
`docker compose up` time from `.env.local` (populated by vault42 or derived locally by
`make env-local-ensure`). The explicit 503 guard at lines 1066-1068 means the bridge
endpoint is fully inoperable — not merely unsigned — if the variable is absent, making
a misconfigured deployment loudly visible rather than silently insecure.

## Reference

[A02 Cryptographic Failures — OWASP Top 10:2021](https://owasp.org/Top10/2021/A02_2021-Cryptographic_Failures/)
classifies the failure to authenticate data in transit as a primary vulnerability
class, distinct from simple confidentiality breaches. The opposite-osiris control
directly addresses the integrity and authenticity sub-category: it is not enough to
encrypt the channel if the receiver cannot verify *who* constructed the message.

## Residual risk / assumptions

- **Bridge-side verification not visible here.** This document covers the signing
  side (auth-gateway). The bridge must independently verify the timestamp staleness
  window and the HMAC; if the bridge implementation is permissive or absent, the
  control provides only one-sided assurance.
- **Shared-secret rotation.** HMAC security degrades if `OSIONOS_BRIDGE_SHARED_SECRET`
  is not rotated periodically; there is no automated rotation mechanism visible in
  this repo — rotation is a manual vault42 operation.
- **No clock-skew policy enforced here.** The timestamp is attached and transmitted
  but the staleness acceptance window is enforced at the bridge (not auditable from
  this file); a lenient bridge window weakens replay resistance.
- **Internal network trust.** The signing assumes the Docker-internal network between
  the gateway and bridge is not accessible to untrusted containers; a compromised
  container on `mini-baas_mini-baas` or the root compose network could attempt a
  replay before the timestamp expires.
