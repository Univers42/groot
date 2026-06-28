# Secrets Management — grobase (the BaaS backend)

> Every runtime secret is generated cryptographically at first boot, never shipped with the repo, and injected into containers through mechanisms that keep the material off the filesystem layer — so a compromised image or leaked compose file yields nothing usable.

## What it is (the concept)

**Secrets management** is the discipline of generating, storing, rotating, and delivering sensitive values — passwords, HMAC keys, JWTs, TLS private keys — in a way that prevents accidental exposure and limits blast radius when one value is compromised. A well-managed secrets posture means **no hardcoded defaults**, **no committed secret files**, and **secret isolation**: a leak of one credential does not automatically compromise others. The **principle of least exposure** dictates that a secret is present only in the process that needs it, for only as long as needed.

## What it defends against

See [Credential Theft via Secrets Exposure](../../attack/secrets-management.md). In grobase's context, the two concrete threats are:

1. **Committed or image-baked secrets** — an attacker who clones the repo or pulls the container image must find no usable credential. A hardcoded `JWT_SECRET` would let them mint arbitrary JWTs for any tenant.
2. **Blast-radius coupling** — if every inter-service call authenticates with the same `JWT_SECRET` used for user tokens, a single exposure compromises both user auth and internal service trust simultaneously.

## How grobase implements it

### Cryptographically-random generation at first boot

[`apps/grobase/scripts/env/generate-env.sh`](../../../../apps/grobase/scripts/env/generate-env.sh) mints every runtime secret exactly once, on the first `make up` call that finds no `.env` file. The generation lines (lines 63–81) use `openssl rand` throughout:

```sh
JWT_SECRET="$(openssl rand -hex 32)"
VAULT_ENC_KEY="$(openssl rand -hex 16)"
# Inter-plane service token — DISTINCT from JWT_SECRET (audit O1/O2): a leak of the
# user-auth JWT secret must not also compromise service auth. Minted ONCE here.
ADAPTER_REGISTRY_SERVICE_TOKEN="$(openssl rand -hex 32)"
INTERNAL_IDENTITY_HMAC_KEYS="k1:$(openssl rand -hex 32)"
```

The `ANON_KEY` and `SERVICE_ROLE_KEY` are then derived as HS256 JWTs signed with `JWT_SECRET` via a local `jwt_hs256` shell function — no external service required. The script **refuses to overwrite** an existing secrets file without `FORCE=1` (line 23: `if [[ -f "$SECRETS_FILE" && "$FORCE" != "1" ]]; then … exit 1`), preventing accidental secret rotation that would break a live database.

### Gitignored secrets tree

[`apps/grobase/.gitignore`](../../../../apps/grobase/.gitignore) enforces that the entire generated secret surface is untrackable:

- Lines 5–8: `.env` and `.env.*` are excluded globally (`!.env.example` is the sole exception — only example files are committed).
- Lines 62–65: `certs/` (all generated TLS material) and `scripts/certs/*.key` are excluded; the cert-generation *scripts* remain tracked but their output does not.
- Lines 442–450: per-tenant provisioning envs (`*-tenant.env`, `*-baas.env`, `*.env.stale`) are excluded with an explicit comment: `# secrets: api keys, JWT, DSNs — NEVER track`.

### TLS private key delivered as a Docker secret, not a bind mount

[`apps/grobase/docker-compose.yml`](../../../../apps/grobase/docker-compose.yml) (lines 68–75) declares both TLS files as Docker top-level secrets:

```yaml
# TLS material for the waf (public HTTPS entrypoint) delivered as Docker secrets,
# not bind mounts. The source pems are generated once at fresh start by `make certs`
secrets:
  localhost_cert:
    file: certs/localhost.pem
  localhost_key:
    file: certs/localhost-key.pem
```

[`apps/grobase/orchestrators/compose/base/gateway.yml`](../../../../apps/grobase/orchestrators/compose/base/gateway.yml) (lines 13–15) wires them into the `waf` service:

```yaml
secrets:
  - localhost_cert
  - localhost_key
```

Docker secrets mount the files at `/run/secrets/<name>` on a **tmpfs** — they are never baked into an image layer, never written to a volume, and are destroyed when the container stops.

### Fail-closed enforcement for the encryption key

The `VAULT_ENC_KEY` used by the adapter-registry is verified at boot via [`apps/grobase/scripts/verify/m65-vault-enforce.sh`](../../../../apps/grobase/scripts/verify/m65-vault-enforce.sh). When `SECURITY_MODE=max`, the control plane's `LoadConfig` refuses to start if `VAULT_ENC_KEY` is absent or matches a known placeholder — it never silently falls back to an insecure value.

## How we know it is applied

`m65-vault-enforce.sh` is the concrete live proof. The gate's assertion chain (lines 37–48) is explicit:

```
(1) NEGATIVE / FAIL-CLOSED: boot SECURITY_MODE=max with NO Vault creds
    (placeholder VAULT_ENC_KEY, no VAULT_ADDR) -> the container MUST exit
    NON-ZERO and its logs MUST carry the explicit "SECURITY_MODE=max requires
    a Vault-backed VAULT_ENC_KEY" refusal. It MUST NOT serve /health/live.
(2) POSITIVE: boot SECURITY_MODE=max WITH a real key … -> MUST stay up and serve /health/live -> 200.
(3) PARITY: boot the DEFAULT SECURITY_MODE with the SAME placeholder key -> MUST boot (Vault not
    required; live baseline byte-identical).
```

The gate runs in an isolated ephemeral environment with a private Docker network, ensuring it never touches the live `mini-baas-*` stack. It exits non-zero on any assertion failure and names the exact assertion that tripped.

Additionally, the generate-env.sh clobber guard is exercised on every `make up` invocation that finds an existing `.env` — the make target (encoded in `orchestrators/makes/`) calls `[ -f .env ] || make env`, which only generates if absent, and the script itself re-checks and exits 1 with an explicit message if `FORCE!=1`.

## Reference

The [OWASP Secrets Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html) defines the full lifecycle — generation entropy requirements, storage isolation, rotation hygiene, and audit logging. Grobase's implementation directly satisfies the sheet's core mandates: secrets are generated with a cryptographic RNG (`openssl rand`), never stored in version control (`.gitignore` deny-list), and injected at runtime through a mechanism that avoids filesystem persistence (Docker secrets on tmpfs). The inter-plane key separation (`ADAPTER_REGISTRY_SERVICE_TOKEN` distinct from `JWT_SECRET`) implements the sheet's blast-radius containment principle.

## Residual risk / assumptions

- **Host filesystem trust**: `certs/localhost.pem` and `certs/localhost-key.pem` exist on the host as regular files before Docker reads them into the secrets mechanism. An attacker with host filesystem read access can retrieve the TLS private key directly, bypassing the tmpfs isolation.
- **No automatic rotation**: secrets are minted once. `FORCE=1` rotation requires manual coordination with the live database (the Postgres password is embedded in `DATABASE_URL` and `PGRST_DB_URI`); there is no built-in automated rotation pipeline.
- **`SECURITY_MODE=max` is opt-in**: the fail-closed `VAULT_ENC_KEY` enforcement (gate m65) activates only at `SECURITY_MODE=max`. The default mode boots with whatever key is present; a weak or placeholder `VAULT_ENC_KEY` in default mode is not refused at startup.
- **Monorepo root `.env` derivation**: the root repo's `env-local-ensure` target derives `./.env.local` from grobase's self-generated secrets. That derivation path must remain consistent; a manual edit to the grobase `.env` that is not reflected in the root `.env.local` produces a split-brain configuration without any automated detection.
