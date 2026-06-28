# Security at Track Binocle — defense, attack & why you can trust it

This is the security knowledge base for the `ft_transcendence` monorepo. It exists to answer one
question with **evidence, not adjectives**: *why is it safe to put sensitive content into these apps?*

Every claim here is backed by a real file in this repository. The notes were produced by a
read-only audit that inventoried **175 implemented controls with file-level evidence**, then
adversarially re-checked every citation against the source. Where a claim could not be confirmed in
the code, it was dropped. So when a note says "we do X," you can open the cited file and see X.

---

## Why you can trust these apps with sensitive content

Not because of one strong wall, but because the data sits behind **many independent ones** — the
principle of [defense in depth](attack/defense-in-depth.md). For a single user note to leak, an
attacker would have to defeat *all* of these, each verifiable in the repo:

- **The data owner-scopes itself at the database.** PostgreSQL **Row-Level Security** (with
  `FORCE ROW LEVEL SECURITY`) ties every row to its owner, so even a direct SQL connection sees only
  its own rows — see [platform/row-level-security](defense/platform/row-level-security.md),
  [grobase/row-level-security](defense/grobase/row-level-security.md).
- **The one key that can bypass that never reaches the browser.** The BaaS service-role key lives
  only server-side, behind the [osionos-bridge trust boundary](defense/osionos-bridge/trust-boundary.md)
  and in [vault42, never in git](defense/platform/secrets-management.md).
- **Auth is short-lived and signed.** Reaching the data needs a signed, expiring app-session
  ([osionos-bridge/session-management](defense/osionos-bridge/session-management.md)) minted only
  after authentication, with **algorithm-pinned JWTs**, **TOTP MFA** and **passkeys/WebAuthn**
  available ([grobase/authentication](defense/grobase/authentication.md),
  [grobase/mfa-passkeys](defense/grobase/mfa-passkeys.md)).
- **The edge is hardened.** A **WAF** (ModSecurity + the OWASP Core Rule Set) is the sole public
  listener in front of the [Kong gateway](defense/grobase/cors-misconfiguration.md), and everything
  speaks **TLS 1.2/1.3** ([grobase/web-application-firewall](defense/grobase/web-application-firewall.md),
  [platform/transport-security-tls](defense/platform/transport-security-tls.md)).
- **Releases are gated.** A **supply-chain hold** plus **SAST + SCA + DAST** run in CI, so known-bad
  dependencies and code patterns don't ship ([platform/supply-chain-security](defense/platform/supply-chain-security.md),
  [platform/sast-dast-sca](defense/platform/sast-dast-sca.md)).

