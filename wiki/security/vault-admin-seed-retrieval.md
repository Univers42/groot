# Vault Admin Seed Retrieval — Complete Guide

This guide documents the exact credential types, file locations, and command sequence required to retrieve the admin seed from the Fly-hosted Vault and make `make all` work from any machine. It records what was diagnosed and fixed on 2026-05-20.

---

## Context: What "Admin Seed Retrieval" Means

The shared team secrets (all `.env.local` and managed env files) live in a HashiCorp Vault instance hosted on Fly.io at:

```
https://track-binocle-vault.fly.dev
```

On first setup, the Vault was seeded with all project environment values. That seed lives under the KV prefix:

```
secret/data/track-binocle/env
```

To fetch those secrets on any machine, `make all` needs a valid **reader token** pointing to the Fly.io URL. If that token is missing, expired, or pointing to `localhost`, the pipeline refuses to start.

The admin seed retrieval process is: prove you own the Fly app → derive a Vault admin token → mint a portable reader token → `make all` fetches the secrets and proceeds.

---

## Credential Map

There are three distinct credential types in this system. You must understand which one you hold before you know what you can do.

```
Fly.io Personal Access Token (FLY_API_TOKEN)
    └── proves Fly app operator access
    └── grants: SSH into the Fly VM, read /vault/data/.vault-keys.json
    └── where to get: https://fly.io/user/personal_access_tokens

Vault Root Token (hvs.xxx stored in /vault/data/.vault-keys.json on the Fly VM)
    └── proves Vault owner identity
    └── grants: everything — policies, mounts, token creation, secrets
    └── where it lives: inside the Fly VM, never locally
    └── NEVER paste into chat, commits, logs, or environment variables on disk

Vault Reader/Writer Invite Token (.vault/track-binocle-reader.env or writer.env)
    └── proves team membership
    └── reader grants: read managed env values, list metadata
    └── writer grants: read + write managed env values
    └── where to get: minted from an admin session (see below)
    └── share only through a one-time secret link or encrypted channel
```

For the admin seed retrieval flow, **you need the Fly.io Personal Access Token**. The Vault root token is derived from it automatically — you never handle it directly.

---

## What You Need Before Starting

### 1. Fly.io Personal Access Token

