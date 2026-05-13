# How To Use The Docker Pipeline

This workspace runs through Docker Compose only. Do not install app dependencies on the host and do not start the website or osionos app with local `npm`, `pnpm`, or `node` scripts. The root `docker-compose.yml` is the source of truth for the backend, the website, the osionos app, and the bridge between them.

## What Runs

- Website: `http://localhost:4322`
- osionos app: `http://localhost:3001`
- osionos bridge API: `http://localhost:4000`
- Auth gateway: `http://localhost:8787/api/auth`
- BaaS gateway: `http://localhost:8000`
- osionos Mail: `http://localhost:3002`
- Mail bridge: `http://localhost:4100`
- osionos Calendar: `http://localhost:3003`
- Calendar bridge: `http://localhost:4200`

The browser flow is:

1. Open the website at `http://localhost:4322`.
2. Create or sign in to a local development account.
3. The website asks the auth gateway for an osionos bridge session.
4. The bridge creates a short-lived one-time token and persists the private osionos workspace in Postgres.
5. The browser redirects to `http://localhost:3001/#bridge_token=...`.
6. osionos consumes the token and opens the user's private workspace.
7. The osionos sidebar app buttons open the Docker-served Mail and Calendar apps.

## Normal Workflow

Most users only need two commands:

```sh
make all
make playground
```

`make all` bootstraps the ignored runtime files, builds and starts the Docker stack, runs health checks, then prints the localhost URLs only after the pipeline is ready.

`make playground` opens a VS Code simulation viewer, then runs the Docker-contained Playwright scenario: open the website, create a development account, sign in, bridge into osionos, create a persisted markdown page through the osionos bridge, open Settings, open Mail and Calendar from the sidebar, and probe both service bridges. If Gmail or Google Calendar are already authorized in their ignored token files, the simulation also samples real messages/events without printing account values.

## Dependency Supply Chain Controls

Docker builds and CI use frozen lockfiles. npm-based apps use `npm ci --ignore-scripts`, and the local mini-BaaS SDK is built through an explicit trusted `npm run build` step instead of install-time lifecycle hooks. pnpm-based apps use `minimum-release-age=1440`, frozen lockfiles, store integrity checks, and explicit `onlyBuiltDependencies` allowlists for packages that genuinely need build scripts.

Dependabot and Renovate are configured at the root so JS, Docker, and GitHub Actions updates are reviewable and delayed after publication. Docker image CI enables SBOM/provenance attestations where the existing image pipelines build through Buildx.

## Environment And Vault

Runtime env files are managed by Docker-only commands. The generated `.env.example` files are grouped by required, recommended, optional, and legacy keys. Optional keys may stay commented or blank when the feature is not enabled, for example SMTP, analytics, Sonar, or third-party API integrations. Gmail and Google Calendar OAuth credentials are required for the root `make all` pipeline because the healthcheck verifies that both bridges are configured.

Useful commands:

```sh
make pulls
make env-format
make vault-seed
make vault-publish
make vault-status
make vault-invite-token VAULT_TEAM_ROLE=reader
make vault-invite-token VAULT_TEAM_ROLE=writer VAULT_TOKEN_TTL=8h
make vault-fetch-shared VAULT_TOKEN_FILE=.vault/track-binocle-reader.env
make env-fetch-shared
make vault-publish-shared VAULT_PUBLISH_TOKEN_FILE=.vault/track-binocle-writer.env
make vault-repair-shared VAULT_PUBLISH_TOKEN_FILE=.vault/track-binocle-writer.env
make vault-github-oidc
make vault-fly
make vault-rotate-approles
make vault-verify-approles
make env-fetch
make env-restore-test
make db-password-check
make db-password-apply
make pushes
```

`make pulls` fetches and pulls the root repository plus every recursive submodule before the Docker pipeline runs. It uses configured upstream branches when they exist and otherwise fetches without changing branches. `make all` runs this first so a fresh clone is brought as close as possible to the latest upstream state before dependencies and containers are built.

`make pushes` stages, commits, and pushes every recursive submodule and then the root repository. It commits deeper nested submodules first so parent repositories record the new submodule SHAs. The default commit message is `update`; override it with `make pushes GIT_COMMIT_MESSAGE="your message"`.

`make env-format` rewrites managed env files and examples with comments and categories. Real env files comment out missing values so later Compose env files do not accidentally override earlier non-empty secrets with blanks.

`make vault-seed` starts local HashiCorp Vault through the Compose `secrets` profile, initializes and unseals it, creates service AppRoles, and stores the managed env data under `secret/data/track-binocle/env/*`. Vault is exposed only on `http://127.0.0.1:8200` by default.

