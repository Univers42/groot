# Fresh Clone Vault Onboarding

This guide verifies the same path a new teammate should use on a clean machine.

## Security Contract

`make all` is the shared-team pipeline. It must have Vault credentials before it does any Git or Docker bootstrap work.

Accepted credentials are:

- `VAULT_API_KEY` with `VAULT_ADDR`
- `VAULT_TOKEN` with `VAULT_ADDR`
- a private `VAULT_TOKEN_FILE`, usually `.vault/track-binocle-reader.env`

The token file must be mode `600` or `400`. Group-readable or world-readable files are refused. Without one of these credentials, `make all` exits immediately with an error. For local throwaway development secrets, use `make all-local` instead.

## Maintainer: Create The Teammate Key

Create a reader token from the shared Vault and send it through your secure channel. Do not commit it.

The teammate can receive either a password-like API key:

```sh
export VAULT_ADDR=https://track-binocle-vault.fly.dev
export VAULT_API_KEY=replace-with-reader-token
```

Or a private file:

```sh
mkdir -p .vault
chmod 700 .vault
cat > .vault/track-binocle-reader.env <<'EOF'
VAULT_ADDR=https://track-binocle-vault.fly.dev
VAULT_TOKEN=replace-with-reader-token
VAULT_ENV_PREFIX=secret/data/track-binocle/env
EOF
chmod 600 .vault/track-binocle-reader.env
```

## Teammate: Fresh Clone Verification

```sh
git clone git@github.com:Univers42/track-binocle.git --recursive
cd track-binocle
make docker-rm-all
VAULT_ADDR=https://track-binocle-vault.fly.dev VAULT_API_KEY=replace-with-reader-token make all
```

With a token file, use:

```sh
make all
```

Expected behavior:

- The shared Vault env files are fetched first.
- If Vault auth fails, the command stops before Docker Compose starts.
- If Vault data is incomplete, the command prints missing key names only and stops.
- If Vault auth succeeds, the local Vault is seeded from the fetched env, app services start through HTTPS, and the healthcheck verifies the full app pipeline.

## Negative Test

This should fail quickly:

```sh
env -u VAULT_API_KEY -u VAULT_TOKEN VAULT_TOKEN_FILE=/tmp/missing-track-binocle-token.env make all
```

The error should say shared Vault credentials are missing and suggest `make all-local` only for offline generated development secrets.

## GitHub Actions

The workflow `.github/workflows/colleague-docker-pipeline.yml` uses GitHub OIDC to create `.vault/track-binocle-reader.env` during the job. `make all` then exercises the same Vault-backed pipeline a teammate uses.

Do not store a static Vault token in GitHub secrets. The repository variables should point Actions at the public Vault OIDC login path:

- `TRACK_BINOCLE_VAULT_ADDR=https://track-binocle-vault.fly.dev`
- `TRACK_BINOCLE_VAULT_AUTH_PATH=jwt`
- `TRACK_BINOCLE_VAULT_ROLE=track-binocle-github-actions`
- `TRACK_BINOCLE_VAULT_ENV_PREFIX=secret/data/track-binocle/env`

## Troubleshooting Docker Pulls

After `make docker-rm-all`, every image layer must be downloaded again. `make all` runs `make docker-prefetch-images` before Compose builds; that target tries public mirrors first, retries each pull, and bounds every pull with `DOCKER_PULL_TIMEOUT` seconds. If all mirror and direct pulls fail, the pipeline exits with a Docker networking or registry error instead of waiting indefinitely. The default pipeline still fails before these pulls when credentials are missing.