# Brute Force & Credential Stuffing

> Automated, high-volume login attempts that exploit weak account lockout controls or reuse known-compromised credential pairs to gain unauthorized access to accounts.

## What it is

Brute force attacks systematically enumerate possible passwords against a target account until a valid combination is found. Credential stuffing is a specific, more efficient variant: instead of guessing arbitrary passwords, the attacker feeds a corpus of username/password pairs harvested from prior data breaches into an automated login loop, betting that victims reuse the same credentials across services. Both attacks treat the authentication endpoint as a stateless oracle — each attempt is a yes/no query — and scale linearly with the attacker's request throughput. What makes credential stuffing particularly damaging is that the attacker requires no cryptographic knowledge; they simply replay valid secrets obtained elsewhere. The barrier to entry is low: breach databases containing hundreds of millions of credential pairs are freely circulated, and off-the-shelf tools automate the replay at scale.

## How the attack works

1. **Acquisition.** The attacker obtains a credential corpus — typically a plaintext or cracked dump from a third-party breach, purchased on underground markets or freely indexed.
2. **Target reconnaissance.** The attacker identifies the application's login endpoint, request format (form POST, JSON body, OAuth flow), and any visible rate-limiting signals (HTTP 429, CAPTCHA challenges, cookie requirements).
3. **Automation setup.** A script or commercial credential-stuffing tool is configured to rotate IP addresses (via residential proxy networks), randomize `User-Agent` headers, and throttle per-IP request rates to stay below naive detection thresholds.
4. **Replay loop.** The tool submits credential pairs at controlled cadence, parsing HTTP response codes, redirect targets, or body tokens to classify each attempt as success or failure.
5. **Harvest.** Valid sessions or tokens from successful logins are extracted, and the corresponding accounts are then accessed — often to drain stored payment methods, sell the session, or pivot into linked services.

**Illustrative (non-weaponized) example.** An attacker with a 10 million record corpus and a pool of 500 residential proxy IPs could — absent controls — distribute 20 000 attempts per IP. A naive rate limiter keyed only on IP address would observe 20 000 requests per IP over hours, well below any per-IP threshold, while the application processes the full 10 million attempts. The correct control layer must aggregate signals across IP, device fingerprint, account identifier, and behavioral anomaly simultaneously.

## Real-world impact

Credential stuffing is not a theoretical risk. Brian Krebs documented the broader credential-stuffing economy in depth, noting that freely available tools and billion-record breach compilations have made account takeover a commodity attack requiring minimal technical skill ([krebsonsecurity.com](https://krebsonsecurity.com/tag/credential-stuffing/)). In terms of scale, the "Collection #1" dump published in early 2019 — catalogued through Have I Been Pwned — contained over 770 million unique email addresses paired with passwords, providing attackers a ready-made stuffing corpus across every online service those users touched. The documented impact class is consistent: account takeover, fraudulent transactions, unauthorized data access, and downstream reputational and regulatory liability for the breached service — even though the service itself was never directly compromised.

## OWASP classification

This attack class is addressed under the OWASP Authentication Cheat Sheet, which defines controls specifically targeting automated credential attacks — lockout policies, multi-factor authentication requirements, breached-password detection, and rate limiting at the authentication layer.

Reference: [Authentication — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html)

## How defenders stop it

- **Rate limiting per account identifier, not just per IP.** Keying limits on the target `username` or `email` field catches distributed attacks that rotate source addresses.
- **Exponential back-off and soft lockout.** Introduce increasing delays after N failed attempts; lock the account temporarily after a configurable threshold, then notify the owner rather than silently blocking.
- **Breached-password rejection at registration and password-change time.** Compare candidate passwords against known-compromised corpora (e.g., HIBP Pwned Passwords API) to prevent users from selecting credentials already in attacker databases.
- **Multi-factor authentication (MFA/TOTP/WebAuthn).** A valid password alone becomes insufficient; even a fully matched credential pair yields no access without the second factor.
- **Bot detection signals.** Combine IP reputation, `User-Agent` anomaly, TLS fingerprint (JA3), and behavioral biometrics (typing cadence, pointer movement) to distinguish automated clients from human browsers.
- **CAPTCHA or proof-of-work challenges.** Introduce after a threshold of failed attempts on a given account or from a given IP range, raising the per-attempt cost for automated tooling.
- **Alerting and anomaly detection.** Monitor for sudden spikes in authentication failure rates by account, ASN, or geographic cluster; alert and auto-throttle before thresholds are saturated.
- **Credential-pair deduplication.** Log failed attempts in a short-lived store and reject identical credential pairs retried within a window, collapsing replay loops without a full lockout.

In this project, see the defenses: [grobase](../defense/grobase/rate-limiting-brute-force.md), [osionos-bridge](../defense/osionos-bridge/rate-limiting-brute-force.md), [opposite-osiris](../defense/opposite-osiris/rate-limiting-brute-force.md), [auth-gateway](../defense/auth-gateway/rate-limiting-brute-force.md).

## References

- [Authentication — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html)
- [Krebs on Security — credential stuffing coverage](https://krebsonsecurity.com/tag/credential-stuffing/)
- [Have I Been Pwned — Pwned Passwords](https://haveibeenpwned.com/Passwords)
