# Credential Theft via Secrets Exposure

> An attacker gains access to application or infrastructure secrets — API keys, database credentials, private keys, or session tokens — by exploiting weaknesses in how those secrets are stored, transmitted, or managed, then uses them to impersonate services or users.

## What it is

Secrets exposure is a broad attack class that targets any long-lived credential that grants privileged access to a system. Unlike password-based attacks that target human authentication flows, this class targets the machine-to-machine trust anchors that applications rely on: environment variable files committed to source control, credentials baked into container images, tokens logged to stdout during debugging, or vault-adjacent keys left in world-readable locations. The attacker's goal is to obtain a credential that was never meant to leave a controlled boundary — then quietly reuse it, often for weeks or months before detection. Because applications tend to rotate secrets infrequently, even a single disclosure event can yield persistent access long after the original breach vector is patched. OWASP classifies the underlying storage and rotation failures as a leading cause of data breaches across organizations of all sizes.

## How the attack works

1. **Reconnaissance.** The attacker identifies the target application's likely secret footprint: what cloud provider it uses, what SaaS APIs it integrates with, whether it publishes public repositories. Public git history, Docker Hub image layers, and job-artifact archives are common starting points.
2. **Discovery.** Using automated scanners (pattern-matching on strings like `AKIA`, `sk_live_`, `-----BEGIN RSA PRIVATE KEY-----`, or `DATABASE_URL=postgres://`), the attacker combs through source code history, CI logs, error-page stack traces, or exposed `.env` files on misconfigured static servers.
3. **Extraction.** The credential is pulled — often from a git commit that was later deleted but whose hash is still reachable, or from a leaked `.env` backup file that bypassed `.gitignore`.
4. **Validation and exploitation.** The attacker makes a low-noise probe (e.g., a read-only API call) to confirm the credential is still live, then escalates: enumerating cloud storage buckets, reading database contents, calling privileged API endpoints, or issuing tokens to create backdoor accounts.
5. **Persistence.** New secrets or IAM roles are created under the attacker's control before the original credential is discovered and rotated.

**Illustrative example (non-weaponized):** A developer pushes a branch that includes a debug `.env` file containing `DB_PASSWORD=hunter2` and `STRIPE_SECRET_KEY=sk_live_XXXX`. The branch is short-lived but the commit is indexed by a public repository scanner within minutes. Even after the branch is deleted and the file is removed, the commit object remains reachable via direct hash. The application's Stripe account and production database are now reachable to anyone who ran the scanner.

```text
# .env committed by mistake — never do this
DB_HOST=prod-db.internal
DB_USER=app
DB_PASSWORD=hunter2
STRIPE_SECRET_KEY=sk_live_XXXX
```

The fix is to keep every secret out of the filesystem entirely and inject them exclusively through a secrets manager at runtime.

## Real-world impact

In August–December 2022, LastPass suffered a two-stage breach in which attackers first exfiltrated source code and internal tooling, then used knowledge gained from that to access a third-party cloud storage environment holding encrypted customer password vaults. The stolen vaults contained both encrypted fields and a significant amount of plaintext metadata. Because many accounts had been created when LastPass enforced only 500 PBKDF2 iterations — far below the 310,000 NIST recommended at the time — attackers with access to capable hardware could feasibly brute-force the master passwords of older accounts offline. From December 2022 onward, researchers tracking on-chain movements linked at least 150 victims to roughly $35 million in cryptocurrency losses, with individual victims losing as much as $3.4 million. The breach class is not exotic: secrets (seed phrases, private keys) were stored in a vault whose encryption parameters were never migrated to modern standards, and the third-party cloud credential granting access to that storage was itself insufficiently isolated. Source: Brian Krebs, *"Experts Fear Crooks Are Cracking Keys Stolen in LastPass Breach"*, September 2023 — [krebsonsecurity.com](https://krebsonsecurity.com/2023/09/experts-fear-crooks-are-cracking-keys-stolen-in-lastpass-breach/).

## OWASP classification

This attack class is addressed directly by the **OWASP Secrets Management Cheat Sheet**, which covers the full lifecycle of secrets — generation, storage, rotation, access control, and audit. The cheat sheet maps to **OWASP Top 10 A02:2021 – Cryptographic Failures** (previously "Sensitive Data Exposure") and **A05:2021 – Security Misconfiguration**, both of which frequently manifest as credentials in the wrong place.

Reference: [Secrets Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html)

## How defenders stop it

- **Never commit secrets to version control.** Use `.gitignore` enforced by pre-commit hooks and scanning tools (e.g., `trufflehog`, `gitleaks`) in CI to reject any push that matches known secret patterns.
- **Use a dedicated secrets manager.** Inject secrets at runtime from a vault (e.g., HashiCorp Vault, AWS Secrets Manager, or a self-hosted equivalent) rather than baking them into images, environment files, or configuration artifacts.
- **Apply least-privilege scoping.** Each service should receive only the credentials it needs, bound to the minimum permission set — a database read replica credential for a read-only service, a scoped API token rather than a root key.
- **Rotate secrets on a fixed schedule and immediately after any suspected exposure.** Short-lived, time-bounded tokens (OAuth access tokens, STS credentials, OIDC JWT) shrink the damage window to minutes rather than months.
- **Audit secret access continuously.** Every secret read or write should emit a log entry to an append-only audit trail. Anomalous read patterns (unexpected geography, service, or volume) should trigger alerts.
- **Upgrade encryption parameters for stored secrets.** PBKDF2 iterations, Argon2 parameters, and key lengths should be migrated to current NIST recommendations as part of routine maintenance — not left at values set a decade ago.
- **Scan container image layers and CI artifacts.** Build pipelines should run secret-detection passes over Docker layers and any uploaded artifacts before they reach a registry.
- **Separate secrets from configuration.** Environment variables set by an orchestrator at container start time are acceptable; static `.env` files on disk, configuration files in the image layer, or values in `docker-compose.yml` checked into the repo are not.

In this project, see the defenses: [grobase](../defense/grobase/secrets-management.md), [osionos](../defense/osionos/secrets-management.md), [osionos-bridge](../defense/osionos-bridge/secrets-management.md), [auth-gateway](../defense/auth-gateway/secrets-management.md), [mail-calendar](../defense/mail-calendar/secrets-management.md), [platform](../defense/platform/secrets-management.md).

## References

- OWASP – Secrets Management Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html>
- Brian Krebs – "Experts Fear Crooks Are Cracking Keys Stolen in LastPass Breach" (September 2023): <https://krebsonsecurity.com/2023/09/experts-fear-crooks-are-cracking-keys-stolen-in-lastpass-breach/>
