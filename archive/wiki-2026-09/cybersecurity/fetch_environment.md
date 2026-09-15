# Fresh Clone Vault Onboarding & Secrets Sharing

This guide details the exact step-by-step process of securely sharing environment variables using Vault and OneTimeSecret. 
It covers how an Administrator generates tokens and how a Teammate uses them to bootstrap a fresh clone using `make all`.

## 1. Context: Local vs Shared Secrets
By default, track-binocle generates local, offline secrets via `make all-local`. However, for a team to share the *same* environment variables, you must use a **Shared Vault** and `make all`. 

To do this, one person (the Maintainer/Admin) generates a token file and securely sends it to another person (the Teammate) via a one-time link (OneTimeSecret).

---

## 2. Maintainer: Generating a Token

You can generate tokens with different permissions for `reader` (can only fetch secrets), `writer` (can publish secrets), or `admin`. 

Run the following command from the repository root to create a tracking token for your teammate:

```bash
# Generate a Reader Token from the Fly-hosted shared Vault (standard for remote teammates)
VAULT_TEAM_ROLE=reader make vault-fly-invite-token

# Or generate a Writer Token from the Fly-hosted shared Vault
VAULT_TEAM_ROLE=writer make vault-fly-invite-token

# Only use the local Compose Vault for same-machine testing
VAULT_TEAM_ROLE=reader make vault-invite-token
```

**Where did it go?**
This creates a new file at `.vault/track-binocle-reader.env` (or `-writer.env`).
It will look something like this:
```env
VAULT_ADDR=https://track-binocle-vault.fly.dev
VAULT_TOKEN=hvs.CAE... (long secret token)
VAULT_ENV_PREFIX=secret/data/track-binocle/env
```
For remote teammates, the Fly-issued file must use `VAULT_ADDR=https://track-binocle-vault.fly.dev`. A `localhost` token only works against the Vault instance on the maintainer's own machine and is rejected by shared fetches unless `VAULT_ALLOW_LOCAL_SHARED=true` is set for same-machine testing.

---

## 3. Maintainer: Sending the Token via OneTimeSecret

Since we cannot put this `.env` token file in GitHub (or it compromises the Vault), we use **OneTimeSecret**.

1. Print the contents of the file you just created:
   ```bash
   cat .vault/track-binocle-reader.env
   ```
2. Copy the entire output (all 3 lines).
3. Go to [OneTimeSecret.com](https://onetimesecret.com).
4. Paste the 3 lines into the "Secret content" box.
5. Set a passphrase if desired, and click **Create a secret link**.
6. Copy the resulting URL (e.g., `https://eu.onetimesecret.com/secret/a74oof...`).
7. Send this URL to your Teammate over Slack, Discord, or Email.

---

## 4. Teammate: Receiving and Installing the Token

Once the Teammate opens the OneTimeSecret URL, they will see the 3 lines of Vault credentials. The link will immediately self-destruct.

### Step 4a: Create the Vault Directory
The Teammate must navigate to the root of their freshly cloned `track-binocle` repository:
```bash
cd /path/to/your/track-binocle
mkdir -p .vault
```

### Step 4b: Create the Token File
The Teammate creates the `.vault/track-binocle-reader.env` file and restricts its permissions (mandatory for security):
```bash
touch .vault/track-binocle-reader.env
chmod 600 .vault/track-binocle-reader.env
```

Before the long pipeline, verify the token wiring without printing secret values:

```bash
make vault-shared-doctor
```

### Step 4c: Paste the Contents
The Teammate opens the file in an editor (like VS Code or nano) and pastes the exactly 3 lines securely copied from the OneTimeSecret website:
```bash
nano .vault/track-binocle-reader.env
# Paste the content, then save and exit.
```

---

## 5. Teammate: Running `make all`

Now the repository is armed with Vault credentials.

Run:
```bash
make all
```

**What `make all` does at this point:**
1. It looks for `.vault/track-binocle-reader.env`.
2. It detects the `VAULT_TOKEN` and connects to the shared Vault.
3. It fetches all the shared environment variables.
4. It creates all the `.env.local` or `.env` files automatically in the correct `apps/*` subfolders.
5. It proceeds to build the Docker images and start the pipeline.

If the shared Vault is unreachable, the token has expired, or the file points at the wrong host, `make all` now continues with generated local development secrets. Use `VAULT_SHARED_REQUIRED=true make all` when a shared Vault failure should stop the run.

---

## 6. GitHub Actions (For CI/CD)

The GitHub Actions pipeline (`colleague-docker-pipeline.yml`) skips the `.env` file generation. Instead, it uses **GitHub OIDC** (OpenID Connect) to dynamically ask the Vault for a 1-hour token! 

There is no need to create a OneTimeSecret for GitHub. Just set these repository variables:
- `TRACK_BINOCLE_VAULT_ADDR=https://track-binocle-vault.fly.dev`
- `TRACK_BINOCLE_VAULT_AUTH_PATH=jwt`
- `TRACK_BINOCLE_VAULT_ROLE=track-binocle-github-actions`
- `TRACK_BINOCLE_VAULT_ENV_PREFIX=secret/data/track-binocle/env`