The flagship walkthrough of these layers is below: **[Defense in depth — one atom, many
layers](#defense-in-depth--one-data-atom-many-layers)**.

---

## How this wiki is organized

```
wiki/security/
├── README.md                    ← this hub
├── defense/<app>/<concept>.md   ← what each app DOES: the control, grounded in real files,
│                                  with "how we know it's applied" + residual risk
└── attack/<concept>.md          ← the THREAT each control defends against: how the attack works,
                                   a real-world example, the OWASP classification
```

Every **defense** note links the **attack** note for its concept; every **attack** note links back
to the apps that defend against it. Coverage: **7 apps · 32 security concepts · 107 defense notes ·
32 attack notes**.

### How we keep it honest (the "no bullshit" method)

1. **Audit, don't assume.** Read-only auditors inventoried only controls they could back with an
   exact file + the specific code/config that proves it (175 controls).
2. **Write from evidence.** Each defense note was written from that evidence, and the author
   re-opened the cited files to confirm them before writing.
3. **Adversarially verify.** Independent critics re-checked *every* cited path and cross-link and
   flagged anything unsupported; those were corrected against the source.
4. **Original wording, sources cited.** These notes are written in our own words and *cite* the
   security canon below — they never reproduce its text.

---

## The security canon we align to

These notes use standard vocabulary and link out to the authoritative, widely-trusted sources for
each concept.

| Source | What it is | URL |
|--------|-----------|-----|
| **OWASP** | The Open Worldwide Application Security Project — the de-facto standard for web security: the **Top 10** risk list and the **Cheat Sheet Series**. Most notes cite it. | <https://owasp.org> · <https://cheatsheetseries.owasp.org> |
| **SANS Institute** | Security research, training, and the kind of practical whitepapers (e.g. defense-in-depth, zero-trust) we reference for rationale. | <https://www.sans.org> |
| **Krebs on Security** | Brian Krebs' investigative reporting on real breaches and attacker techniques. | <https://krebsonsecurity.com> |
| **The Hacker News** | High-volume reporting on live vulnerabilities, breaches, and malware. | <https://thehackernews.com> |
| **Have I Been Pwned** | Troy Hunt's breach-aggregation service — concrete evidence of what credential exposure costs. | <https://haveibeenpwned.com> |

---

## Defense in depth — one data atom, many layers

The concept (per OWASP [Secure Product Design](attack/defense-in-depth.md)): never rely on a single
control; layer independent ones so that breaching any one still leaves the attacker outside. Here is
that idea applied to **one atom of data — a single row in a user's notebook** (`osionos_pages`):

| # | Layer | What an attacker must additionally defeat | Evidence |
|---|-------|-------------------------------------------|----------|
| 1 | **Row-Level Security** | Even with a DB connection, RLS + `FORCE RLS` returns only the caller's own rows | [platform/row-level-security](defense/platform/row-level-security.md) |
| 2 | **Trust boundary** | The only credential that bypasses RLS (service-role key) is server-side only, never in the browser | [osionos-bridge/trust-boundary](defense/osionos-bridge/trust-boundary.md) |
| 3 | **Signed app-session** | Calls need a short-lived HMAC-signed session token (audience + expiry checked) | [osionos-bridge/session-management](defense/osionos-bridge/session-management.md) |
| 4 | **Authentication + MFA** | The session is minted only after auth; JWTs are algorithm-pinned; TOTP + passkeys available | [grobase/authentication](defense/grobase/authentication.md) · [grobase/mfa-passkeys](defense/grobase/mfa-passkeys.md) |
| 5 | **API gateway** | Kong requires an API key and validates the JWT per route | [grobase/cors-misconfiguration](defense/grobase/cors-misconfiguration.md) |
| 6 | **Web Application Firewall** | ModSecurity + OWASP CRS filters injection/XSS before requests reach Kong | [grobase/web-application-firewall](defense/grobase/web-application-firewall.md) |
| 7 | **Transport security** | TLS 1.2/1.3 + HSTS everywhere; no cleartext to sniff or downgrade | [platform/transport-security-tls](defense/platform/transport-security-tls.md) |
| 8 | **Network segmentation** | Containers are isolated on a private Docker network; data engines bind to loopback | [grobase/network-segmentation](defense/grobase/network-segmentation.md) |
| 9 | **Secrets in vault42** | The keys to all of the above are in a zero-knowledge store, never committed to git | [platform/secrets-management](defense/platform/secrets-management.md) |
| 10 | **Supply chain + CI gates** | Dependencies age before use; SAST/SCA/DAST block vulnerable builds | [platform/supply-chain-security](defense/platform/supply-chain-security.md) · [platform/sast-dast-sca](defense/platform/sast-dast-sca.md) |

> To read that one row, an attacker must defeat **RLS** *and* steal the **service-role key** *and*
> forge a **signed session** *and* pass **Kong** *and* evade the **WAF** *and* break **TLS** *and*
> pierce **network isolation** *and* extract secrets from **vault42** — each an independent barrier.
> That widening scope is the whole point: no single failure is catastrophic.

---

## The apps (defense index)

Each app's folder documents the controls it actually implements. (`grobase` is the backend where
most sensitive-data controls live; `platform` is the cross-cutting infrastructure.)

### grobase — the BaaS backend · [folder](defense/grobase/)
[audit-logging-monitoring](defense/grobase/audit-logging-monitoring.md) ·
[authentication](defense/grobase/authentication.md) ·
[broken-access-control](defense/grobase/broken-access-control.md) ·
[cors-misconfiguration](defense/grobase/cors-misconfiguration.md) ·
[cryptographic-failures](defense/grobase/cryptographic-failures.md) ·
[data-protection-gdpr](defense/grobase/data-protection-gdpr.md) ·
[defense-in-depth](defense/grobase/defense-in-depth.md) ·
[denial-of-service](defense/grobase/denial-of-service.md) ·
[input-validation](defense/grobase/input-validation.md) ·
[mfa-passkeys](defense/grobase/mfa-passkeys.md) ·
[multi-tenancy-isolation](defense/grobase/multi-tenancy-isolation.md) ·
[network-segmentation](defense/grobase/network-segmentation.md) ·
[rate-limiting-brute-force](defense/grobase/rate-limiting-brute-force.md) ·
[row-level-security](defense/grobase/row-level-security.md) ·
[secrets-management](defense/grobase/secrets-management.md) ·
[security-headers-csp](defense/grobase/security-headers-csp.md) ·
[security-misconfiguration](defense/grobase/security-misconfiguration.md) ·
[session-management](defense/grobase/session-management.md) ·
[sql-injection](defense/grobase/sql-injection.md) ·
[supply-chain-security](defense/grobase/supply-chain-security.md) ·
[transport-security-tls](defense/grobase/transport-security-tls.md) ·
[trust-boundary](defense/grobase/trust-boundary.md) ·
[web-application-firewall](defense/grobase/web-application-firewall.md)

