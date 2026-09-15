# Sensitive Data Exposure

> A failure to adequately protect sensitive information — through missing encryption, weak cryptographic primitives, or insecure key management — allowing an attacker to read data that should be opaque to them.

## What it is

Sensitive Data Exposure occurs when an application stores, transmits, or processes personal, financial, or credential data without enforcing the cryptographic controls required to keep it confidential. The label covers two failure modes that almost always co-occur: data that is never encrypted at all, and data that is nominally encrypted but protected by an algorithm, key length, or implementation that has known weaknesses. Under GDPR, any personal data (name, email, health record, IP address) that can be read by an unauthorised party constitutes a reportable breach regardless of whether an attacker actively exploited the gap. The risk is especially acute at rest (database rows, log files, backups) and in transit (APIs, WebSocket connections, internal service calls). Because the underlying flaw is often a missing control rather than an exploitable code path, it routinely goes undetected until a breach has already occurred.

## How the attack works

1. **Reconnaissance.** The attacker identifies where sensitive data flows: login endpoints, profile APIs, export features, backup buckets, or internal service-to-service calls.
2. **Protocol downgrade or interception.** If TLS is not enforced for all paths — including redirects, internal traffic, and legacy endpoints — the attacker positions themselves on the network (coffee-shop Wi-Fi, a compromised load balancer, a BGP hijack) and captures cleartext or weakly-encrypted traffic.
3. **Database or backup access.** Through SQL injection, a misconfigured S3 bucket, a stolen DB credential, or a compromised cloud snapshot, the attacker obtains a copy of the data store.
4. **Offline cracking.** If passwords are stored with a fast algorithm such as MD5 or unsalted SHA-1, the attacker runs the hash list through a GPU cluster or pre-computed rainbow table. Recovery of the majority of passwords can take minutes.
5. **Pivot or resale.** Recovered credentials are tested against other services (credential stuffing), sold, or used to escalate access within the same application.

**Illustrative example.** Consider a registration endpoint that stores user passwords with `md5(password)` and returns a session token over HTTP (not HTTPS). An attacker who captures a single network response obtains the session token directly. A second attacker who later exfiltrates the `users` table through an unrelated SQL injection vulnerability can recover plaintext passwords for a significant fraction of accounts in hours using publicly available wordlists — exposing those users on every other service where they reuse the same password.

## Real-world impact

The OWASP Top 10 (both the 2017 and 2021 editions) identifies cryptographic failure as one of the most consistently impactful vulnerability classes across the industry, noting that it is "the most common impactful attack" seen over multiple years of data collection. A recurring documented pattern is the exposure of password databases protected only by fast, unsalted hashes: when such a database is leaked, GPU-accelerated cracking tools can recover the majority of passwords from the most common wordlists in a matter of hours, turning a single server compromise into a credential-stuffing source affecting millions of accounts on unrelated services. OWASP also documents the scenario where credit card numbers are "encrypted" in a database but decrypted automatically on every query, meaning a successful SQL injection bypasses the encryption entirely and returns card numbers in cleartext. In both cases the GDPR consequence is the same — mandatory notification to supervisory authorities within 72 hours and potential fines of up to 4% of global annual turnover — because the personal data was not rendered "unintelligible to any person who is not authorised to access it" as required by Article 32. (Source: [OWASP Top 10 2017 — A3 Sensitive Data Exposure](https://owasp.org/www-project-top-ten/2017/A3_2017-Sensitive_Data_Exposure))

## OWASP classification

**A02:2021 — Cryptographic Failures** (formerly "Sensitive Data Exposure" in the 2017 edition). This category covers all failures relating to cryptography or its absence that result in the exposure of sensitive data. Common weaknesses mapped to it include transmitting data in cleartext, using deprecated algorithms (MD5, SHA-1, DES, RC4), weak or hardcoded keys, missing certificate validation, and improper use of padding or initialisation vectors.

Reference: [A02 Cryptographic Failures — OWASP Top 10:2021](https://owasp.org/Top10/2021/A02_2021-Cryptographic_Failures/)

Password-specific implementation guidance: [OWASP Password Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html)

## How defenders stop it

- **Classify data first.** Enumerate every field that qualifies as personal, financial, or credential data under GDPR Article 4 and apply controls proportionate to sensitivity.
- **Encrypt in transit, unconditionally.** Enforce TLS 1.2+ on every endpoint including internal service-to-service calls; redirect HTTP to HTTPS; set `Strict-Transport-Security` with a long `max-age`; disable TLS 1.0/1.1 and weak cipher suites.
- **Encrypt at rest.** Use AES-256 (GCM mode) or equivalent for database columns, backups, and export files containing personal data. Ensure the decryption key is not stored beside the ciphertext.
- **Use memory-hard password hashing.** Replace MD5/SHA-1/bcrypt with Argon2id (minimum: 19 MiB memory, 2 iterations, 1 parallelism) or scrypt. Never store plaintext or reversible password representations.
- **Rotate and protect keys.** Store cryptographic keys in a dedicated secrets manager or hardware security module; never hardcode them or commit them to version control; enforce key rotation schedules.
- **Minimise retention.** Do not log sensitive fields (tokens, passwords, card numbers, PII); truncate or pseudonymise data that does not need to remain in its original form after processing.
- **Validate certificates.** Disable self-signed or expired certificate acceptance in all HTTP clients; pin certificates where the threat model justifies it.
- **Test cryptographic controls.** Include checks for cleartext transmission, weak algorithm negotiation, and hash algorithm in automated security scans and pentest scope.

In this project, see the defenses: [grobase](../defense/grobase/data-protection-gdpr.md), [osionos-bridge](../defense/osionos-bridge/data-protection-gdpr.md), [mail-calendar](../defense/mail-calendar/data-protection-gdpr.md), [platform](../defense/platform/data-protection-gdpr.md).

## References

- [A02 Cryptographic Failures — OWASP Top 10:2021](https://owasp.org/Top10/2021/A02_2021-Cryptographic_Failures/)
- [A3 Sensitive Data Exposure — OWASP Top 10:2017](https://owasp.org/www-project-top-ten/2017/A3_2017-Sensitive_Data_Exposure)
- [OWASP Password Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html)
