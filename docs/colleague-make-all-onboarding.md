# Colleague Fresh Clone `make all` Onboarding

This document is the reproducible path for a new teammate on another computer and another network. The expected teammate workflow is intentionally small:

1. Clone the repository recursively.
2. Put the private Vault reader token in `.vault/track-binocle-reader.env` with private file permissions.
3. Run `make all`.

`make all` must fetch secrets, build images, start the HTTPS stack, verify service health, verify bridge credentials, and print the local service URLs without requiring manual Compose commands.

## What Was Rehearsed

On 2026-05-14, the nested child checkout at `apps/track-binocle` was destroyed, recloned with recursive submodules, given a private Vault reader token, and started with `make all` only.

The run activated the full default stack:

- `vault`
- `local-https-proxy`
- `postgres`
- `redis`
- `db-bootstrap`
- `project-db-init`
- `gotrue`
- `postgrest`
- `pg-meta`
- `kong`
- `osionos-bridge`
- `osionos-app`
- `auth-gateway`
- `opposite-osiris-deps`
- `opposite-osiris`
- `mail-bridge`
- `mail`
- `calendar-bridge`
- `calendar`

`supavisor` is intentionally not in the default stack. It is optional and lives behind the `supavisor` Compose profile because the application pipeline does not depend on it and it can slow or block fresh onboarding.

## Teammate Requirements

Install these before cloning:

- Git with access to the `Univers42` GitHub organization.
- Docker Engine or Docker Desktop with Compose v2.
- Docker Buildx. Current Docker Desktop includes it; on Linux verify with `docker buildx version`.
- Node.js is optional on the host. If host `node` is missing, the Makefile uses Dockerized Node for the bootstrap scripts.
- Enough disk space for Docker images, build cache, and npm/pnpm dependency volumes. Keep at least 15 GB free for a cold run.

Verify the local Docker toolchain:

```bash
docker version
docker compose version
docker buildx version
docker run --rm hello-world
```

On Linux, the user must be allowed to talk to Docker. If `docker ps` fails with permission errors, add the user to the Docker group and log out/in, or use the local Docker Desktop context.

## Clone Options

Preferred, when SSH to GitHub works:

```bash
git clone git@github.com:Univers42/track-binocle.git --recursive
cd track-binocle
```

If SSH port 22 is blocked by a school, office, VPN, or public network, use HTTPS instead. Private submodules still require GitHub credentials or a GitHub token accepted by Git credential storage.

```bash
git config --global url."https://github.com/".insteadOf git@github.com:
git config --global url."https://github.com/".insteadOf ssh://git@github.com/
git clone https://github.com/Univers42/track-binocle.git --recursive
cd track-binocle
```

If the clone was created without `--recursive`, repair it before running `make all`:

```bash
git submodule sync --recursive
git submodule update --init --recursive
```

## Vault Token Handoff

A teammate should not invent `.env` values manually. The shared team values come from Vault.

An admin creates a reader token file from a machine that already has working Vault access:

```bash
VAULT_TEAM_ROLE=reader make vault-fly-invite-token
```

The generated file is ignored by Git and should contain exactly these keys:

```text
VAULT_ADDR=...
VAULT_TOKEN=...
VAULT_ENV_PREFIX=...
```

Share those three lines through a one-time secret link or another approved secret channel. Do not paste the token in chat history, tickets, commit messages, logs, screenshots, or shell transcripts.

On the teammate machine, create the token file with private permissions:

```bash
mkdir -p .vault
umask 077
${EDITOR:-nano} .vault/track-binocle-reader.env
chmod 600 .vault/track-binocle-reader.env
```

Before running the full pipeline, check the token file without printing the token:

```bash
make vault-shared-doctor
```

After pasting the three lines, verify only the mode and key names, not the secret values:

```bash
stat -c '%a %n' .vault/track-binocle-reader.env
sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' .vault/track-binocle-reader.env | sort
```

Expected output shape:

```text
600 .vault/track-binocle-reader.env
VAULT_ADDR
VAULT_ENV_PREFIX
VAULT_TOKEN
```

`make all` refuses this file if it is world-readable or group-readable. Fix that with `chmod 600 .vault/track-binocle-reader.env`.

## The Only Startup Command

Run:

```bash
make all
```

Do not pre-run Compose manually for normal onboarding. `make all` is responsible for the full sequence:

1. Fetch shared env files from Vault using `.vault/track-binocle-reader.env`.
2. Pull and update root and recursive submodules.
3. Generate the local HTTPS CA and localhost certificate.
4. Best-effort trust the local CA in browser stores when the host supports it.
5. Bootstrap generated project files.
6. Format managed env files.
7. Prefetch public Docker images in parallel.
8. Start and seed local Vault services as needed.
9. Verify service AppRoles.
10. Fetch final env files.
11. Build local application images with `docker buildx bake --load`.
12. Start Docker Compose with prebuilt images using `--no-build`.
13. Wait for services and init jobs.
14. Run HTTPS and bridge health checks.
15. Print the local URLs.