### osionos — the block editor · [folder](defense/osionos/)
[broken-access-control](defense/osionos/broken-access-control.md) ·
[cryptographic-failures](defense/osionos/cryptographic-failures.md) ·
[denial-of-service](defense/osionos/denial-of-service.md) ·
[file-upload-security](defense/osionos/file-upload-security.md) ·
[mfa-passkeys](defense/osionos/mfa-passkeys.md) ·
[reverse-tabnabbing](defense/osionos/reverse-tabnabbing.md) ·
[secrets-management](defense/osionos/secrets-management.md) ·
[session-management](defense/osionos/session-management.md) ·
[xss](defense/osionos/xss.md)

### osionos-bridge — website→editor trust boundary · [folder](defense/osionos-bridge/)
[authentication](defense/osionos-bridge/authentication.md) ·
[broken-access-control](defense/osionos-bridge/broken-access-control.md) ·
[cors-misconfiguration](defense/osionos-bridge/cors-misconfiguration.md) ·
[cryptographic-failures](defense/osionos-bridge/cryptographic-failures.md) ·
[data-protection-gdpr](defense/osionos-bridge/data-protection-gdpr.md) ·
[denial-of-service](defense/osionos-bridge/denial-of-service.md) ·
[input-validation](defense/osionos-bridge/input-validation.md) ·
[multi-tenancy-isolation](defense/osionos-bridge/multi-tenancy-isolation.md) ·
[rate-limiting-brute-force](defense/osionos-bridge/rate-limiting-brute-force.md) ·
[secrets-management](defense/osionos-bridge/secrets-management.md) ·
[security-misconfiguration](defense/osionos-bridge/security-misconfiguration.md) ·
[session-management](defense/osionos-bridge/session-management.md) ·
[sql-injection](defense/osionos-bridge/sql-injection.md) ·
[trust-boundary](defense/osionos-bridge/trust-boundary.md)

### opposite-osiris — marketing + auth website · [folder](defense/opposite-osiris/)
[audit-logging-monitoring](defense/opposite-osiris/audit-logging-monitoring.md) ·
[authentication](defense/opposite-osiris/authentication.md) ·
[captcha-bot-protection](defense/opposite-osiris/captcha-bot-protection.md) ·
[clickjacking](defense/opposite-osiris/clickjacking.md) ·
[cors-misconfiguration](defense/opposite-osiris/cors-misconfiguration.md) ·
[cryptographic-failures](defense/opposite-osiris/cryptographic-failures.md) ·
[csrf](defense/opposite-osiris/csrf.md) ·
[denial-of-service](defense/opposite-osiris/denial-of-service.md) ·
[file-upload-security](defense/opposite-osiris/file-upload-security.md) ·
[input-validation](defense/opposite-osiris/input-validation.md) ·
[rate-limiting-brute-force](defense/opposite-osiris/rate-limiting-brute-force.md) ·
[security-headers-csp](defense/opposite-osiris/security-headers-csp.md) ·
[security-misconfiguration](defense/opposite-osiris/security-misconfiguration.md) ·
[session-management](defense/opposite-osiris/session-management.md) ·
[ssrf](defense/opposite-osiris/ssrf.md) ·
[supply-chain-security](defense/opposite-osiris/supply-chain-security.md) ·
[transport-security-tls](defense/opposite-osiris/transport-security-tls.md) ·
[trust-boundary](defense/opposite-osiris/trust-boundary.md) ·
[xss](defense/opposite-osiris/xss.md)

