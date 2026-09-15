# Credential Theft / Broken Authentication

> An attacker gains illegitimate access to user accounts by exploiting weaknesses in how an application verifies identity — either by stealing valid credentials or by circumventing the authentication mechanism itself.

## What it is

Broken authentication is a broad class of vulnerabilities that arise when the controls an application uses to prove "you are who you claim to be" can be bypassed, guessed, replayed, or stolen. Credential theft is one primary vector: an attacker acquires a working username-and-password pair (or token) without the account owner's consent. The pair can be harvested through phishing, database dumps from unrelated breached services, keyloggers, or insecure transmission over unencrypted channels. Once valid credentials are in hand, the attacker needs no exploit — the login form simply works. Complementary weaknesses (no account-lockout policy, no multi-factor requirement, weak session token entropy, or tokens that never expire) make it possible to abuse stolen credentials at scale and to persist access long after the original compromise.

## How the attack works

1. **Credential acquisition.** The attacker obtains a list of email-and-password pairs. Common sources include publicly leaked database dumps sold on underground markets, phishing pages that mimic the target service, or man-in-the-middle interception of credentials sent over plain HTTP.
2. **Automated stuffing or spraying.** A script iterates through the list, submitting each pair against the target's login endpoint. In a *credential-stuffing* attack the exact stolen pairs are tried; in *password spraying* a small set of common passwords is tried against many accounts to stay under lockout thresholds.
3. **Session establishment.** On a successful match the application issues a session token (cookie or JWT). If that token has an excessively long lifetime or is transmitted without the `Secure` and `HttpOnly` flags, it can itself be stolen for further reuse.
4. **Lateral movement and persistence.** With a valid session, the attacker explores accessible resources, escalates privilege where misconfigured roles allow it, and may change the account's recovery email or phone number to lock the legitimate owner out.

**Illustrative example — credential stuffing against a fictional service:**

```
# Pseudocode — NOT a working tool; shown for conceptual clarity only
for (email, password) in leaked_pairs:
    response = POST /api/login  { email, password }
    if response.status == 200:
        log("valid: " + email)
        # attacker now holds a session token
```

The notable detail is that the application's login logic is never "broken" — the credentials are simply correct. The defence must therefore happen before or around the login endpoint, not only inside it.

## Real-world impact

Credential-stuffing campaigns are consistently among the highest-volume threats recorded. The Have I Been Pwned aggregator — a service that collects verified breach data and lets individuals check their own exposure — indexes more than **17.6 billion** compromised accounts across over **1,000** distinct breaches as of mid-2026. That corpus represents the standing inventory of credential pairs available to attackers. Even a modest match rate (industry estimates typically place credential-stuffing success in the low single-digit percentages on fresh lists) translates to millions of account takeovers when an attacker works at scale. The downstream harm spans unauthorized purchases, fraudulent fund transfers, exposure of stored PII, and downstream phishing of the victim's contacts from within a now-trusted account. See [Have I Been Pwned](https://haveibeenpwned.com/) for the current breach count and to check individual exposure.

## OWASP classification

This attack class maps directly to **OWASP A07:2021 — Identification and Authentication Failures** (formerly "Broken Authentication" in the OWASP Top 10 2017 edition). OWASP maintains a dedicated cheat sheet covering secure implementation requirements: password storage, multi-factor authentication, lockout policy, session lifecycle, and secure credential-recovery flows.

Reference: [Authentication Cheat Sheet — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html)

## How defenders stop it

- **Enforce multi-factor authentication (MFA)** on all accounts, particularly for privileged or sensitive operations; a stolen password alone is then insufficient.
- **Hash passwords with a slow, memory-hard algorithm** (`bcrypt`, `scrypt`, or `Argon2id`) so that leaked credential stores cannot be reversed quickly at scale.
- **Apply progressive account lockout or CAPTCHA** after a configurable number of failed attempts to blunt automated credential-stuffing loops.
- **Rate-limit and monitor login endpoints** for abnormal velocity: many attempts from a single IP, or the same credential tried from many IPs within a short window.
- **Enforce short session lifetimes with absolute and idle timeouts**; require re-authentication before high-impact actions regardless of session age.
- **Transmit all authentication traffic over TLS**; mark session cookies `Secure`, `HttpOnly`, and `SameSite=Strict` to prevent interception and scripted exfiltration.
- **Cross-check new registrations or login attempts against known-breached credential lists** (e.g., via the Have I Been Pwned Pwned Passwords API) and reject or prompt-reset any match.
- **Avoid exposing enumeration signals**: return identical HTTP status codes and response times for unknown users and wrong passwords so attackers cannot infer account existence.
- **Implement secure credential-recovery flows**: time-limited, single-use tokens sent to the registered address rather than security questions or SMS alone.

In this project, see the defenses: [grobase](../defense/grobase/authentication.md), [osionos-bridge](../defense/osionos-bridge/authentication.md), [opposite-osiris](../defense/opposite-osiris/authentication.md), [auth-gateway](../defense/auth-gateway/authentication.md).

## References

- OWASP Authentication Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html>
- Have I Been Pwned — aggregated breach statistics and pwned-password lookup: <https://haveibeenpwned.com/>
