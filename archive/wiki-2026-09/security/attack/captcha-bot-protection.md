# Credential Stuffing

> Automated injection of previously breached username-and-password pairs into login forms at scale, exploiting the widespread human habit of reusing credentials across services.

## What it is

Credential stuffing is a category of automated account-takeover attack in which an adversary acquires a corpus of credential pairs — typically sourced from prior data breaches sold or leaked on criminal marketplaces — and replays them against unrelated login endpoints using bot infrastructure. Unlike a brute-force attack, the attacker is not guessing passwords: every pair tried is a real credential that at least one person used somewhere. The attack therefore achieves meaningful success rates even against targets that enforce account lockouts, because a single credential is tried at most once or twice per account. The sheer volume of breached data available (billions of pairs across aggregations such as Collection X) means that even modest success percentages yield thousands of compromised accounts. OWASP classifies this threat as **OAT-008** in its Automated Threats to Web Applications catalogue.

## How the attack works

1. **Corpus acquisition.** The attacker obtains a credential dump — from dark-web markets, paste sites, or peer-to-peer sharing networks — containing email/username and plaintext or cracked-hash password pairs from previous breaches.
2. **Infrastructure assembly.** A botnet, residential proxy pool, or CAPTCHA-solving service is configured to distribute requests across many IP addresses and simulate human-like browser fingerprints, evading simple IP-rate and bot-signal controls.
3. **Automated replay.** A credential-stuffing tool (publicly available open-source tooling exists; it is not reproduced here) iterates over the corpus, submitting one credential pair per login request against the target site. Requests are throttled and jittered to avoid triggering velocity alarms.
4. **Validity filtering.** HTTP response codes, redirect destinations, or page-body markers distinguish successful logins from failures. The tool records all hits for later exploitation.
5. **Account monetisation.** Valid sessions are used to exfiltrate stored payment methods, personal data, or loyalty points; sold in bulk; or leveraged as a stepping stone for further access.

**Illustrative (non-functional) example — what a replay payload looks like conceptually:**

```http
POST /api/auth/login HTTP/1.1
Host: example.internal
Content-Type: application/json
X-Forwarded-For: 198.51.100.42   ← rotated via proxy pool

{
  "email": "alice@example.com",
  "password": "hunter2"          ← sourced from a prior breach, not guessed
}
```

The request is structurally identical to a legitimate login. The distinguishing signal lies in behavioural patterns (velocity, fingerprint entropy, credential-list origin) rather than the individual request.

## Real-world impact

In 2014, attackers obtained credentials from a third-party corporate athletic race-registration website and used those same username-and-password combinations to target JPMorgan Chase accounts — a documented example of cross-service credential reuse enabling access to a financial institution with no direct vulnerability in its own systems (source: [OWASP Credential Stuffing](https://owasp.org/www-community/attacks/Credential_stuffing)). At an industry level, F5 Labs documented that across four Fortune 500 customers nearly one-third of all login attempts in the observed window used credentials traceable to the "Collection X" aggregate leak, and that 1.86 billion credential records were spilled industry-wide in 2020 alone ([F5 Labs 2021 Credential Stuffing Report](https://www.f5.com/labs/articles/threat-intelligence/2021-credential-stuffing-report)). The attack class disproportionately harms users because the root cause — password reuse — exists on the user side, yet the liability and remediation burden falls on the breached service.

## OWASP classification

- **OAT-008 — Credential Stuffing**, OWASP Automated Threats to Web Applications:
  [https://owasp.org/www-project-automated-threats-to-web-applications/](https://owasp.org/www-project-automated-threats-to-web-applications/)
- **Credential Stuffing Prevention Cheat Sheet**, OWASP Cheat Sheet Series:
  [https://cheatsheetseries.owasp.org/cheatsheets/Credential_Stuffing_Prevention_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/Credential_Stuffing_Prevention_Cheat_Sheet.html)
- **OWASP Community Attack Reference:**
  [https://owasp.org/www-community/attacks/Credential_stuffing](https://owasp.org/www-community/attacks/Credential_stuffing)

The attack maps to **OWASP Top 10 2021 — A07:2021 Identification and Authentication Failures** when the target application lacks adequate bot-signal detection or credential-reuse checking.

## How defenders stop it

- **Multi-factor authentication (MFA):** the single highest-impact control; a stolen password pair is useless once a second factor is required. Microsoft research cited by OWASP suggests MFA would prevent roughly 99.9 % of automated account compromises.
- **CAPTCHA on suspicious sessions:** deploy challenge-response tests (hCaptcha, reCAPTCHA v3, Turnstile) conditionally — triggered by anomalous signals rather than every login — to raise the cost of automation without degrading UX for legitimate users.
- **Credential-breach lookup:** check submitted passwords against known-breached-password datasets (e.g., the Have I Been Pwned `k-anonymity` API) at registration and on change, rejecting pairs that appear in public dumps.
- **Device and TLS fingerprinting:** use JA3/JA4 TLS fingerprints and HTTP/2 frame-order signatures to detect non-browser clients masquerading as browsers; flag or challenge mismatches.
- **Headless-browser detection:** inject JavaScript challenges that fail under common headless runtimes (absent `window.chrome`, inconsistent `navigator` properties) to surface bot traffic before it reaches the authentication endpoint.
- **IP reputation and velocity controls:** rate-limit by IP subnet and ASN, integrate threat-intelligence feeds, and apply graduated responses (slow-down → CAPTCHA → block) rather than a hard cutoff that merely prompts proxy rotation.
- **Leaked-username suppression:** avoid confirming whether an email address exists during login error messages; return a generic "invalid credentials" response to deny attackers a validity oracle.
- **Anomaly-based alerting:** monitor aggregate failed-login ratios per time window; a sharp rise in 4xx auth responses is the earliest reliable signal of an active stuffing campaign.
- **Passkey / passwordless adoption:** eliminating shared-secret credentials entirely removes the attack surface; WebAuthn credentials are phishing- and replay-resistant by construction.

In this project, see the defenses: [opposite-osiris](../defense/opposite-osiris/captcha-bot-protection.md).

## References

- OWASP Credential Stuffing Community Attack Reference: <https://owasp.org/www-community/attacks/Credential_stuffing>
- OWASP Credential Stuffing Prevention Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/Credential_Stuffing_Prevention_Cheat_Sheet.html>
- OWASP Automated Threats to Web Applications (OAT-008): <https://owasp.org/www-project-automated-threats-to-web-applications/>
- F5 Labs 2021 Credential Stuffing Report: <https://www.f5.com/labs/articles/threat-intelligence/2021-credential-stuffing-report>