### auth-gateway — the auth BFF · [folder](defense/auth-gateway/)
[audit-logging-monitoring](defense/auth-gateway/audit-logging-monitoring.md) ·
[authentication](defense/auth-gateway/authentication.md) ·
[cors-misconfiguration](defense/auth-gateway/cors-misconfiguration.md) ·
[cryptographic-failures](defense/auth-gateway/cryptographic-failures.md) ·
[csrf](defense/auth-gateway/csrf.md) ·
[denial-of-service](defense/auth-gateway/denial-of-service.md) ·
[input-validation](defense/auth-gateway/input-validation.md) ·
[rate-limiting-brute-force](defense/auth-gateway/rate-limiting-brute-force.md) ·
[secrets-management](defense/auth-gateway/secrets-management.md) ·
[security-misconfiguration](defense/auth-gateway/security-misconfiguration.md) ·
[session-management](defense/auth-gateway/session-management.md) ·
[ssrf](defense/auth-gateway/ssrf.md) ·
[transport-security-tls](defense/auth-gateway/transport-security-tls.md) ·
[trust-boundary](defense/auth-gateway/trust-boundary.md) ·
[xss](defense/auth-gateway/xss.md)

### mail & calendar — Google OAuth apps · [folder](defense/mail-calendar/)
[broken-access-control](defense/mail-calendar/broken-access-control.md) ·
[clickjacking](defense/mail-calendar/clickjacking.md) ·
[cors-misconfiguration](defense/mail-calendar/cors-misconfiguration.md) ·
[cryptographic-failures](defense/mail-calendar/cryptographic-failures.md) ·
[csrf](defense/mail-calendar/csrf.md) ·
[data-protection-gdpr](defense/mail-calendar/data-protection-gdpr.md) ·
[denial-of-service](defense/mail-calendar/denial-of-service.md) ·
[input-validation](defense/mail-calendar/input-validation.md) ·
[secrets-management](defense/mail-calendar/secrets-management.md) ·
[security-misconfiguration](defense/mail-calendar/security-misconfiguration.md) ·
[session-management](defense/mail-calendar/session-management.md) ·
[xss](defense/mail-calendar/xss.md)

### platform / infrastructure — cross-cutting · [folder](defense/platform/)
[audit-logging-monitoring](defense/platform/audit-logging-monitoring.md) ·
[broken-access-control](defense/platform/broken-access-control.md) ·
[clickjacking](defense/platform/clickjacking.md) ·
[cors-misconfiguration](defense/platform/cors-misconfiguration.md) ·
[data-integrity-safeguards](defense/platform/data-integrity-safeguards.md) ·
[data-protection-gdpr](defense/platform/data-protection-gdpr.md) ·
[multi-tenancy-isolation](defense/platform/multi-tenancy-isolation.md) ·
[row-level-security](defense/platform/row-level-security.md) ·
[sast-dast-sca](defense/platform/sast-dast-sca.md) ·
[secrets-management](defense/platform/secrets-management.md) ·
[security-headers-csp](defense/platform/security-headers-csp.md) ·
[security-misconfiguration](defense/platform/security-misconfiguration.md) ·
[sql-injection](defense/platform/sql-injection.md) ·
[supply-chain-security](defense/platform/supply-chain-security.md) ·
[transport-security-tls](defense/platform/transport-security-tls.md)

---

## The threats (attack index)

Each threat note explains how the attack works, a real-world example, and the OWASP classification —
then links the apps that defend against it.

