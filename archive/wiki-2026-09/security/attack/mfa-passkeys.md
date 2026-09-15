# Credential Phishing & Password-Based Account Takeover

> Attackers obtain valid credentials through deception or theft and then authenticate as the victim — completely bypassing perimeter controls because they present a legitimate username and password.

## What it is

Credential phishing and password-based account takeover (ATO) are exploitation techniques that target the weakest link in authentication: the human-memorised password. An attacker tricks or coerces a user into disclosing their credentials — typically via a cloned login page, a vishing call, or a malicious link — and then replays those credentials against the real service. Because the attacker uses the account owner's exact secrets, server-side rate-limiting and IP controls are frequently insufficient to block the attempt. The attack class spans a spectrum from low-sophistication bulk spray campaigns (credential stuffing from leaked dumps) to highly targeted spear-phishing that impersonates internal tooling. In all variants the root cause is the same: a shared secret that can be captured in transit and reused independently of the legitimate owner.

## How the attack works

1. **Reconnaissance.** The attacker identifies a target application and harvests a list of candidate usernames — from LinkedIn, a prior breach dump, or a public directory.
2. **Lure construction.** A convincing phishing site or SMS message is crafted that mirrors the target's login flow, including valid TLS certificates (often on a look-alike domain: `app-company.com` vs `company.com`).
3. **Credential capture.** The victim enters their username and password. An adversary-in-the-middle (AiTM) proxy may relay the login to the real service in real time, forwarding any SMS OTP prompt back to the victim so the attacker can capture the one-time code before it expires.
4. **Session hijack or silent re-use.** The attacker either injects the stolen session token directly, or stores the plaintext credentials for later stuffing across other services where the victim reused the same password.
5. **Lateral escalation.** With access established, the attacker harvests OAuth tokens, elevates via IDOR or privilege-escalation bugs, and may alter recovery contact details to lock out the legitimate owner.

**Illustrative example (non-weaponized).**  
A developer receives an email appearing to come from their CI/CD provider:

```
Subject: Action required — pipeline token expiry
Click here to re-authenticate: https://ci-provider-secure.example.net/login
```

The link resolves to an AiTM proxy that presents an identical login form. The developer enters their password and an SMS OTP. The proxy relays both to the real service, obtains a valid session cookie, and stores it — while returning a fake "success" page to the developer. The legitimate session is now cloned.

## Real-world impact

Between May 2022 and September 2025, the threat group known as Scattered Spider compromised more than 120 organisations across healthcare, technology, retail, and hospitality. Their method was systematic credential phishing combined with SIM-swapping: SMS-based phishing campaigns stole single-sign-on credentials from employees at hundreds of companies in a matter of weeks, and SIM-swap attacks on mobile carriers gave the group the ability to intercept SMS OTPs and redirect MFA challenges to attacker-controlled devices. Victims included MGM Resorts, Caesars Entertainment, LastPass, and Transport for London; the group extracted at least $115 million in ransom payments. The attacks succeeded precisely because SMS-based MFA does not bind authentication to the legitimate channel — once a credential and an OTP are captured in transit, the attacker's possession of them is indistinguishable from the genuine user's.

Source: [Scattered Spider Hackers Plead Guilty on Day 1 of Trial — Krebs on Security (June 2026)](https://krebsonsecurity.com/2026/06/scattered-spider-hackers-plead-guilty-on-day-1-of-trial/)

## OWASP classification

This attack class maps to **OWASP Top 10 A07:2021 — Identification and Authentication Failures**, which covers broken, missing, or weak authentication controls including insufficient protection against credential-stuffing and session-fixation. The OWASP MFA Cheat Sheet provides the authoritative guidance on factor strength, phishing-resistant authenticator types, and banned authenticator categories (SMS/PSTN are explicitly designated as "restricted" due to SIM-swap and AiTM susceptibility).

Reference: [Multifactor Authentication — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Multifactor_Authentication_Cheat_Sheet.html)

## How defenders stop it

- **Deploy phishing-resistant MFA.** FIDO2 passkeys and hardware U2F tokens bind the credential assertion to the origin URL at the protocol level; an AiTM proxy on a look-alike domain receives a challenge that is cryptographically invalid for its domain, so the stolen prompt cannot be replayed against the real service.
- **Retire SMS/PSTN OTP for any high-value flow.** Per OWASP guidance, SMS codes are "restricted authenticators" — treat them as a soft factor at best, and replace them with TOTP or passkeys wherever the risk justifies it.
- **Enforce credential-breach screening at registration and login.** Check new and updated passwords against known-compromised datasets (e.g., the `k-Anonymity` pwned-passwords API) and reject matches before they become an attack surface.
- **Apply strict Content Security Policy and HSTS preloading** to reduce the viability of injected credential-harvesting scripts on legitimate pages.
- **Implement account-change alerting.** Any mutation of recovery email, phone, or MFA factors should trigger an out-of-band notification to the previous contact and require re-authentication.
- **Use short-lived, audience-bound session tokens** with server-side revocation; a hijacked session cookie becomes worthless when it cannot be refreshed without a fresh phishing-resistant challenge.
- **Log and alert on authenticator-downgrade attempts** — a request that omits a previously registered passkey and falls back to password-only warrants immediate scrutiny.

In this project, see the defenses: [grobase](../defense/grobase/mfa-passkeys.md), [osionos](../defense/osionos/mfa-passkeys.md).

## References

- [Multifactor Authentication — OWASP Cheat Sheet Series](https://cheatsheetseries.owasp.org/cheatsheets/Multifactor_Authentication_Cheat_Sheet.html)
- [Scattered Spider Hackers Plead Guilty on Day 1 of Trial — Krebs on Security, June 2026](https://krebsonsecurity.com/2026/06/scattered-spider-hackers-plead-guilty-on-day-1-of-trial/)
