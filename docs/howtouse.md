# How To Use The Docker Pipeline

This workspace runs through Docker Compose only. Do not install app dependencies on the host and do not start the website or osionos app with local `npm`, `pnpm`, or `node` scripts. The root `docker-compose.yml` is the source of truth for the backend, the website, the osionos app, and the bridge between them.

## What Runs

- Website: `http://localhost:4322`
- osionos app: `http://localhost:3001`
- osionos bridge API: `http://localhost:4000`
- Auth gateway: `http://localhost:8787/api/auth`
- BaaS gateway: `http://localhost:8000`

The browser flow is:

1. Open the website at `http://localhost:4322`.
2. Create or sign in to a local development account.
3. The website asks the auth gateway for an osionos bridge session.
4. The bridge creates a short-lived one-time token and persists the private osionos workspace in Postgres.
5. The browser redirects to `http://localhost:3001/#bridge_token=...`.
6. osionos consumes the token and opens the user's private workspace.

## Fresh Start

Run these commands from the repository root.

```sh
docker run --rm -v "$PWD":/workspace -w /workspace node:22-alpine node infrastructure/baas/scripts/bootstrap-env.mjs
docker run --rm -v "$PWD":/workspace -w /workspace node:22-alpine node infrastructure/baas/scripts/ensure-osionos-runtime-secrets.mjs
docker compose up -d --build
```

The first two commands generate ignored local runtime files without using host Node. The third command builds and starts every service.

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
docker run --rm -v "$PWD":/workspace -w /workspace node:22-alpine node infrastructure/baas/scripts/bootstrap-env.mjs
docker run --rm -v "$PWD":/workspace -w /workspace node:22-alpine node infrastructure/baas/scripts/ensure-osionos-runtime-secrets.mjs
docker compose up -d --build
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