| Threat | Defended in |
|--------|-------------|
| [Broken Access Control / Privilege Escalation](attack/broken-access-control.md) | grobase · osionos · osionos-bridge · mail-calendar · platform |
| [Row-Level Security bypass / Cross-Tenant Leakage](attack/row-level-security.md) | grobase · platform |
| [Multi-Tenant Data Leakage](attack/multi-tenancy-isolation.md) | grobase · osionos-bridge · platform |
| [Trust-Boundary Crossing](attack/trust-boundary.md) | grobase · osionos-bridge · opposite-osiris · auth-gateway |
| [Broken Authentication](attack/authentication.md) | grobase · osionos-bridge · opposite-osiris · auth-gateway |
| [Credential Phishing / Account Takeover (MFA)](attack/mfa-passkeys.md) | grobase · osionos |
| [Session Hijacking / Fixation](attack/session-management.md) | grobase · osionos · osionos-bridge · opposite-osiris · auth-gateway · mail-calendar |
| [Brute Force / Credential Stuffing](attack/rate-limiting-brute-force.md) | grobase · osionos-bridge · opposite-osiris · auth-gateway |
| [SQL Injection](attack/sql-injection.md) | grobase · osionos-bridge · platform |
| [Cross-Site Scripting (XSS)](attack/xss.md) | osionos · opposite-osiris · auth-gateway · mail-calendar |
| [Content-Security-Policy / header gaps](attack/security-headers-csp.md) | grobase · opposite-osiris · platform |
| [Clickjacking](attack/clickjacking.md) | opposite-osiris · mail-calendar · platform |
| [Reverse Tabnabbing](attack/reverse-tabnabbing.md) | osionos |
| [CSRF](attack/csrf.md) | opposite-osiris · auth-gateway · mail-calendar |
| [CORS Misconfiguration](attack/cors-misconfiguration.md) | grobase · osionos-bridge · opposite-osiris · auth-gateway · mail-calendar · platform |
| [SSRF](attack/ssrf.md) | opposite-osiris · auth-gateway |
| [Input Validation / Injection](attack/input-validation.md) | grobase · osionos-bridge · opposite-osiris · auth-gateway · mail-calendar |
| [Cryptographic Failures](attack/cryptographic-failures.md) | every app |
| [Sensitive Data Exposure / GDPR](attack/data-protection-gdpr.md) | grobase · osionos-bridge · mail-calendar · platform |
| [Secrets Exposure](attack/secrets-management.md) | grobase · osionos · osionos-bridge · auth-gateway · mail-calendar · platform |
| [Transport / MITM / Downgrade](attack/transport-security-tls.md) | grobase · opposite-osiris · auth-gateway · platform |
| [Injection via the edge (WAF)](attack/web-application-firewall.md) | grobase |
| [Security Misconfiguration](attack/security-misconfiguration.md) | grobase · osionos-bridge · opposite-osiris · auth-gateway · mail-calendar · platform |
| [Automated Abuse / Bots (CAPTCHA)](attack/captcha-bot-protection.md) | opposite-osiris |
| [Unrestricted File Upload](attack/file-upload-security.md) | osionos · opposite-osiris |
| [Denial of Service](attack/denial-of-service.md) | grobase · osionos · osionos-bridge · opposite-osiris · auth-gateway · mail-calendar |
| [Lateral Movement (Network Segmentation)](attack/network-segmentation.md) | grobase |
| [Logging & Monitoring Failures](attack/audit-logging-monitoring.md) | grobase · opposite-osiris · auth-gateway · platform |
| [Data Tampering / Integrity](attack/data-integrity-safeguards.md) | platform |
| [Vulnerable Components (SAST/DAST/SCA)](attack/sast-dast-sca.md) | platform |
| [Software Supply-Chain Attack](attack/supply-chain-security.md) | grobase · opposite-osiris · platform |
| [Multi-Stage / Layered Intrusion](attack/defense-in-depth.md) | grobase |

---

## Operational security guides (secrets / Vault)

These pre-existing runbooks cover day-to-day secret operations. **Note:** the current secret store
is **vault42** (a zero-knowledge store reached via the `42ctl` CLI — see
[platform/secrets-management](defense/platform/secrets-management.md)); the guides below describe the
earlier HashiCorp-Vault flow and are kept for operational history.

| Document | When to read |
|----------|-------------|
| [vault-admin-seed-retrieval.md](vault-admin-seed-retrieval.md) | Fresh machine setup, "refusing localhost" error, first Fly-token wiring |
| [vault-session-management.md](vault-session-management.md) | Day-to-day session login, token minting, logout |
| [vault-fly-admin-setup.md](vault-fly-admin-setup.md) | Quick fix for the localhost token error |
| [vault-publish-from-home.md](vault-publish-from-home.md) | Publishing updated secrets |
| [vault-owner-recovery-and-invite.md](vault-owner-recovery-and-invite.md) | Lost admin credentials, owner boundary, reset path |
| [../vault-security-model.md](../vault-security-model.md) | Token TTLs, policies, why localhost tokens are rejected |

**Related security reviews:** [baas-rls-audit.md](baas-rls-audit.md) (RLS audit) ·
[opposite-osiris-security-review.md](opposite-osiris-security-review.md) (website review).

---

## Provenance

Generated from a read-only security audit of this repository (175 evidence-backed controls across 7
apps), with OWASP/SANS/Krebs/HIBP reference URLs verified resolving in June 2026, and every defense
note adversarially re-checked against its cited source files. Notes are original; authoritative
sources are cited, never reproduced. Re-run the audit if the stack changes materially.