Go to [fly.io/user/personal_access_tokens](https://fly.io/user/personal_access_tokens) and create a token. Choose **Personal Access Token** (not a Deploy Token — it needs SSH console access to the Vault VM).

The token looks like:

```
FlyV1 fm2_lJPECAAAAAAAEVV...
```

This token proves to Fly.io that you are authorised to operate the `track-binocle-vault` app. It does not expire unless you revoke it.

### 2. Docker (no flyctl needed)

`flyctl` does not need to be installed locally. The Makefile automatically falls back to running `flyio/flyctl:latest` in Docker when `FLY_API_TOKEN` is set and no local `fly`/`flyctl` binary exists:

```
FLY := docker compose --profile secrets run --rm --no-deps -e FLY_API_TOKEN vault-fly
```

Docker must be running. Verify with `docker info`.

### 3. The project cloned and submodules initialised

```sh
git clone git@github.com:Univers42/ft_transcendence.git --recursive
cd ft_transcendence
```

---

## Step 1 — Store `FLY_API_TOKEN`

The `vault-session.mjs` script reads `FLY_API_TOKEN` from the shell environment **or** from ignored local env files. The recommended approach is to store it in `.env.local` so every `make` session picks it up without manual exports.

`.env.local` is gitignored by `.gitignore` (`.env.*` pattern). Create it with strict permissions:

```sh
printf 'FLY_API_TOKEN=FlyV1 fm2_<your-token-here>\n' >> .env.local
chmod 600 .env.local
```

Verify it was written:

```sh
grep -c FLY_API_TOKEN .env.local    # should print 1
stat -c '%a %n' .env.local          # should print 600 .env.local
```

Alternatively, for a one-off run without writing to disk:

```sh
export FLY_API_TOKEN="FlyV1 fm2_<your-token>"
```

---

## Step 2 — Open an Admin Session via Fly SSH

```sh
make vault-login-fly-admin
```

**What this does internally:**

1. `vault-session.mjs` reads `FLY_API_TOKEN` from `.env.local` or the shell.
2. Because `flyctl` is not installed, it uses Docker: `docker compose --profile secrets run --rm --no-deps -e FLY_API_TOKEN vault-fly ssh console --app track-binocle-vault --command 'jq -r .root_token /vault/data/.vault-keys.json'`
3. Fly authenticates using `FLY_API_TOKEN` and opens an SSH console into the `track-binocle-vault` app on Fly.io.
4. Inside the Fly VM, it reads `/vault/data/.vault-keys.json` and extracts the `root_token` field.
5. The root token is used to call `POST https://track-binocle-vault.fly.dev/v1/auth/token/create` with the `admin` policy and a 2-hour TTL.
6. The root token is discarded from memory. Only the short-lived admin child token is kept.
7. The admin child token is written to two files:

```text
.vault/track-binocle-admin.env     (mode 600)
.vault/track-binocle-session.env   (mode 600)
~/.vault-token                     (Vault CLI default, mode 600)
```

The content of `.vault/track-binocle-admin.env` looks like:

```sh
VAULT_TOKEN=hvs.<admin-child-token>
VAULT_SESSION_SOURCE=fly-admin
VAULT_AUTH_METHOD=fly-admin
VAULT_ADMIN_TOKEN_TTL=2h
```

**Verify the session:**

```sh
make vault-session-status
```

Expected output:

```
[vault-session] vault address: https://track-binocle-vault.fly.dev
[vault-session] token source: admin-token-file
[vault-session] policies: admin, default
[vault-session] ttl: 7199
[vault-session] renewable: false
```

---

## Step 3 — Mint a Portable Reader Token

```sh
make vault-session-reader-token
```

**What this does internally:**

1. Reads the admin token from `.vault/track-binocle-admin.env`.
2. Syncs the two team ACL policies to the Fly Vault (`track-binocle-env-reader`, `track-binocle-env-writer`) from the HCL files at `apps/baas/mini-baas-infra/docker/services/vault/policies/`.
3. Calls `POST https://track-binocle-vault.fly.dev/v1/auth/token/create` with:
   - policy: `track-binocle-env-reader`
   - TTL: `24h`
   - orphan: `true` (so revoking the admin session does not revoke this token)
4. Writes `.vault/track-binocle-reader.env` with mode `600`:

```sh
# Track Binocle Vault invite token. Keep this file private.
VAULT_ADDR=https://track-binocle-vault.fly.dev
VAULT_TOKEN=hvs.<new-reader-token>
VAULT_ENV_PREFIX=secret/data/track-binocle/env
```

The key difference from a local token is `VAULT_ADDR=https://track-binocle-vault.fly.dev` (not `localhost`). The `make all` shared-fetch check specifically refuses localhost addresses.

**Verify the token file:**

```sh
make vault-shared-doctor
```

Expected output:

```
[vault] token source: file:.vault/track-binocle-reader.env
[vault] vault address: https://track-binocle-vault.fly.dev
[vault] env prefix: secret/data/track-binocle/env
[vault] shared Vault token wiring looks usable
```

---

## Step 4 — Run the Pipeline

```sh
make all
```

`make all` starts with `env-fetch-shared`, which reads `.vault/track-binocle-reader.env` and fetches all managed env files from the Fly Vault. If the token wiring is correct, you will see:

```
[vault] shared env fetch complete
[vault] fetched root
[vault] fetched opposite-osiris
[vault] fetched osionos-app
[vault] fetched mail
[vault] fetched calendar
[vault] fetched baas
[vault] fetched mini-baas-infra
```

The pipeline then continues through cert trust, Docker image prefetch, vault seed, and full service startup.

---

## Complete Quick Reference

Run these four commands in order on a fresh machine or after a "refusing localhost Vault address" failure:

```sh
# 1. Store your Fly token (gitignored)
printf 'FLY_API_TOKEN=FlyV1 fm2_<your-token>\n' >> .env.local && chmod 600 .env.local

# 2. Open a 2h admin session via Fly SSH
make vault-login-fly-admin

# 3. Mint a 24h reader token pointing to the Fly Vault
make vault-session-reader-token

# 4. Verify token wiring
make vault-shared-doctor

# 5. Run the full pipeline
make all
```

---

## What Each File Does

| File | Content | Purpose | Gitignored |
|------|---------|---------|-----------|
| `.env.local` | `FLY_API_TOKEN=...` | Fly authentication for admin session | yes |
| `.vault/track-binocle-admin.env` | Vault admin child token, 2h TTL | Active admin session for minting invites | yes |
| `.vault/track-binocle-session.env` | Same admin token, also written here | Active session read by all vault-session targets | yes |
| `.vault/track-binocle-reader.env` | Reader invite token, 24h TTL | Used by `make all` → `env-fetch-shared` to fetch secrets | yes |
| `.vault/track-binocle-writer.env` | Writer invite token, 8h TTL | Used by `vault-publish-shared` to update secrets | yes |
| `~/.vault-token` | Same as session token | Vault CLI interop | no (home dir) |

---

## The "Localhost Token" Failure Mode

The most common failure is having a reader token that points to `localhost`:

```sh
# .vault/track-binocle-reader.env (BAD — generated from local Docker Vault)
VAULT_ADDR=https://localhost:18200
VAULT_TOKEN=hvs.CAESL...
VAULT_ENV_PREFIX=secret/data/track-binocle/env
```

This token was created by `make vault-invite-token` (local Vault target) instead of `make vault-session-reader-token` or `make vault-reader-token` (Fly-backed targets). The `env-fetch-shared` target explicitly refuses it:

```
[vault] refusing localhost Vault address for shared env fetch.
[vault] This token only works with the Vault instance on the machine that issued it.
```

**Diagnosis:**

```sh
grep VAULT_ADDR .vault/track-binocle-reader.env
# bad:  VAULT_ADDR=https://localhost:18200
# good: VAULT_ADDR=https://track-binocle-vault.fly.dev
```

**Fix:** repeat steps 2–4 above.

---

## Admin Session Token Lifecycle

```
make vault-login-fly-admin
  │
  ├── reads FLY_API_TOKEN from .env.local or shell
  ├── Docker flyctl → fly ssh console → reads /vault/data/.vault-keys.json
  ├── Vault root token used to create admin child token (2h)
  └── writes .vault/track-binocle-admin.env, .vault/track-binocle-session.env

make vault-session-reader-token
  │
  ├── reads admin token from .vault/track-binocle-admin.env
  ├── syncs ACL policies from apps/baas/mini-baas-infra/docker/services/vault/policies/
  ├── creates orphan reader token (24h) via Vault API
  └── writes .vault/track-binocle-reader.env (VAULT_ADDR = Fly URL)

make all
  │
  ├── env-fetch-shared reads .vault/track-binocle-reader.env
  ├── fetches 7 managed env files from secret/data/track-binocle/env/*
  └── continues with full pipeline (certs, docker, vault-seed, services)

make vault-logout
  │
  ├── revokes active session token on Fly Vault
  └── removes .vault/track-binocle-session.env, ~/.vault-token
      (and .vault/track-binocle-admin.env if it held the same token)
```

The reader token file is an **orphan token** — it keeps working after the admin session that minted it is revoked or expires. The reader token has its own 24-hour TTL from the moment it was created.

---

## When the Admin Session Expires (2h)

The reader token is valid for 24h independently. You only need to re-run `vault-login-fly-admin` if you need to:

- Mint new reader/writer tokens.
- Publish updated secrets (`make vault-publish-shared`).
- Run admin operations (`vault-session-status`, `vault-kv-export`).

For daily `make all` runs where the reader token is still valid, you do not need a Fly admin session at all.

---

## Generating Additional Tokens

**Writer token** (for publishing updated env values):

```sh
make vault-session-writer-token
# writes .vault/track-binocle-writer.env  (8h TTL, orphan)
```

**Time-limited reader for a school machine** (24h):

```sh
make vault-fly-invite-token VAULT_TEAM_ROLE=reader VAULT_TOKEN_TTL=24h
```

Share the resulting `.vault/track-binocle-reader.env` through a one-time secret link. The teammate places it at `.vault/track-binocle-reader.env`, runs `chmod 600`, and verifies with `make vault-shared-doctor`.

---

## Security Boundaries

| Actor | Can do | Cannot do |
|-------|--------|-----------|
| Fly account owner | SSH into Fly VM, read root token, full Vault access | — |
| Vault admin session (2h child token) | Mint tokens, sync policies, read/write all secrets | Destroy Vault, modify Fly config |
| Writer invite token | Read + write managed env values | Create tokens, change policies |
| Reader invite token | Read managed env values, list metadata | Anything write-related or administrative |
| No token | Health check (`/v1/sys/health`) | Anything else |

A reader token holder cannot escalate to writer or admin. A writer token holder cannot mint new tokens. Only Fly operator access can produce a new admin session.

---

## Troubleshooting

### `flyctl not found locally and FLY_API_TOKEN is not set`

`FLY_API_TOKEN` is neither in the shell nor in `.env.local`/`.env`. Add it and retry.

### `Fly admin login could not read a Vault root token from the Fly volume`

The `jq -r .root_token /vault/data/.vault-keys.json` command inside the Fly VM returned nothing. Possible causes:
- The Fly app `track-binocle-vault` is sleeping or not deployed. Check with: `FLY_API_TOKEN=<token> docker compose --profile secrets run --rm --no-deps -e FLY_API_TOKEN vault-fly apps list`
- The `.vault-keys.json` file is missing (Vault was never seeded). Run `make vault-fly-deploy` to redeploy, then check if the file exists.

### `permission denied` when reading Vault health

The Fly Vault is unsealed and running (health returns HTTP 200) but the admin API requires a token. This is normal — proceed with `make vault-login-fly-admin`.

### Reader token rejected with HTTP 403 after fetching

The token exists and points to the Fly URL but Vault rejects it:
- Token may have expired (24h TTL). Regenerate with `make vault-session-reader-token` after re-running `make vault-login-fly-admin`.
- Token may have been revoked. Same fix.
- Token may have been generated from a different Vault instance. Check `grep VAULT_ADDR .vault/track-binocle-reader.env` — it must match `https://track-binocle-vault.fly.dev`.

### `[vault] shared Vault token wiring looks usable` but `make all` still fails on fetch

Run `make vault-fetch-shared` alone to see the full error from `vault-env.mjs`. It will print HTTP status codes and the specific secret path that failed.

---

## Related Documents

- [vault-security-model.md](../vault-security-model.md) — why tokens are temporary and what each policy allows
- [vault-session-management.md](vault-session-management.md) — full reference for all session targets
- [vault-fly-admin-setup.md](vault-fly-admin-setup.md) — concise fix guide for the "refusing localhost" error
- [vault-owner-recovery-and-invite.md](vault-owner-recovery-and-invite.md) — what to do when admin credentials are lost entirely
- [vault-publish-from-home.md](vault-publish-from-home.md) — how to push updated secrets to the Fly Vault
- [colleague-make-all-onboarding.md](../colleague-make-all-onboarding.md) — teammate onboarding with a pre-minted reader token
