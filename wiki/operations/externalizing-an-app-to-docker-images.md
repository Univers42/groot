# Externalizing an app into Docker images (runbook)

How to take an app that currently builds from in-repo source and turn it into
**self-contained Docker images** that the stack runs **pull-only** — without
breaking the pipeline, the secrets, or a fresh `make all`.

This was first done for **opposite-osiris** (the marketing/auth website + its
custom API gateway) on 2026-06-06. osionos (the editor + bridge) was also imaged
but **kept** in-repo as a submodule. Use this as the template for the next app.

> TL;DR of the hard-won lessons:
> 1. **Never bake private secrets into an image.** Inject them at runtime from Vault.
> 2. A static SPA needs a **proxy layer** in its image, or `/api/*` 404s in prod.
> 3. `astro build` needs `--config.node-linker=hoisted` (phantom `vite` import).
> 4. When you delete an app's source, **relocate any secret the rest of the stack
>    read from its `.env`**, or a fresh clone regresses (we hit this with Turnstile).
> 5. `docker compose environment:` overrides `env_file:` — don't set a secret to an
>    empty default in `environment:` or you clobber the Vault value.

---

## 1. The result (opposite-osiris)

| Service | Image (Docker Hub) | Role | Source in repo |
| ------- | ------------------ | ---- | -------------- |
| website | `dlesieur/opposite-osiris-web` | static Astro build + nginx that reverse-proxies `/api/*` | **removed** |
| API gateway | `dlesieur/prismatica-auth-gateway` | auth BFF; brokers account → app; holds private secrets | **removed** |
| osionos editor | `dlesieur/osionos-app` | static Vite SPA + nginx | kept (submodule) |
| osionos bridge | `dlesieur/osionos-bridge` | pure-Node persistence/gateway | kept (submodule) |

All four run with **`mounts=0`** (no source/workspace mounts) — verify with:

```bash
docker inspect track-binocle-<svc>-1 --format '{{.Config.Image}} mounts={{len .Mounts}}'
```

Request path (account → editor), all from images:

```
browser ──https──> local-https-proxy :4322 ──> [opposite-osiris-web]
                                                  │  /api/auth,/api/newsletter ─> [prismatica-auth-gateway] :8787
                                                  │  /api/* (strip /api)        ─> Kong :8000 ─> Postgres/GoTrue/PostgREST
[prismatica-auth-gateway] ─> osionos-bridge :4000 ─(osionos_v1. session)─> [osionos-app] :3001
```

---

## 2. Image build pattern

Two shapes, depending on the app:

**A. Static SPA + proxy (website, osionos-app).** Multi-stage: builder runs the
static build; runtime is `nginx:alpine` serving the build. If the app calls the
BaaS on the **same origin** (`/api`), the nginx must reverse-proxy `/api/*`
(mirror the old Vite dev-proxy routing); if it calls a **separate origin**
(osionos → bridge at `:4000`), nginx is static-only.

- Build context = the app dir (or repo root if it needs a sibling like the SDK).
- Keep the Dockerfile in the **root repo** (e.g. `infrastructure/docker/<app>/`)
  when building from a **submodule** so the submodule stays unmodified.
- Use a per-Dockerfile `<name>.dockerignore` to keep the build context small.
- **`PUBLIC_*` / `VITE_*` are inlined at build time** → pass them as `--build-arg`.
  Relative API paths (`/api`) stay constant across environments; only display
  URLs (site URL, sibling app URLs) and the **public** anon key are baked.

**Gotcha — Astro `vite` import.** `astro.config.mjs` does `import { loadEnv } from
'vite'`, but `vite` is only a transitive dep. A default pnpm (isolated) install
does not put it at the project root → `astro build` fails `Cannot find module
'vite'`. Install with `--config.node-linker=hoisted`.

**Gotcha — stale submodule prod Dockerfile.** osionos's own `Dockerfile.prod`
ran `pnpm run build` → `bash scripts/docker-run.sh build` but never COPYed that
script. The real build is just `pnpm exec vite build` (outDir `build/`). We
invoke `vite build` directly from a root-repo Dockerfile.

