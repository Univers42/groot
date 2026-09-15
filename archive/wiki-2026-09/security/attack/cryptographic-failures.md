# Sensitive Data Exposure via Weak/Absent Cryptography

> Cryptographic failures occur when an application either omits cryptographic protection entirely or applies it incorrectly, allowing attackers to recover data that should be confidential.

## What it is

Cryptographic failures encompass a broad class of vulnerabilities that arise when sensitive data — passwords, tokens, PII, financial records, private keys — is transmitted or stored without adequate cryptographic protection. This includes using algorithms that are mathematically broken or practically weak (e.g., `MD5`, `SHA-1`, `DES`, `RC4`), relying on hard-coded or predictable keys, generating randomness from non-cryptographic sources, or transmitting data over unencrypted channels. The failure need not be a complete absence of cryptography: an application using `AES-128-ECB` is still performing encryption, yet the mode leaks structural patterns that can betray plaintext. Even correctly chosen algorithms become liabilities when key management is poor — a key stored in plaintext next to the ciphertext it protects provides no real protection. OWASP elevated this category to second place in the 2021 Top 10 precisely because these failures are pervasive and consistently lead to large-scale data compromise.

## How the attack works

1. **Reconnaissance.** The attacker identifies what sensitive data the application stores or transmits — user credentials, session tokens, PII fields, payment data — and how each is protected. This may involve reading public source code, reviewing API responses, or inspecting TLS configurations with tooling like `testssl.sh`.

2. **Algorithm or mode assessment.** The attacker checks whether hashing algorithms are broken (`MD5`, `SHA-1`), whether block cipher modes leak structure (`ECB`), or whether password hashing uses a fast general-purpose hash (`SHA-256`) instead of a slow, salted memory-hard function (`bcrypt`, `argon2id`, `scrypt`).

3. **Offline cracking (passwords).** If a database containing `MD5`- or `SHA-1`-hashed passwords without per-user salts is leaked, the attacker runs the dump against a precomputed rainbow table or a GPU-accelerated cracker. Millions of entries can be reversed in hours.

4. **Traffic interception (weak transport).** If the application falls back to `TLS 1.0` or accepts deprecated cipher suites, a network-adjacent attacker exploits known protocol weaknesses to decrypt session data in transit.

5. **Key recovery (poor key management).** Hard-coded secrets committed to a public repository, or encryption keys stored in the same database as the ciphertext, are extracted directly and used to decrypt the protected data without any cryptanalysis.

**Illustrative example — unsalted hash reversal:**

```python
# Insecure: fast hash, no salt — entire user table maps to a precomputed lookup
import hashlib
stored = hashlib.md5(b"Summer2024!").hexdigest()
# "9b3f6e..." — found instantly in public rainbow tables

# Secure: memory-hard, salted, per-user cost factor
import bcrypt
stored = bcrypt.hashpw(b"Summer2024!", bcrypt.gensalt(rounds=12))
# reversal requires per-hash brute-force at ~12 rounds cost
```

The insecure line is illustrative only; the intent is to show the structural difference, not to provide a working attack.

## Real-world impact

The 2012 LinkedIn breach is the canonical example of this failure class. Attackers exfiltrated approximately 117 million password records that had been hashed with unsalted `SHA-1` — a fast algorithm with no per-user salt, making the entire table vulnerable to a single rainbow-table pass. The breach was initially disclosed as roughly 6.5 million records; the true scale only became clear in 2016 when the full dump surfaced on the dark web. Troy Hunt documented the scope and indexed the accounts in Have I Been Pwned, where the LinkedIn set remains one of the largest single-service entries. The documented impact category is mass account takeover: because users reuse passwords, cracking LinkedIn credentials gave attackers valid logins to unrelated services for years after the original breach. Source: [Have I Been Pwned — LinkedIn](https://haveibeenpwned.com/PwnedWebsites).

## OWASP classification

- **Category:** A02:2021 — Cryptographic Failures (formerly "Sensitive Data Exposure")
- **Reference:** [A02 Cryptographic Failures — OWASP Top 10:2021](https://owasp.org/Top10/2021/A02_2021-Cryptographic_Failures/)
- **Supporting cheat sheet:** [OWASP Cryptographic Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html) — canonical guidance on algorithm selection, key management, and storage patterns.

## How defenders stop it

- **Classify data by sensitivity** before choosing a protection mechanism; apply stronger controls to credentials, PII, and financial data than to public content.
- **Use `argon2id`, `bcrypt`, or `scrypt`** for password storage; never use `MD5`, `SHA-1`, or unsalted `SHA-2` for this purpose.
- **Use authenticated encryption** (`AES-256-GCM`, `ChaCha20-Poly1305`) for symmetric encryption of stored data; avoid `ECB` mode unconditionally.
- **Enforce TLS 1.2 minimum** on all transports; prefer TLS 1.3; disable weak cipher suites and deprecated protocol versions at the load-balancer or reverse-proxy layer.
- **Never hard-code secrets** in source code or configuration files committed to version control; use a dedicated secrets manager or environment-variable injection at runtime.
- **Rotate keys on a defined schedule** and on any suspected compromise; keep the key separate from the data it protects.
- **Use a cryptographically secure random number generator** (`crypto/rand` in Go, `secrets` module in Python, `crypto.getRandomValues` in the browser) for all token, nonce, and salt generation.
- **Audit third-party dependencies** for known-weak cryptographic primitives; update or replace libraries when CVEs affect their cryptographic correctness.
- **Disable HTTP entirely** for any endpoint that handles authenticated or sensitive sessions; use HSTS with a long `max-age` and `includeSubDomains`.

In this project, see the defenses: [grobase](../defense/grobase/cryptographic-failures.md), [osionos](../defense/osionos/cryptographic-failures.md), [osionos-bridge](../defense/osionos-bridge/cryptographic-failures.md), [opposite-osiris](../defense/opposite-osiris/cryptographic-failures.md), [auth-gateway](../defense/auth-gateway/cryptographic-failures.md), [mail-calendar](../defense/mail-calendar/cryptographic-failures.md).

## References

- [A02:2021 Cryptographic Failures — OWASP Top 10](https://owasp.org/Top10/2021/A02_2021-Cryptographic_Failures/)
- [OWASP Cryptographic Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html)
- [Have I Been Pwned — Pwned Websites (LinkedIn entry)](https://haveibeenpwned.com/PwnedWebsites)
