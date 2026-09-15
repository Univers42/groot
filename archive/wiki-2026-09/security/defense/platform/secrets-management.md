# Secrets Management — platform / infrastructure (cross-cutting)

> All credentials are kept out of the repository: they are either self-generated on first boot or
> pulled from a zero-knowledge remote store, and every CI push is scanned to verify nothing slipped through.

## What it is (the concept)

**Secrets management** is the discipline of ensuring that sensitive material — API keys, JWT signing
secrets, database passwords, and TLS credentials — never appears in version-controlled source code,
build logs, or command-line argument lists. A **zero-knowledge store** goes one step further: the
server that holds the encrypted blobs cannot decrypt them because the **encryption key stays on the
client device**. The **passphrase** that unlocks that device key is read with terminal echo disabled
so it never lands in process arguments, shell history, or system logs.

## What it defends against

See [Credential Theft via Secrets Exposure](../../attack/secrets-management.md).

In this stack, an attacker who obtains a committed `.env` file gains direct access to GoTrue JWT
signing material and PostgREST service keys, bypassing every Row-Level Security policy. A developer
who accidentally pushes a live API key to `main` would expose every tenant's data to anyone who reads
the public repository history.

## How platform implements it

**Control 1 — git-ignore all secret material**

[`.gitignore`](../../../../.gitignore) (lines 4–10, 19, 62) explicitly excludes
every pattern that could carry a secret from the working tree:

```
.env
.env.*
!.env.example
.env*local
.env\ copy*
.env*.bak
.vault/
```
and, further down, `*.secret` (line 19) and `.42ctl/` (line 62).

TLS certificate material under `apps/baas/certs/*` and `apps/baas/mini-baas-infra/certs/*` is also
excluded. Only `.env.example` (a template with no real values) is allowed through the negation rule.

**Control 2 — zero-knowledge encrypt-before-upload via 42ctl**

[`apps/grobase/scripts/vault/ctl-env.sh`](../../../../apps/grobase/scripts/vault/ctl-env.sh)
implements the push/pull protocol. Lines 31–44 read the keystore passphrase with `stty -echo` so it
is never echoed to the terminal and never appears in `ps` or shell history:

```sh
stty -echo 2>/dev/null || true
trap 'stty echo 2>/dev/null || true' EXIT INT TERM
read -r FT_PASSPHRASE
stty echo 2>/dev/null || true
```

The passphrase is then forwarded to the 42ctl container only via `-e FT_PASSPHRASE` (line 84) — not
as a positional argument. Line 66 confirms the model: `encrypting locally + uploading to project=…`.
The keystore file (`~/.config/42ctl/keystore.v42`, ~498 B) never leaves the developer's machine; the
remote vault stores ciphertext it cannot read.

For CI and headless agents, lines 35–36 honor a pre-set `FT_PASSPHRASE` or `VAULT42_PASSPHRASE`
environment variable so no TTY prompt is needed and the secret is injected through the CI secret
store, not the command line.

**Control 3 — secrets-ensure wired into `make all`**

[`infrastructure/makes/repo.mk`](../../../../infrastructure/makes/repo.mk)
(lines 64–73) implements a three-branch decision on every `make all` invocation:

- `apps/grobase/.env` already present → no-op (idempotent).
- `~/.config/42ctl/keystore.v42` present but `.env` absent → pull the entire `.env` tree from
  vault42 (`vault42-pull-all APPLY=1 FORCE=1`).
- Neither present → local no-vault mode: grobase self-generates its secrets and `env-local-ensure`
  derives the root `./.env.local` from the freshly generated backend values.

This means a bare `git clone` + `make all` comes up with working secrets in both vault and no-vault
paths, and no human step can accidentally skip the provisioning.

## How we know it is applied

**Proof 1 — `secrets-ensure` is a mandatory step in the `make all` recipe** (confirmed in
`CLAUDE.md`: `all: sync-submodules-soft secrets-ensure certs certs-trust-local backend-up
env-local-ensure restore-if-empty frontends-up healthcheck showcase`). Every machine bring-up,
whether on a developer laptop or a CI runner, traverses this target before any container starts.

**Proof 2 — blocking CI secret-scan gates** in
[`.github/workflows/mini-baas-security.yml`](../../../../.github/workflows/mini-baas-security.yml):

- **`secret-trufflehog`** (lines 222–247): runs `trufflesecurity/trufflehog@main` diff-scoped to
  the PR's commit range with `extra_args: --only-verified` — only live, provably-valid credentials
  trigger a failure, eliminating false positives.
- **`secret-gitleaks`** (lines 249–289): installs gitleaks 8.21.2 and runs:
  ```
  gitleaks detect --no-git --source apps/grobase \
    --config apps/grobase/.gitleaks.toml \
    --redact --exit-code 1
  ```
  The `--exit-code 1` flag makes any match a hard build failure; `--redact` ensures the matched
  value is never printed in CI logs.
- **`security-gate`** (lines 442–469) lists both `secret-trufflehog` and `secret-gitleaks` in its
  `needs:` array and exits 1 unless every job is `success` or `skipped`. This gate is evaluated on
  every `pull_request` and `push: branches: [main]` event (lines 7–10), so neither path to `main`
  can bypass it.

## Reference

The [OWASP Secrets Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html)
defines the lifecycle controls that this implementation covers: secret generation, encrypted
storage, access scoping, and rotation. The cheat sheet also recommends automated scanning of version
control history, which aligns directly with the dual TruffleHog + gitleaks CI layer above.

A complementary reference is the [OWASP Top 10 A05 Security Misconfiguration](https://owasp.org/Top10/A05_2021-Security_Misconfiguration/),
under which exposed secrets from misconfigured environments are one of the most frequently observed
root causes of breach in production deployments.

## Residual risk / assumptions

- **The keystore is the root of trust.** If `~/.config/42ctl/keystore.v42` is compromised (device
  theft, filesystem exfiltration), all vault-held secrets are exposed to whoever also learns the
  passphrase. The keystore is excluded from git but is not itself stored in a hardware security
  module; its protection rests entirely on device-level encryption and the passphrase strength.
- **No-vault mode uses self-generated secrets.** When the keystore is absent, grobase generates its
  own JWT signing material on first boot. These secrets are ephemeral to that deployment; the
  shared demo data and any cross-service tokens from vault42 will not align. This is documented and
  accepted for local development but is not appropriate for production.
- **CI secret injection.** The `FT_PASSPHRASE` / `VAULT42_PASSPHRASE` environment variable consumed
  by headless agents must be injected through the CI platform's secret store (e.g., GitHub Actions
  Secrets). If that secret store is misconfigured or the secret is logged, the encryption boundary
  is broken at the CI layer.
- **gitleaks scans the `apps/grobase` working tree only.** The `--source apps/grobase` flag means
  other submodules and root-level files are not covered by the gitleaks regex/entropy scan;
  TruffleHog's diff-scoped mode covers the whole repository but only for verified credentials, not
  high-entropy strings.
- **Rotation is manual.** There is no automated rotation schedule; the current model requires a
  human to trigger `make vault42-push-all` after rotating a secret. A rotated key that is not
  pushed to vault42 will diverge from what a fresh machine restores.
