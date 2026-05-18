# Publishing env secrets to Vault from a home machine (admin)

This guide covers how to push all managed `.env` / `.env.local` files to the
Fly-hosted Vault when you are working from a machine that is **not** a 42 school
computer — for example your personal laptop or home desktop.

The shared Vault instance lives at:

```
https://track-binocle-vault.fly.dev
```

All secrets are stored under the KV prefix `secret/data/track-binocle/env`.

---

## Managed env files

The following files are controlled by `vault-env.mjs` and will be published /
fetched as a unit:

| ID | Local path |
|----|-----------|
| `root` | `.env.local` |
| `opposite-osiris` | `apps/opposite-osiris/.env.local` |
| `osionos-app` | `apps/osionos/app/.env` |
| `mail` | `apps/mail/.env.local` |
| `calendar` | `apps/calendar/.env.local` |
| `baas` | `apps/baas/.env.local` |
| `mini-baas-infra` | `apps/baas/mini-baas-infra/.env` |

---

## Option A — you already have a writer token file

If someone generated a writer token for you (via `make vault-writer-token` on the
school machine) and sent you the file `.vault/track-binocle-writer.env`:

```sh
# 1. Clone the repo
git clone git@github.com:Univers42/ft_transcendence.git
cd ft_transcendence
git submodule update --init --recursive

# 2. Install the token file with strict permissions
mkdir -p .vault
cp /path/to/track-binocle-writer.env .vault/track-binocle-writer.env
chmod 600 .vault/track-binocle-writer.env

# 3. Edit your local .env files with real secret values, then:
make vault-publish-shared
```

`vault-publish-shared` automatically loads `.vault/track-binocle-writer.env`,
sets `VAULT_ADDR` and `VAULT_TOKEN`, then calls `vault-env.mjs publish` for
every managed file without printing values to the terminal.

---

## Option B — you are the owner (admin via Fly)

Use this when you have owner access to the Fly organisation and need to publish
fresh secrets (e.g. after a credential rotation or on a brand-new machine).

### Prerequisites

```sh
# macOS / Linux
curl -L https://fly.io/install.sh | sh
# or via Homebrew
brew install flyctl

# Authenticate
fly auth login          # opens browser
```

### Step 1 — obtain the Vault root token via Fly SSH

```sh
fly ssh console --app track-binocle-vault \
  --command 'jq -r .root_token /vault/data/.vault-keys.json'
```

Copy the token printed to your terminal (it starts with `hvs.`).

> **Never commit or log this token.** It grants unrestricted Vault access.

### Step 2 — publish your local env files

```sh
VAULT_API_KEY=<root-token-from-step-1> \
VAULT_ADDR=https://track-binocle-vault.fly.dev \
  make vault-publish-shared
```

Expected output — one line per managed file, no values printed:

```
[vault] published root
[vault] published opposite-osiris
[vault] published osionos-app
[vault] published mail
[vault] published calendar
[vault] published baas
[vault] published mini-baas-infra
```

### Step 3 — mint fresh reader / writer tokens for teammates

After publishing you should regenerate limited-scope tokens so teammates do not
need the root token:

```sh
# Reader token (24 h, read-only)
VAULT_API_KEY=<root-token> VAULT_ADDR=https://track-binocle-vault.fly.dev \
  make vault-reader-token

# Writer token (8 h, read + write env records)
VAULT_API_KEY=<root-token> VAULT_ADDR=https://track-binocle-vault.fly.dev \
  make vault-writer-token
```

Both commands write the token files under `.vault/` with mode `600` and print
the Vault address embedded inside the file — safe to share with teammates over
a private channel (never in git).

### Step 4 — verify

```sh
VAULT_API_KEY=<root-token> VAULT_ADDR=https://track-binocle-vault.fly.dev \
  make vault-status-shared
```

---

## Option C — full recovery (admin creds lost or tokens expired)

If both the writer token and the Fly root token are gone, the single-command
recovery path is:

```sh
# Requires flyctl authenticated as the Fly org owner
make admin-cred-lost
```

This will:
1. SSH into the Fly app to retrieve the Vault root token
2. Re-publish all managed env files from your local `.env` files
3. Mint fresh reader **and** writer token files under `.vault/`
4. Run `vault-status-shared` to confirm coverage

After `admin-cred-lost` completes, share the new token files with teammates.

---

## Fetching secrets on a fresh machine (teammate / home)

If you only need to **pull** secrets (not publish):

```sh
# Install your reader token (sent by the maintainer)
mkdir -p .vault
cp /path/to/track-binocle-reader.env .vault/track-binocle-reader.env
chmod 600 .vault/track-binocle-reader.env

make vault-fetch-shared
# or simply:
make all    # vault-fetch-shared is called automatically when the token file exists
```

---

## Quick reference

| Action | Command |
|--------|---------|
| Publish from school machine (writer token) | `make vault-publish-shared` |
| Publish from home (Fly admin token) | `VAULT_API_KEY=<token> VAULT_ADDR=https://track-binocle-vault.fly.dev make vault-publish-shared` |
| Check coverage without printing values | `make vault-status-shared` |
| Mint reader token (admin only) | `make vault-reader-token` |
| Mint writer token (admin only) | `make vault-writer-token` |
| Full recovery (lost admin creds) | `make admin-cred-lost` |
| Fetch secrets as teammate | `make vault-fetch-shared` |
