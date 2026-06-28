# Email PII Stored as Keyed HMAC Hash — osionos-bridge (website-to-editor trust boundary)

> The bridge never writes a user's email address to the BaaS; it derives a keyed HMAC-SHA256 digest from the address before any persistence call, so a full dump of the identity table yields no recoverable email.

## What it is (the concept)

**Data minimisation** is the GDPR principle (Art. 5(1)(c)) that only the minimum personal data necessary for a processing purpose may be stored. When the stored artifact must remain linkable across sessions without storing the original PII, a **keyed hash** (also called a **pseudonym** or **pseudonymisation token** under GDPR Art. 4(5)) achieves this: the raw value is replaced by an HMAC digest bound to a secret salt. Unlike an unkeyed hash, a **keyed HMAC** resists offline dictionary and rainbow-table attacks because an attacker without the salt cannot precompute candidate digests.

## What it defends against

See [Sensitive Data Exposure](../../attack/data-protection-gdpr.md). In the osionos-bridge context the threat is an attacker — or a compromised PostgREST/BaaS read credential — obtaining the `osionos_bridge_identities` table and reconstructing user email addresses. Email addresses are high-value PII: they reveal identity across services, enable phishing, and trigger breach-notification obligations. Because the bridge sits at the website-to-editor boundary and holds the BaaS service-role key, a logic flaw or leaked credential in this layer would expose every identity ever processed by the handoff flow.

## How osionos-bridge implements it

Every email hash is produced by a single, centralised helper in
[`apps/osionos/app/scripts/bridge-api.mjs`](../../../../apps/osionos/app/scripts/bridge-api.mjs):

```js
// line 229-231
function emailHash(email, config) {
    return createHmac('sha256', config.emailHashSalt).update(email).digest('hex');
}
```

`config.emailHashSalt` is read at startup from the environment variable `OSIONOS_BRIDGE_EMAIL_HASH_SALT`; the raw secret value never appears in source or logs.

`persistBridgeIdentity` (line 935) calls `emailHash` and passes the result as `p_email_hash` in the PostgREST RPC body — the plaintext address is not included in the request:

```js
p_email_hash: emailHash(payload.email, config),
```

The same hash is used by `resolveAdminFlag` (lines 1036, 1039, 1043) to query and patch `osionos_bridge_identities` by `email_hash`, meaning every read-path that touches identity rows also avoids touching the plaintext address.

## How we know it is applied

The unit test suite (`npm run test:bridge`) exercises this path directly. In
[`apps/osionos/app/tests/bridge/bridge-api.test.mjs`](../../../../apps/osionos/app/tests/bridge/bridge-api.test.mjs),
the test **"persists only hashed identity data through the BaaS RPC"** (lines 301–326) intercepts the outbound fetch, captures the request body, and asserts:

```js
assert.notEqual(requestBody.p_email_hash, payload.email.toLowerCase()); // no plaintext
assert.match(requestBody.p_email_hash, /^[a-f0-9]{64}$/);              // 64-char hex = SHA-256
```

The test also validates that `OSIONOS_BRIDGE_EMAIL_HASH_SALT` is consumed via `configFromEnv` with the key `'test-email-hash-salt'`, confirming the salt is injected from environment — not hardcoded. `persistBridgeIdentity` is called unconditionally inside `createBridgeHandoff` (line 1070) for every login/handoff event, so the hash path is exercised on every authenticated request.

## Reference

[A02 Cryptographic Failures — OWASP Top 10:2021](https://owasp.org/Top10/2021/A02_2021-Cryptographic_Failures/) catalogues inadequate protection of sensitive data, including storing personal identifiers in recoverable form. Replacing an email address with a keyed HMAC directly addresses the "insufficient use of cryptography" failure mode that OWASP A02 describes: the data at rest is computationally unlinkable to the original without the salt, and the salt itself is a runtime secret.

## Residual risk / assumptions

- **Salt compromise is equivalent to full reversal.** If `OSIONOS_BRIDGE_EMAIL_HASH_SALT` leaks — via an `.env` file in a repository, a misconfigured secret manager, or a container escape — an attacker can HMAC-brute-force any email they suspect (email address space is small and enumerable). The control's strength is entirely conditional on the salt remaining secret and sufficiently random.
- **Single salt for all users.** A per-user salt would provide stronger pseudonymisation (each user's hash is independent), but the current design uses one global salt, so the salt rotation requires re-hashing all stored rows.
- **No encryption at rest for the hash column.** The `email_hash` column is stored in plaintext within the BaaS (PostgREST/Postgres). Postgres-level encryption at rest or column-level encryption is not applied by the bridge layer — it relies on the BaaS row-level security policies (enforced by grobase) to restrict who may read those rows.
- **Display name is stored verbatim.** `p_display_name` (the user's full name) is passed to `persistBridgeIdentity` without hashing. The minimisation control applies only to the email address; display names are PII that remain in the identity table in plaintext.
- **No client-side verification.** The hashing occurs server-side inside the Node bridge process. A compromised bridge process (not the BaaS) has access to the plaintext email before the hash is applied.
