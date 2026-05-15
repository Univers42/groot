# Track Binocle Vault Security Model

This document explains the security architecture of the Track Binocle centralized environment fetching system. It is written for pedagogical purposes to help you understand how HashiCorp Vault protects our secrets and how to safely reproduce the setup on remote machines.

## 1. The `.env` File Myth

It is a common misconception that simply having a file named `.vault/track-binocle-reader.env` grants access to the project's secrets. 

**This is entirely false.** The file name itself has no security clearance. 

If an attacker simply creates an empty `.vault/track-binocle-reader.env` file, or fills it with random characters, the remote Vault server will instantly reject their connection.

### How it actually works
Inside the file, there are specific directives for the Vault client, most importantly a cryptographically generated **Vault Token** that looks like this:
```env
VAULT_ADDR=https://track-binocle-vault.fly.dev
VAULT_TOKEN=hvs.CAES...[random_secure_string]
VAULT_ENV_PREFIX=secret/data/track-binocle/env
```
When you run `make all` or `make vault-fetch-shared`, the Makefile reads this file and sends the `VAULT_TOKEN` to the Vault server hosted on Fly.io. The server mathematically verifies the token's signature, checks if it is expired, and checks its permissions (Policies) before returning any secrets.

## 2. Temporary Tokens & Time-To-Live (TTL)

Instead of having a single static password that everyone shares forever, Vault allows us to mint **ephemeral (temporary) tokens**. 

For example, if you need to work on a secure school computer or a temporary workstation without risking permanent exposure, you shouldn't use your central maintainer root token. You should generate a single-use token that automatically self-destructs.

### The "School Machine" Scenario
To safely work on a temporary computer, mint a new reader token from your trusted host machine with a 24-hour expiration (TTL):

```bash
make vault-fly-invite-token VAULT_TEAM_ROLE=reader VAULT_TOKEN_TTL=24h
```

**What this does:**
1. Connects to the Fly Vault as an administrator.
2. Generates a brand-new token attached to the `reader` policy.
3. Sets a strictly enforced limit of 24 hours.
4. Writes the new token into your local `.vault/track-binocle-reader.env`.

### 3. Reproducing the Setup on the Temporary Machine

Once you have generated the temporary token on your trusted machine, safely transfer the *contents* of the file (using a Password Manager, an encrypted channel, or a secure USB).

On the temporary school computer:
1. Clone the project repository.
2. Create the file and paste your temporary credentials:
   ```bash
   nano .vault/track-binocle-reader.env
   ```
3. **Secure the file (Mandatory):**
   ```bash
   chmod 600 .vault/track-binocle-reader.env
   ```
   *Why `chmod 600`?* The Track Binocle Makefile aggressively checks the file permissions. If the file is readable by other users on that school computer (`group-readable` or `world-readable`), the pipeline will refuse to execute to protect you from local snooping. `chmod 600` restricts reading and writing strictly to your current user profile.

4. Run the project:
   ```bash
   make all
   ```

When the 24 hours expire, the `VAULT_TOKEN` you pasted will "evaporate" on the Vault server side. Even if you forget to delete `.vault/track-binocle-reader.env` from the school computer, anyone who finds it will be dealing with a dead credential.

## 4. GitHub Actions and OIDC (Zero-Token Security)

For our CI/CD pipelines (like `.github/workflows/colleague-docker-pipeline.yml`), we achieve an even higher level of security: **Zero static tokens**.

Instead of putting a token in GitHub Secrets, the CI pipeline uses OpenID Connect (OIDC). GitHub cryptographically proves the identity of the GitHub workflow to our Vault server, and Vault temporarily generates a memory-only token exclusively for that specific workflow run. This eliminates the risk of leaked pipeline credentials.
