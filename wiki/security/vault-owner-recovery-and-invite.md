# Vault Owner Recovery And Reader Invites

This note records what I verified while repairing the Track Binocle Vault invite flow. I am writing it in the first person because it is my operational record: what I checked, what I could prove, what I could not do from this machine, and what the consequences are if the owner credentials are lost.

## What I Verified

I inspected the root `Makefile`, the Vault Compose services, the Vault bootstrap scripts, the Fly entrypoint, and the Vault ACL policies. The local Vault and the Fly Vault both use HashiCorp Vault with a single-node file storage backend. The managed team environment records live under:

```text
secret/data/track-binocle/env/*
```

The invite policies are intentionally narrow:

- `track-binocle-env-reader` can read managed env records and list their metadata.
- `track-binocle-env-writer` can create, read, and update managed env records.
- Neither reader nor writer can write policies, create tokens, mount engines, read `sys/*`, or become owner.

I generated a local reader invite token with:

```sh
make vault-invite-token VAULT_TEAM_ROLE=reader VAULT_TOKEN_TTL=1h
```

That wrote `.vault/track-binocle-reader.env` with file mode `600`. This local token points to `https://localhost:18200`, so it is only useful on the machine that owns the local Docker Vault. It is not a teammate token for a fresh VM.

I then simulated the no-admin boundary against the local Vault. I did not print token values. The important status codes were:

```text
no-token sys/mounts: 403
reader sys/mounts: 403
reader token/create: 403
reader env metadata list: 200
```

This proves the expected behavior for this setup: without owner/admin credentials, I cannot query administrative Vault state, and a reader invite token cannot mint new tokens or promote itself. The reader can only see the managed env metadata and read the managed env values that the policy allows.

## What I Could Not Do From This Machine

I checked for active environment files with a path-only scan and found only `.env.example` files in this checkout. There were no active `.env` or `.env.local` files to publish from this machine. Because of that, I did not publish a real shared environment payload in this session.

I also checked for the Fly CLI. Neither `flyctl` nor `fly` was installed in this environment. That means I could not destroy, recreate, or reseed the Fly-hosted Vault from here. The remote shared Vault at `https://track-binocle-vault.fly.dev` can only be reset by someone who has Fly operator access and the Fly CLI available.

## Lost Admin API Key Path

If I lose only the Vault admin API key but the unseal/recovery key still exists, I do not need to destroy the Vault. HashiCorp Vault supports root token generation from the configured unseal or recovery key threshold. In this project the Fly Vault stores that key in `/vault/data/.vault-keys.json`, so the practical proof of ownership is Fly operator access to the Vault app plus an explicit local confirmation gate.

The guarded command is:

```sh
make admin-cred-lost
```

It requires `EMAIL_RECUP_ADMIN_VAULT`, asks me to type that address, asks for a recovery phrase bound to the Fly app and address, asks for a local passphrase, and then requires authenticated Fly operator access. It writes the regenerated admin token to `.vault/track-binocle-admin.env`, updates the Fly key file, retires the previous stored root token when possible, writes a non-secret receipt to `.vault/admin-cred-lost-receipt.env`, publishes the current managed env records, and mints fresh reader and writer token files.

This command does not send tokens by email and does not print them. Email is used only as a human confirmation value because sending a Vault root token through email would weaken the security boundary.

## Why Losing Owner Credentials Can Be Real Data Loss

Vault is doing the correct thing here. If I lose the root token and unseal key for a Vault instance, I should not be able to recover the secrets from Vault through an invite token or through the public API. A reader token is a bearer credential with a limited policy, not a recovery key.

For this project, the practical consequence is:

- If I lose only an invite reader or writer token, I can mint a new one if I still have owner access.
- If I lose the Fly Vault root token or unseal key but still have the original ignored env files somewhere, I must recreate the Fly Vault and publish those env files again.
- If I lose the Fly Vault root token or unseal key and I also lose the original env files, the secrets stored only in that Vault are gone for the project. I must generate new secrets, rotate dependent services, and republish a new environment.
- If I lose Fly operator access, I cannot reset the Fly app or access the persistent volume through Fly either. The owner boundary has moved from Vault to the Fly account.

