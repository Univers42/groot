# Vault Session Management

This guide explains how Track Binocle manages HashiCorp Vault sessions from the root `Makefile`. The goal is to make Vault access explicit, short-lived, auditable, and easy to clean up without printing secret token values in terminals or logs.

## Security Model

Vault sessions are bearer credentials. Anyone who has a valid `VAULT_TOKEN` can use every permission attached to that token until it expires or is revoked. The Makefile therefore follows these rules:

- Tokens are written only to ignored private files under `.vault/` and optionally to the Vault CLI default `~/.vault-token`.
- Token files must be mode `600` or stricter.
- Session status prints metadata such as policies and TTL, never the token itself.
- `vault-logout` revokes the active token and removes local session files.
- The Fly root token is not used as the normal session token. `vault-login-fly-admin` uses Fly operator access to mint a short-lived child token with the `admin` policy.
- `VAULT_NAMESPACE` is supported for Vault Enterprise, but it is empty by default because the local/Fly Vault used by this project is the open-source single-namespace setup.

## Files

Default files used by the session targets:

```text
.vault/track-binocle-session.env      current project session token
.vault/track-binocle-admin.env        short-lived admin child token from Fly admin login
.vault/track-binocle-reader.env       reader invite token for fetching managed env values
.vault/track-binocle-writer.env       writer invite token for publishing managed env values
~/.vault-token                        optional Vault CLI session token
```

All `.vault/` files are ignored by Git.

## Configuration Variables

The important variables are:

```makefile
VAULT_SESSION_ADDR      # default: https://track-binocle-vault.fly.dev, or VAULT_ADDR if provided
VAULT_NAMESPACE         # optional Vault Enterprise namespace
VAULT_ENV_PREFIX        # default: secret/data/track-binocle/env
VAULT_SESSION_FILE      # default: .vault/track-binocle-session.env
VAULT_CLI_TOKEN_FILE    # default: ~/.vault-token
VAULT_WRITE_CLI_TOKEN   # default: true; set false to skip ~/.vault-token writes
VAULT_USER_AUTH_METHOD  # github or oidc; default: github
VAULT_JWT_AUTH_PATH     # default: jwt
VAULT_JWT_ROLE          # default: track-binocle-github-actions
VAULT_ADMIN_TOKEN_TTL   # default: 2h
```

`FLY_API_TOKEN` may live in the shell or in ignored local env files such as `.env.local`. The session helper parses that file directly, so values containing spaces still work.

## Target Overview

```sh
make vault-session-check
make vault-login-user
make vault-login-approle
make vault-login-jwt
make vault-login-fly-admin
make vault-session-status
make vault-get-secrets
make vault-kv-export VAULT_SECRET_PATH=secret/data/path VAULT_SECRET_OUTPUT=.vault/path.json
make vault-session-reader-token
make vault-session-writer-token
make vault-logout
```

Compatibility aliases are also available:

```sh
make check-env
make login-user
make login-approle
make login-jwt
make get-secrets
make logout
```

## Developer Login

The default developer login uses Vault's GitHub auth mount, because this project already maps the `Univers42/transcendance` GitHub team to the reader policy.

```sh
gh auth refresh -s read:org
make vault-login-user
make vault-session-status
make vault-get-secrets
```

If a Vault OIDC browser auth mount is configured later, use:

```sh
make vault-login-user VAULT_USER_AUTH_METHOD=oidc
```

OIDC browser login requires the Vault CLI on the host.

## AppRole Login

Machine users can authenticate with AppRole credentials from files or environment variables:

```sh
umask 077
printf '%s' '<role-id>' > .vault/track-binocle-role-id
printf '%s' '<secret-id>' > .vault/track-binocle-secret-id
make vault-login-approle
make vault-session-status
```

Equivalent environment variables are `VAULT_ROLE_ID` and `VAULT_SECRET_ID`.

## JWT Login

CI, Kubernetes, or another workload identity provider can exchange a JWT for a short-lived Vault token:

```sh
JWT_TOKEN='...' make vault-login-jwt
make vault-session-status
make vault-get-secrets
```

Use `VAULT_JWT_AUTH_PATH` and `VAULT_JWT_ROLE` to point at a different Vault JWT mount or role.

## Fly Admin Session

Owners can create a short-lived admin child token from Fly operator access:

```sh
make vault-login-fly-admin
make vault-session-status
```

This target reads the Fly Vault root token from the Fly volume, immediately exchanges it for a short-lived child token with the `admin` policy, and stores that child token locally. It does not print the root token or use it as the active session token.

After creating an admin session, mint fresh invite tokens without using the Fly root token again:

```sh
make vault-session-reader-token
make vault-session-writer-token
```

Invite tokens minted through these targets are orphan tokens by default, so revoking the temporary admin session does not revoke the reader/writer files. Set `VAULT_TOKEN_ORPHAN=false` only when you intentionally want invite tokens to be children of the active admin session.

## Fetching Managed Secrets

Use the current session to fetch the managed Track Binocle env files:

```sh
make vault-get-secrets
```

This calls the existing `apps/baas/scripts/vault-env.mjs fetch` flow, which writes ignored env files and validates required keys. It does not dump secrets to stdout.

For an arbitrary KV path, use an ignored output file:

```sh
make vault-kv-export \
  VAULT_SECRET_PATH=secret/data/track-binocle/env/root \
  VAULT_SECRET_OUTPUT=.vault/root-secret.json
```

Avoid writing secrets to tracked paths such as `config.json`.

## Logout

Revoke the active session and remove local session files:

```sh
make vault-logout
```

By default this removes `.vault/track-binocle-session.env` and `~/.vault-token`. If `.vault/track-binocle-admin.env` contains the same token that was just revoked, logout removes it too so the next session check does not pick up a stale admin token. To force removal of the admin cache even when it contains a different token:

```sh
make vault-logout VAULT_LOGOUT_REMOVE_ADMIN=true
```

## Lost Admin Credentials

If the local admin API key is lost but Fly operator access and the Vault unseal key still exist, use the stricter recovery target:

```sh
make admin-cred-lost
```

That path regenerates root/admin credentials through Vault's root-generation flow and includes confirmation prompts. Use `vault-login-fly-admin` only to create a short-lived session from an existing healthy Fly Vault.

## CI/CD Notes

GitHub Actions should prefer Vault JWT/OIDC over static tokens. A workflow can request a GitHub OIDC token, set `JWT_TOKEN`, and run:

```sh
make vault-login-jwt
make vault-get-secrets
make vault-logout
```

For human developer machines, prefer GitHub auth or short-lived reader tokens. Avoid putting root/admin tokens in shell history, tickets, screenshots, or logs.