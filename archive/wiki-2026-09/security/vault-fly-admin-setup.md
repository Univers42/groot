# Vault Admin Fly.io Credential Setup

This document explains the "refusing localhost Vault address" error that occurs during `make all` and the complete workflow to fix it as a project maintainer.

---

## The Error

```text
[vault] refusing localhost Vault address for shared env fetch.
[vault] This token only works with the Vault instance on the machine that issued it.
[vault]   maintainer: make vault-fly-invite-token VAULT_TEAM_ROLE=reader
[vault]   teammate:   install .vault/track-binocle-reader.env, chmod 600 it, then make vault-shared-doctor
```

**What it means:** `.vault/track-binocle-reader.env` was generated from the local Docker Vault (`https://localhost:18200`) instead of the shared Fly.io Vault (`https://track-binocle-vault.fly.dev`). This happens when you previously ran `make vault-invite-token` (local) instead of `make vault-fly-invite-token` or `make vault-reader-token` (Fly-backed).

A localhost token is machine-specific — it only works where the local Docker Vault container is running, and it cannot be used to authenticate against the remote Fly.io instance.

---

## Why This Happens

The project has two Vault instances:

| Instance | Address | Purpose |
|---|---|---|
| Local Docker | `https://localhost:18200` | Local dev, AppRole seeding, service secrets |
| Fly.io (shared) | `https://track-binocle-vault.fly.dev` | Team shared env values |

`make all` → `env-fetch-shared` → `vault-fetch-shared` reads `.vault/track-binocle-reader.env` and rejects any token whose `VAULT_ADDR` is a localhost address. This prevents accidental use of non-portable tokens on fresh machines.

---

## Fix: Regenerate the Reader Token from Fly.io

You need your **Fly.io Personal Access Token**. Create one at [fly.io/user/personal_access_tokens](https://fly.io/user/personal_access_tokens).

### Step 1 — Store your Fly.io token (gitignored)

Put `FLY_API_TOKEN` in `.env.local` at the repo root. This file is gitignored and parsed automatically by the session scripts:

```bash
printf 'FLY_API_TOKEN=<your-fly-token>\n' >> .env.local
chmod 600 .env.local
```

Alternatively, you can export it in your shell for a one-off run:

```bash
export FLY_API_TOKEN=<your-fly-token>
```

### Step 2 — Open an admin session from the Fly Vault

This SSHes into the Fly app, reads the Vault root token from `/vault/data/.vault-keys.json`, and mints a short-lived admin child token (2h TTL by default):

```bash
make vault-login-fly-admin
```

What happens under the hood:
1. `vault-session.mjs` reads `FLY_API_TOKEN` from `.env.local` or the shell.
2. Because `flyctl` is not installed locally, it falls back to `docker compose run vault-fly` (uses `flyio/flyctl:latest` image).
3. Fly SSH is used to read `/vault/data/.vault-keys.json` on the Fly VM.
4. The root token is used to create a child token with the `admin` policy.
5. The child token is written to `.vault/track-binocle-admin.env` and `.vault/track-binocle-session.env`.

### Step 3 — Mint a reader token pointing to Fly.io

```bash
make vault-session-reader-token
```

This reads the admin session from `.vault/track-binocle-admin.env`, calls the Fly.io Vault API to create a new token with the `track-binocle-env-reader` policy (24h TTL), and writes `.vault/track-binocle-reader.env` with:

```text
VAULT_ADDR=https://track-binocle-vault.fly.dev
VAULT_TOKEN=hvs.<new-portable-token>
VAULT_ENV_PREFIX=secret/data/track-binocle/env
```

### Step 4 — Verify

```bash
make vault-shared-doctor
```

Expected output:

```text
[vault] token source: file:.vault/track-binocle-reader.env
[vault] vault address: https://track-binocle-vault.fly.dev
[vault] env prefix: secret/data/track-binocle/env
[vault] shared Vault token wiring looks usable
```

### Step 5 — Run the pipeline

```bash
make all
```

---

## Alternative: One-liner Without a Persistent Session

If you just need to fix the reader token once and do not want to store the admin session:

```bash
FLY_API_TOKEN=<your-fly-token> make vault-reader-token
```

`make vault-reader-token` calls `make vault-fly-invite-token VAULT_TEAM_ROLE=reader`, which:
1. SSHes into the Fly app via Docker-based flyctl.
2. Reads the root token directly.
3. Calls the Vault API as root to create a reader token (syncing policies first).
4. Writes `.vault/track-binocle-reader.env` with `VAULT_ADDR=https://track-binocle-vault.fly.dev`.

---

## Prerequisite: flyctl vs. Docker Flyctl

`flyctl` does not need to be installed locally. When `FLY_API_TOKEN` is set and no local `flyctl`/`fly` binary exists, the Makefile automatically falls back to running `flyio/flyctl:latest` via Docker Compose:

```text
FLY := docker compose --profile secrets run --rm --no-deps -e FLY_API_TOKEN vault-fly
```

Docker must be running. The `vault-fly` service is defined in `docker-compose.yml` under the `secrets` profile and requires no extra setup.

---

## Maintainer Token Lifecycle

```text
.vault/track-binocle-admin.env    admin child token  — 2h TTL, created by vault-login-fly-admin
.vault/track-binocle-session.env  active session     — points to the same admin token
.vault/track-binocle-reader.env   reader invite token — 24h TTL, created by vault-session-reader-token
.vault/track-binocle-writer.env   writer invite token — 8h TTL, created by vault-session-writer-token
```

When the admin session expires, run `make vault-login-fly-admin` again. The reader/writer token files retain their own TTL independently.

To generate a writer token (for publishing updated env values to Vault):

```bash
make vault-session-writer-token
```

To close the session cleanly:

```bash
make vault-logout
```

---

## Generating a Teammate Reader Token

Once you have an active admin session, distribute a reader token to a teammate:

```bash
make vault-session-reader-token
```

Then share the contents of `.vault/track-binocle-reader.env` through a one-time secret link or encrypted channel. **Never paste the token in chat, tickets, commits, or screenshots.**

The teammate places the file at `.vault/track-binocle-reader.env`, sets `chmod 600`, and runs `make all`.

For a time-limited token (e.g. 24h for a school machine):

```bash
make vault-fly-invite-token VAULT_TEAM_ROLE=reader VAULT_TOKEN_TTL=24h
```

See [vault-security-model.md](../vault-security-model.md) for the full token lifecycle security model.

---

## Troubleshooting

### `flyctl not found locally and FLY_API_TOKEN is not set`

Set `FLY_API_TOKEN` in `.env.local` or export it in the shell, then retry.

### `Fly admin login could not read a Vault root token from the Fly volume`

The Fly app `track-binocle-vault` may be sleeping or undeployed. Check its status:

```bash
FLY_API_TOKEN=<token> docker compose --profile secrets run --rm --no-deps -e FLY_API_TOKEN vault-fly apps list
```

If the app is not running, redeploy it:

```bash
make vault-fly-deploy
```

### `Vault GET secret/data/.../env/root failed with HTTP 403`

The reader token exists but is rejected. Usually means the token expired or was minted from a different Vault instance. Repeat from Step 2.

### `[vault] problem: localhost Vault tokens are not portable`

`make vault-shared-doctor` caught the same issue. The reader token still points to localhost. Repeat Step 3 (mint a new reader token from the Fly.io admin session).