A successful run ends by printing the service list below.

## Expected HTTPS Services

All public developer endpoints are exposed through the local HTTPS proxy on `127.0.0.1`:

| Service | URL |
| --- | --- |
| Website | `https://localhost:4322` |
| osionos app | `https://localhost:3001` |
| osionos bridge API | `https://localhost:4000` |
| Auth gateway | `https://localhost:8787/api/auth` |
| BaaS gateway | `https://localhost:8000` |
| Vault | `https://localhost:8200` |
| osionos Mail | `https://localhost:3002` |
| Mail bridge | `https://localhost:4100` |
| osionos Calendar | `https://localhost:3003` |
| Calendar bridge | `https://localhost:4200` |

`make all` also checks internal service communication:

- `osionos-bridge` answers through HTTPS.
- `auth-gateway` answers through HTTPS.
- Mail and Calendar bridges report configured OAuth sessions.
- Calendar bridge can reach the BaaS gateway.
- `opposite-osiris` verifies the internal BaaS/PostgREST gateway through `kong`.

## Ports And Conflicts

Default host ports:

```text
3001 osionos app
3002 mail
3003 calendar
4000 osionos bridge
4100 mail bridge
4200 calendar bridge
4322 website
5432 postgres
8000 BaaS gateway
8001 Kong admin
8200 Vault
8787 auth gateway
```

If another application already owns one of these ports, stop that application first. For short-lived local testing, host ports can be overridden, but the Makefile health URLs must be overridden too. Example:

```bash
make all \
  OPPOSITE_OSIRIS_HOST_PORT=14322 WEBSITE_URL=https://localhost:14322 \
  OSIONOS_APP_HOST_PORT=13001 OSIONOS_URL=https://localhost:13001
```

Prefer freeing the default ports for the first coworker run. It avoids mismatched OAuth callback URLs and browser trust confusion.

## Network And Registry Notes

Cold machines need to pull public base images. Network behavior varies a lot between home, school, office, VPN, and CI networks.

The Makefile prefetches images in parallel and supports these knobs:

```bash
make all DOCKER_PREFETCH_JOBS=4
make all DOCKER_PREFETCH_JOBS=2 DOCKER_PULL_TIMEOUT=300
```

Use fewer jobs on weak Wi-Fi or rate-limited networks. Use a longer pull timeout on slow VPNs. The default tries to balance speed with bounded failures.

If Docker Hub rate limits the machine, log in before running `make all`:

```bash
docker login docker.io
```

If GitHub Container Registry caching is available in CI or for a trusted developer, `REGISTRY_CACHE_PREFIX` can point to a registry cache namespace. The GitHub Actions colleague workflow sets this automatically for non-fork contexts.

If a corporate proxy is required, configure Docker itself, not only the shell. Docker Desktop has proxy settings in the UI. Linux Docker Engine usually needs proxy variables in the Docker systemd service drop-in.

## Local Certificate Notes

The pipeline generates a local CA at:

```text
apps/baas/certs/track-binocle-local-ca.pem
```

The HTTPS health checks use that CA directly with `curl --cacert`. Browser trust import is best-effort and skipped in CI/noninteractive environments. If the browser still warns after `make all`, run:

```bash
make certs-trust
```

On Debian/Ubuntu, `make certs-trust-system` installs missing `ca-certificates` and `libnss3-tools` with sudo, imports the CA into Chromium/Firefox NSS stores, and updates the Linux system CA store used by VS Code/Electron and some browsers. Set `TRACK_BINOCLE_CERTS_INSTALL_DEPS=0` to disable package installation and manage those packages manually. On other Linux distributions, install the equivalent `certutil` and system CA update tooling before running the trust target.

## CI Parity

The GitHub Actions colleague pipeline should also use `make all`. CI differs from a teammate machine in only two important ways:

- It obtains Vault credentials through GitHub OIDC instead of a pasted `.vault` token file.
- It uses Docker Buildx with a registry cache when permissions allow it.

The workflow must have:

- `id-token: write` for Vault OIDC.
- `packages: write` when pushing GHCR build cache.
- `docker/setup-buildx-action` before `make all`.

## Verification Commands

`make all` already runs these, but they are useful when diagnosing another machine:

```bash
docker compose ps
make compose-wait
make healthcheck
make showcase
```

Useful log commands:

