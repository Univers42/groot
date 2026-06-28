# Secrets Management — auth-gateway (the auth BFF)

> The auth-gateway image is built with no secrets embedded; every server-only credential is
> injected at container start-time from the host's `.env.local`, and the process runs as a
> non-root OS user so a compromised runtime cannot pivot to root-level host resources.

## What it is (the concept)

**Secrets management** is the discipline of keeping sensitive credentials — API keys, shared
secrets, SMTP passwords — out of artefacts that are stored, cached, or distributed (source trees,
container images, compose YAML) and delivering them only at the moment a process needs them.
The canonical pattern is **runtime injection**: the build produces a secret-free image; the
orchestrator supplies credentials through environment variables that exist only in the running
process's memory. A complementary control is **least-privilege execution**: running as a
**non-root user** limits blast radius if the process is compromised.

## What it defends against

See [Credential Theft via Secrets Exposure](../../attack/secrets-management.md).

If secrets were baked into an image layer, anyone with registry read-access — or who pulls the
public Docker Hub image `dlesieur/prismatica-auth-gateway` — could extract
`SERVICE_ROLE_KEY`, `OSIONOS_BRIDGE_SHARED_SECRET`, and `TURNSTILE_SECRET_KEY` with a single
`docker history` or layer-inspection command. A root-running process amplifies this: a
server-side request forgery or remote-code-execution vulnerability can reach the host's Docker
socket and escalate to full host compromise.

## How auth-gateway implements it

**1. Build context exclusion — `Dockerfile.dockerignore`**

[`apps/opposite-osiris/docker/services/api-gateway/Dockerfile.dockerignore`](../../../../apps/opposite-osiris/docker/services/api-gateway/Dockerfile.dockerignore)
explicitly removes every `.env` variant from the build context sent to the Docker daemon:

```
**/.env.local
**/.env.*.local
```

Even if a `COPY . .` instruction were added by mistake, no secret file would reach the image.

**2. Multi-stage image with no secret COPY — `Dockerfile`**

[`apps/opposite-osiris/docker/services/api-gateway/Dockerfile`](../../../../apps/opposite-osiris/docker/services/api-gateway/Dockerfile)
is a two-stage build. Stage 1 compiles the SDK; stage 2 copies only the compiled SDK output,
the gateway script, and email templates. The image comment on lines 7–8 makes the guarantee
explicit:

```dockerfile
# which are injected at RUNTIME via env — NEVER baked into this image.
```

**3. Non-root runtime user**

In the same Dockerfile, line 48:

```dockerfile
USER node
```

`node:22-alpine` ships a pre-created `node` user at UID 1000. All process activity runs under
that identity, with no capabilities to write to host paths, bind privileged ports, or access
the Docker socket.

**4. Runtime-only env injection, with TURNSTILE guard — `docker-compose.yml`**

[`docker-compose.yml`](../../../../docker-compose.yml) (lines 337–352) wires the auth-gateway
service with `env_file` only:

```yaml
env_file:
  - path: ./.env.local
    required: false
  # secrets injected at up-time from ./.env.local
```

`SERVICE_ROLE_KEY`, `OSIONOS_BRIDGE_SHARED_SECRET`, and `TURNSTILE_SECRET_KEY` are
intentionally absent from the `environment:` block. The compose comment (lines 348–352)
documents why:

```
# SECRET itself is NOT set here on purpose — `environment:` overrides
# `env_file:`, so an empty default would clobber the Vault-fetched value.
# TURNSTILE_SECRET_KEY is injected at up-time from ./.env.local.
```

Setting an empty default in `environment:` would silently shadow the vault-sourced value;
omitting it entirely guarantees `env_file` wins.

**5. Pure `process.env` reads at runtime — `auth-gateway.mjs`**

[`apps/opposite-osiris/scripts/auth-gateway.mjs`](../../../../apps/opposite-osiris/scripts/auth-gateway.mjs)
reads every credential exclusively from environment variables at process start (lines 53–68):

```js
serviceKey:          process.env.SERVICE_ROLE_KEY ?? ...,
turnstileSecret:     process.env.TURNSTILE_SECRET_KEY ?? '',
osionosBridgeSecret: process.env.OSIONOS_BRIDGE_SHARED_SECRET ?? '',
smtpPassword:        process.env.SMTP_PASSWORD ?? process.env.SMTP_PASS ?? '',
```

No file-system reads of secret material occur inside the gateway; no secret is logged or
echoed.

## How we know it is applied

The compose definition is the authoritative wiring: `docker compose up` for the `auth-gateway`
service will always source `./.env.local` via `env_file` and will never supply a default for
`TURNSTILE_SECRET_KEY`. The Dockerfile constraint is structural — a multi-stage build that
copies only named artefacts cannot accidentally include `.env` files, and the
`Dockerfile.dockerignore` enforces this at the build-context level before any `COPY` runs.

The `USER node` directive is unconditional; there is no code path that re-elevates to root
after the image entrypoint starts. Verifying the running container confirms this:

```
docker inspect track-binocle-auth-gateway-1 \
  --format '{{.Config.User}}'
# → node
```

## Reference

The [OWASP Secrets Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html)
codifies the exact pattern implemented here: inject credentials at runtime through the
environment rather than embedding them in build artefacts, and enforce least-privilege execution
to contain the impact of a runtime compromise. The `env_file`/`environment:` precedence guard
documented in the compose file is a practical application of the cheat sheet's "never default
a secret to an empty string" principle, which would otherwise silently disable the
vault-supplied value.

## Residual risk / assumptions

- **Host `.env.local` security is out of scope.** If the developer's workstation is compromised
  or `.env.local` is committed to git, the runtime injection boundary is bypassed entirely. The
  vault42 pull workflow (`make vault42-pull-all APPLY=1`) is the only sanctioned delivery path;
  no automated check prevents a developer from manually writing secrets into the file.
- **Image pull trust.** The image is pulled from Docker Hub (`dlesieur/prismatica-auth-gateway`)
  with no digest pin in the compose file. A supply-chain attack on the registry tag would
  deliver an image the runtime-injection controls cannot detect.
- **No-vault local mode.** When `42ctl` is absent, `make all` derives `.env.local` locally from
  grobase's self-generated secrets. `TURNSTILE_SECRET_KEY` may remain empty in that scenario;
  the gateway falls back to `TURNSTILE_BYPASS_LOCAL=true`, disabling Turnstile verification in
  the dev environment.
- **In-memory secret lifetime.** Secrets loaded into `process.env` persist for the lifetime of
  the Node process. A heap dump or `/proc/<pid>/environ` read by a co-tenant process would
  expose them; the non-root user mitigates cross-container reads but does not eliminate
  in-process exposure.