This is the intended security model. A teammate with a reader invite must not be able to recover owner credentials or take over the Vault.

## Owner Reset Path

I added a confirmation-gated Makefile target for the owner reset path:

```sh
make vault-fly-reset VAULT_FLY_RESET_CONFIRM=destroy-track-binocle-vault
```

This target is destructive. It destroys the Fly app boundary for `track-binocle-vault`, removes local ignored invite-token files, recreates the Fly Vault with `make vault-fly`, publishes the managed env records, and rewires GitHub Actions variables.

Before I run that target for real, I need these conditions to be true:

- `flyctl` or `fly` is installed and authenticated as the owner.
- The ignored `.env` and `.env.local` files exist locally and contain the values I want to publish.
- I accept that old Vault contents are unrecoverable after reset unless I already backed them up outside Vault.

The safe owner sequence is:

```sh
make env-format
make vault-fly-reset VAULT_FLY_RESET_CONFIRM=destroy-track-binocle-vault
make vault-reader-token
make vault-shared-doctor VAULT_TOKEN_FILE=.vault/track-binocle-reader.env
```

If I only need to publish updated values to an existing reachable Fly Vault and I still have owner/root access, I do not reset the app. I use:

```sh
make vault-fly-publish
make vault-reader-token
```

## Reader Invite Path

For teammates, I should create Fly-backed reader tokens, not local tokens:

```sh
make vault-reader-token
```

That writes `.vault/track-binocle-reader.env`. I share that file only through a secure channel, never through Git. The teammate stores it under `.vault/`, keeps it private with `chmod 600`, and verifies wiring with:

```sh
make vault-shared-doctor VAULT_TOKEN_FILE=.vault/track-binocle-reader.env
make vault-fetch-shared VAULT_TOKEN_FILE=.vault/track-binocle-reader.env
```

A reader token can fetch the environment but cannot publish or administer Vault. A writer token should be short-lived and only given to someone allowed to update shared env values:

```sh
make vault-writer-token VAULT_TOKEN_TTL=8h
```

Reader and writer invite tokens are created as orphan Vault tokens by default. That keeps them usable after the short-lived owner/admin session that minted them has been revoked. Set `VAULT_TOKEN_ORPHAN=false` only when deliberately testing parent-child revocation.

## Why The Fly Vault Exists

The local Docker Vault is useful for same-machine testing, but it is bound to `localhost` and the Docker volume on that machine. A token generated from local Vault is deliberately rejected by the shared fetch path unless I set `VAULT_ALLOW_LOCAL_SHARED=true` for same-machine testing.

The Fly Vault exists because teammates and GitHub Actions need a stable HTTPS Vault URL that is reachable outside my laptop:

```text
https://track-binocle-vault.fly.dev
```

The Fly deployment stores Vault data on a Fly volume mounted at `/vault/data`. On first boot, the Fly entrypoint initializes Vault, writes `/vault/data/.vault-keys.json`, unseals Vault, syncs policies, configures GitHub OIDC, and maps the GitHub team to the reader policy. GitHub Actions should use OIDC instead of a static Vault token in repository secrets.

## Security Notes And Weak Points

The current model is strong for invite-token separation: readers cannot become owners and writers cannot change policies. The important residual risks are operational:

- A Vault invite token is a bearer credential. Anyone who receives it can use the permissions until it expires.
- The Fly Vault root token and unseal key are stored in the Fly volume at `/vault/data/.vault-keys.json`. Anyone with Fly operator access to the app can potentially retrieve them through `fly ssh console`.
- The Vault server uses single-node file storage and one unseal key share with threshold one. That is practical for this project, but it is not the same as production-grade HSM or cloud KMS auto-unseal.
- The local Docker Vault is a development convenience. Anyone with control over the local Docker host can access the local Vault volume and should be treated as local owner.
- The reset target is intentionally confirmation-gated because wiping the Fly Vault without a complete local env source means I lose secrets permanently.

The rule I keep is simple: readers fetch, writers update env records, and only the owner with Fly access can reset or administer the Vault. If I cannot prove I am the owner, Vault should say no.