```bash
docker compose logs --tail=120 kong
docker compose logs --tail=120 gotrue
docker compose logs --tail=120 osionos-bridge
docker compose logs --tail=120 mail-bridge
docker compose logs --tail=120 calendar-bridge
docker compose logs --tail=120 opposite-osiris
```

Check generated env coverage without printing values:

```bash
for file in .env.local apps/baas/.env.local apps/opposite-osiris/.env.local apps/osionos/app/.env apps/mail/.env.local apps/calendar/.env.local; do
  test -f "$file" && printf 'ok %s\n' "$file" || printf 'missing %s\n' "$file"
done
```

## Reset And Retry

For a normal retry, run `make all` again. It is designed to reuse pulled images, BuildKit cache, Docker volumes, and generated env files.

For a destructive local rehearsal like the one used to prove coworker onboarding, use this from the parent repository:

```bash
root=/path/to/track-binocle
child="$root/apps/track-binocle"
rm -rf "$child"
cd "$root/apps"
git clone git@github.com:Univers42/track-binocle.git --recursive
cd "$child"
mkdir -p .vault
umask 077
${EDITOR:-nano} .vault/track-binocle-reader.env
chmod 600 .vault/track-binocle-reader.env
make all
```

If Docker itself must be reset, use this with care because it removes containers, images, and BuildKit cache:

```bash
make docker-rm-all
make all
```

Volumes are preserved by default. Set `BOOL=true` only when you intentionally want Docker volumes removed too.

## Common Failure Modes

### Token file rejected

Symptom:

```text
[vault] refusing .vault/track-binocle-reader.env because it must be private
```

Fix:

```bash
chmod 600 .vault/track-binocle-reader.env
make all
```

### Missing shared Vault credentials

Symptom:

```text
[vault] missing shared Vault credentials
```

Fix: create `.vault/track-binocle-reader.env` from the one-time secret link, or export `VAULT_TOKEN`/`VAULT_API_KEY`, `VAULT_ADDR`, and `VAULT_ENV_PREFIX` in the shell. If only `VAULT_TOKEN` or `VAULT_API_KEY` is set, shared fetches default to the Fly Vault address. Local developer runs continue with generated secrets unless `VAULT_SHARED_REQUIRED=true` is set.

### Vault token rejected with HTTP 403

Symptom:

```text
Vault GET secret/data/track-binocle/env/root failed with HTTP 403
```

Fix: run `make vault-shared-doctor`. If it reports a localhost Vault address, replace the reader file with a Fly-backed invite generated by `make vault-fly-invite-token VAULT_TEAM_ROLE=reader`, then run `chmod 600 .vault/track-binocle-reader.env`. A localhost invite only works with the Vault instance on the machine that created it and requires `VAULT_ALLOW_LOCAL_SHARED=true` for same-machine testing.

### Git submodule clone fails on SSH

Symptom: SSH timeout or permission denied while cloning `git@github.com:Univers42/...`.

Fix for HTTPS networks:

```bash
git config --global url."https://github.com/".insteadOf git@github.com:
git submodule sync --recursive
git submodule update --init --recursive
make all
```

### Public image pull is slow

Symptom: `docker pull` waits on `public.ecr.aws`, Docker Hub, or `mirror.gcr.io`.

Fix options:

```bash
make all DOCKER_PREFETCH_JOBS=2 DOCKER_PULL_TIMEOUT=300
docker login docker.io
```

If a registry is blocked by a company or school network, change network, VPN policy, or Docker proxy settings. The app cannot start until Docker can pull the base images at least once.

### Buildx builder is inactive or unresponsive

The Makefile bootstraps the named builder and recreates it if it does not respond within the bounded timeout. Manual repair, if needed:

```bash
docker buildx rm -f track-binocle-builder || true
docker buildx create --name track-binocle-builder --driver docker-container --driver-opt image=moby/buildkit:buildx-stable-1 --use
make all
```

### Port already in use

Find the owner:

```bash
ss -ltnp | grep -E ':3001|:3002|:3003|:4000|:4100|:4200|:4322|:5432|:8000|:8001|:8200|:8787'
```

Stop the conflicting process or override both the Compose host port and the matching Makefile URL.

## Expected Coworker Success Criteria

A teammate is considered fully onboarded when one `make all` run from a fresh clone does all of this:

- Generates or reuses local HTTPS certificates.
- Fetches shared Vault-backed env files.
- Builds local app images through Buildx bake.
- Starts the full default Compose graph without `supavisor`.
- Leaves all long-running default services healthy or running.
- Leaves init jobs exited with code `0`.
- Passes `make healthcheck`.
- Prints the service URLs from `make showcase`.

At that point the teammate should be able to open the HTTPS URLs above and use the website, osionos app, Mail, Calendar, bridges, auth gateway, and BaaS gateway with the services communicating through Docker networking.