`make vault-publish` updates the managed Vault env records from the ignored local env files after a maintainer changes a credential. `make vault-status` compares local and Vault key coverage without printing values.

For teammates, a maintainer can run `make vault-invite-token VAULT_TEAM_ROLE=reader` to write an ignored `.vault/track-binocle-reader.env` token file, or `make vault-invite-token VAULT_TEAM_ROLE=writer VAULT_TOKEN_TTL=8h` for someone allowed to publish updated secrets. Share that file through your normal secure channel, never through Git. Invited users can place the reader file in `.vault/` and run `make all`; the Makefile fetches shared secrets before seeding the local Vault when the token file is present. They can also run `make vault-fetch-shared VAULT_TOKEN_FILE=.vault/track-binocle-reader.env` explicitly.

If a colleague receives an old or incomplete Vault payload, the fetch now fails before Compose starts and prints only the missing key names. A maintainer with complete ignored env files should repair the shared Vault with `make vault-repair-shared VAULT_PUBLISH_TOKEN_FILE=.vault/track-binocle-writer.env`, then recreate or resend reader tokens as needed. Writers can still run `make vault-publish-shared VAULT_PUBLISH_TOKEN_FILE=.vault/track-binocle-writer.env` after updating local ignored env files.

The GitHub workflow `.github/workflows/colleague-docker-pipeline.yml` simulates the colleague path on `push`, `pull_request`, and manual runs. It authenticates to Vault with GitHub OIDC, so do not store a static Vault token in GitHub secrets. `make vault-fly` creates the Fly app `track-binocle-vault`, deploys Vault at `https://track-binocle-vault.fly.dev`, publishes the managed env records, configures GitHub Actions OIDC, maps the GitHub team `Univers42/transcendance` to the Vault reader policy, and sets the repository variables. The variables `TRACK_BINOCLE_VAULT_ADDR`, `TRACK_BINOCLE_VAULT_AUTH_PATH=jwt`, `TRACK_BINOCLE_VAULT_ROLE=track-binocle-github-actions`, and `TRACK_BINOCLE_VAULT_ENV_PREFIX=secret/data/track-binocle/env` describe the Vault OIDC login path. If private submodule checkout needs broader access than `GITHUB_TOKEN`, set `SUBMODULES_TOKEN` to a PAT that can read the submodule repositories.

Developers in the GitHub team can use Vault's GitHub auth against the public Fly Vault without a shared Vault password. After authenticating with `gh`, run `gh auth refresh -s read:org` if the CLI token cannot read organization teams, then `export VAULT_ADDR=https://track-binocle-vault.fly.dev` and `export VAULT_TOKEN="$(vault login -method=github -format=json token="$(gh auth token)" | jq -r '.auth.client_token')"`. `make vault-fetch-shared` can then fetch the managed env files. The Vault policy grants read access only to the managed env path, not broad `secret/*` access.

`make vault-rotate-approles` rotates service AppRole secret IDs and stores the new IDs in Vault. `make vault-verify-approles` logs in with the root service AppRoles and verifies each token can read the managed Vault env secret without printing secret values. This confirms the local AppRole path for the BaaS, osionos, website, Mail, and Calendar services.

`make env-fetch` materializes the current Vault values back into the ignored local env files before the Compose stack starts. Fetch merges non-empty Vault values with existing local/generated values, so an older Vault record cannot erase a newly generated required value. `make env-restore-test` creates `.env.bak` files, removes the managed env files, fetches them from Vault, and verifies required keys came back.

If the live Postgres volume was initialized with an older password than `apps/baas/.env.local`, `make db-password-check` detects the drift and `make db-password-apply` applies the current ignored env password to the live Postgres role without printing it. After changing database credentials, run `make db-password-apply`, `make vault-publish`, and then `make env-fetch` on other machines.

## osionos Mail And Calendar

The Gmail and Google Calendar service apps are Docker-managed from the repository root:

```sh
docker compose up --build mail mail-bridge calendar calendar-bridge
```

Convenience commands are also available:

```sh
make mail-up
make calendar-up
npm run dev:all
```

Mail runs at `http://localhost:3002` with its bridge at `http://localhost:4100`. Calendar runs at `http://localhost:3003` with its bridge at `http://localhost:4200`. Google OAuth credentials belong in the ignored app env files or the BaaS Vault secret configured by each bridge. Calendar can reuse the Mail app's `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`; put Calendar-specific overrides in `apps/calendar/.env.local`. The root stack builds stable local images named `track-binocle/mail:local`, `track-binocle/mail-bridge:local`, `track-binocle/calendar:local`, and `track-binocle/calendar-bridge:local` unless overridden with compose image variables.