**B. Node service (api-gateway, bridge).** `node:alpine` + the script(s) + only
the runtime deps. The api-gateway needs the built `@mini-baas/js` SDK and the
email templates it reads at runtime (`src/email-templates/*.html`). The bridge is
pure built-ins + one sibling module — no `npm install`, no build.

**Secrets are NEVER baked.** Verify a runtime image has none:

```bash
docker run --rm --entrypoint sh <image> -c 'find / -name ".env*" 2>/dev/null'   # expect: nothing
```

---

## 3. Wire it pull-only in compose

- Replace `build:`/`working_dir`/`command`/source `volumes:` with just
  `image: <user>/<app>:latest` (+ `build:` kept temporarily as a local rebuild
  path while the source still exists).
- The front-door TLS proxy (`infrastructure/tls/nginx.conf`) points each public
  port at the image's internal port (e.g. `:4322 -> opposite-osiris-web:8080`,
  `:3001 -> osionos-app:80`).
- Publish + pull to prove it works from the registry, not local cache:

```bash
docker compose --profile dev pull <svc>
docker compose --profile dev up -d <svc>
```

---

## 4. Secrets & Vault — the important part

**Principle (12-factor): the image is environment-agnostic; secrets are injected
at runtime from a secret store.** Here that store is the Fly-hosted Vault; values
flow `Vault → .env files (make vault-fetch-shared) → compose env_file/environment
→ container env`. The only secret in an image is the **public** anon key in the
website bundle (by design — it's a browser-side publishable key).

- Managed env files + their Vault paths (`secret/data/track-binocle/env/<id>`)
  are declared in `apps/baas/scripts/vault-env.mjs` (`managedFiles`).
- Publish all secrets: see **[wiki/security/vault-publish-from-home.md](../security/vault-publish-from-home.md)**
  and **[wiki/security/vault-fly-admin-setup.md](../security/vault-fly-admin-setup.md)**.

### Publishing when the host has no `node`/`fly` and the stored token is stale
(Proven flow — full detail in the security docs above.)

1. `docker run -d --name vaultfly -e HOME=/fly-home -v vaultfly_home:/fly-home flyio/flyctl:latest auth login`
   then `docker logs vaultfly` → give the **user** the `https://fly.io/app/auth/cli/...`
   URL to approve. (Do **not** use the deploy `FLY_API_TOKEN` — it lacks SSH perms;
   the URL expires fast.)
2. Root token (keep in a shell var only, never print/persist):
   `docker run --rm -e HOME=/fly-home -v vaultfly_home:/fly-home flyio/flyctl ssh console --app track-binocle-vault --command 'jq -r .root_token /vault/data/.vault-keys.json'`
3. `VAULT_API_KEY=$TOKEN VAULT_ADDR=https://track-binocle-vault.fly.dev VAULT_TOKEN_FILE= VAULT_PUBLISH_TOKEN_FILE= make vault-publish-shared`
4. Mint fresh team tokens (default TTL is only 24h — pass `VAULT_TOKEN_TTL=720h`):
   `make vault-reader-token` / `make vault-writer-token` (or the docker-node
   `vault-env.mjs team-token` equivalent), then `docker rm -f vaultfly && docker volume rm vaultfly_home`.

> **GOTCHA:** the `vault-*-shared` recipes **source `VAULT_TOKEN_FILE` /
> `VAULT_PUBLISH_TOKEN_FILE` if the file exists**, overriding `VAULT_API_KEY`.
> If those files hold a stale token you get `403 permission denied`. Pass them
> empty (`VAULT_TOKEN_FILE=`) to force your token.

### When you DELETE an app's source, relocate the secrets it shared
This is the subtle regression. Other services may read keys from the deleted
app's `.env`. For opposite-osiris, the **api-gateway** read `TURNSTILE_BYPASS_LOCAL`
and `TURNSTILE_SECRET_KEY` only from `apps/opposite-osiris/.env.local`. After
removal, a fresh clone left those unset → the gateway enforced Turnstile → local
**signup broke**. Fix pattern:

- Move the **behavior flag** into the owning service's compose `environment:`
  with a safe default (`TURNSTILE_BYPASS_LOCAL: ${TURNSTILE_BYPASS_LOCAL:-true}`).
- Move the **secret** into a surviving managed file (`apps/baas/.env.local`) and
  add it to that file's `managedFiles` entry in `vault-env.mjs`, then republish.
  Do **not** put the secret in compose `environment:` with an empty default —
  `environment:` overrides `env_file:` and would clobber the Vault value.
- Remove the deleted app's `managedFiles` entry so `vault-fetch-shared` doesn't
  recreate its directory, and drop dead `env_file:` references to it.
- Beware JS `??`: `process.env.X ?? FALLBACK` only falls back on null/undefined.
  Setting `X=""` in compose **breaks** the fallback (e.g. anon key →
  `PUBLIC_BAAS_ANON_KEY ?? KONG_PUBLIC_API_KEY`). Leave it unset, don't empty it.

---

## 5. Fresh-start behavior (`make all` on a clean clone)

- `make vault-fetch-shared` regenerates the managed `.env` files from Vault. It
  `mkdir -p`s parents, so a **missing** app dir would be **recreated** to hold an
  env file — which is why we removed the deleted app's `managedFiles` entry.
- Services start from the pulled images; secrets arrive via `env_file`/`environment`.
- The deleted app's source is **not** needed; its build-time config belongs to its
  new home repo.

---

## 6. Verify (do this every time)

```bash
# 1. image-only at runtime
for s in opposite-osiris-web auth-gateway osionos-app osionos-bridge; do
  docker inspect track-binocle-$s-1 --format "$s {{.Config.Image}} mounts={{len .Mounts}}"; done

# 2. full account -> osionos flow (Playwright)
docker compose --profile testing run --rm playground-simulation   # expect: "...simulation succeeded."

# 3. fresh-start proof: remove the source dir, recreate from images, re-run (2)
mv apps/opposite-osiris apps/.stash
docker compose --profile dev up -d --force-recreate --no-deps auth-gateway opposite-osiris-web
docker compose --profile testing run --rm playground-simulation   # must still pass
mv apps/.stash apps/opposite-osiris
```

---

## 7. Repeatable checklist for the next app

1. Write image Dockerfile(s) (static+proxy and/or node service); keep secrets out.
2. Build, push to the registry, pin a real tag for prod (`:latest` is mutable).
3. Make the compose service pull-only; point the TLS proxy at it.
4. Drop local images, `docker compose pull`, bring up — confirm `mounts=0`.
5. Run Playwright + the dir-absent fresh-start proof.
6. Relocate any secret other services read from the app's `.env`; update
   `vault-env.mjs managedFiles`; remove the app's entry + dead `env_file` refs.
7. Republish secrets to Vault; verify `make vault-status-shared` is clean.
8. Snapshot uncommitted WIP **before** `git rm` (don't lose unsaved work), then
   remove the source. Update `infrastructure/makes/*` service lists.

---

## 8. Security posture / trust boundaries (be honest)

What's solid:
- Images carry **no private secrets** (verified); secrets are runtime-injected from Vault.
- Website bundle exposes only the **public** anon key (BaaS RLS is the real boundary).
- TLS at the edge + hardening headers (HSTS, `X-Frame-Options: DENY`,
  `frame-ancestors 'none'`, Referrer-Policy, Permissions-Policy) + strict hashed CSP.
- Single-use osionos bridge session; Turnstile anti-abuse in prod.

What you must still own (these, not the images, are the weak points):
- **Fly account access = Vault root.** The root token + unseal keys sit in
  `/vault/data/.vault-keys.json` on the Vault machine; anyone with `fly ssh` to
  that app has full Vault. Protect the Fly account (2FA), scope tokens.
- **BaaS Row-Level-Security policies** are what protect data behind the public
  anon key — audit them; the anon key being public is expected.
- **Docker Hub image visibility** — if the repos are public, the api-gateway/bridge
  source is readable (info disclosure, not secret leakage). Make them private if
  that matters.
- Pin image tags by digest for production; `:latest` is mutable.
- Rotate the Vault team tokens (720h TTL) and the `DOCKER_PAT`/`FLY_API_TOKEN`
  kept in local `.env.local`.

See also: [vault-security-model](../vault-security-model.md),
[SECURITY.md](../SECURITY.md). The osionos image Dockerfiles live at
`infrastructure/docker/osionos/`; the opposite-osiris image Dockerfiles moved out
with the source (git history at the snapshot commit before removal, and the new
opposite-osiris repo).