To publish the app images to DockerHub, set `DOCKER_USER` and `DOCKER_PAT` in the shell or an ignored env file, then run:

```sh
make app-images-push VERSION=v0.1.0
```

This target logs in with `--password-stdin`, tags every app image with the requested version and `latest`, and pushes them without printing the token.

## Fresh Start Internals

The Makefile runs these commands from the repository root:

```sh
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD":/workspace -w /workspace node:22-alpine node apps/baas/scripts/bootstrap.mjs
docker compose --profile secrets run --rm --no-deps vault-env node apps/baas/scripts/vault-env.mjs fetch # only when .vault/track-binocle-reader.env or VAULT_TOKEN is present
docker compose --profile secrets up -d --build vault
docker compose --profile secrets run --rm --build vault-init
docker compose --profile secrets run --rm vault-env node apps/baas/scripts/vault-env.mjs fetch
docker compose up -d --build
```

The bootstrap command generates ignored local runtime files without using host Node. If a shared Vault token exists, the Makefile fetches team secrets first; if the shared Vault is missing required keys, it stops with the missing key names. The local Vault commands then keep env files aligned with the local Vault store. The final Compose command builds and starts every service.

If the website dependency volume needs to be initialized separately, run:

```sh
docker compose up -d --build opposite-osiris-deps
docker compose up -d --build
```

## Health Checks

```sh
docker compose ps
curl -fsS http://localhost:4000/api/auth/bridge/health
curl -fsS http://localhost:3001 >/dev/null
curl -fsS http://localhost:4322 >/dev/null
curl -sS -o /dev/null -w 'auth-gateway-http-%{http_code}\n' http://localhost:8787/api/auth/availability
curl -fsS http://localhost:4100/health >/dev/null
curl -fsS http://localhost:3002 >/dev/null
curl -fsS http://localhost:4200/health >/dev/null
curl -fsS http://localhost:3003 >/dev/null
curl -fsS http://localhost:4200/baas/status | grep -q '"connected":true'
```

`http://localhost:8787/health` is not a real route for this gateway. Use `/api/auth/availability`.

To confirm the bridge database tables exist:

```sh
docker compose exec -T postgres sh -lc 'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select schemaname || chr(46) || tablename from pg_tables where tablename like chr(37) || chr(111) || chr(115) || chr(105) || chr(111) || chr(110) || chr(111) || chr(115) || chr(37) order by 1;"'
```

To confirm a bridge login created a workspace:

```sh
docker compose exec -T postgres sh -lc 'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from public.osionos_workspaces; select name from public.osionos_workspaces order by created_at desc limit 3;"'
```

## Login Verification

The verified development flow is:

1. Open `http://localhost:4322`.
2. Click `Start free`.
3. Create a local account. Development email verification is disabled in the Docker stack, so the account can sign in immediately.
4. Switch to `Sign in` and sign in with the new account.
5. Expect a redirect to `http://localhost:3001`.
6. The final osionos URL should look like `http://localhost:3001/#source=adapter&view=v-prod-table` after the bridge token is consumed.
7. The sidebar should show the user's private workspace, for example `dockerbridge's osionos`.

The Playwright verification performed for this stack created a local account, signed in through the website, redirected into osionos, consumed the bridge token, and found this app session in browser storage:

```json
{
  "hasBridgeSession": true,
  "bridgePersona": "dockerbridge",
  "workspace": "dockerbridge's osionos",
  "accessTokenPrefix": "osionos_v1."
}
```

Postgres then reported one persisted bridge workspace named `dockerbridge's osionos`.

## Logs

```sh
docker compose logs -f opposite-osiris osionos-app auth-gateway osionos-bridge
```

Useful focused logs:

```sh
docker compose logs --tail=120 project-db-init
docker compose logs --tail=120 osionos-bridge auth-gateway postgrest
```

## Stop And Restart

Stop containers but keep data and dependency volumes:

```sh
docker compose down
```

Start again:

```sh
docker compose up -d --build
```

Fully reset containers, Postgres data, dependency volumes, and generated runtime state:

```sh
docker compose down -v
make
```

Use the reset only when you intentionally want to remove local database data and Docker dependency volumes.

## Dependency Rule

Host dependency folders should not be used. While containers are running, some app paths may show `node_modules` because Docker volumes are mounted there. Those are Docker-managed volumes, not host installs.

If host dependency folders were created by an older local workflow, stop the stack first and remove them from the host filesystem:

```sh
docker compose down
find apps infrastructure -name node_modules -type d -prune -exec rm -rf {} +
docker compose up -d --build
```

Do not run local package manager install commands afterward. Docker will recreate the needed dependency volumes through the Compose services.
