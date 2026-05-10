# track-binocle

Docker-only local runtime for the website, osionos app, bridge, and mini BaaS backend.

Do not install or run app dependencies on the host. The root `docker-compose.yml` owns the runtime, dependency volumes, database, gateways, website, and app.

## Start

From the repository root:

```sh
docker run --rm -v "$PWD":/workspace -w /workspace node:22-alpine node infrastructure/baas/scripts/bootstrap-env.mjs
docker run --rm -v "$PWD":/workspace -w /workspace node:22-alpine node infrastructure/baas/scripts/ensure-osionos-runtime-secrets.mjs
docker compose up -d --build
```

## URLs

- Website: `http://localhost:4322`
- osionos app: `http://localhost:3001`
- osionos bridge API: `http://localhost:4000`
- Auth gateway: `http://localhost:8787/api/auth`
- BaaS gateway: `http://localhost:8000`

## Verify

```sh
docker compose ps
curl -fsS http://localhost:4000/api/auth/bridge/health
curl -fsS http://localhost:3001 >/dev/null
curl -fsS http://localhost:4322 >/dev/null
curl -sS -o /dev/null -w 'auth-gateway-http-%{http_code}\n' http://localhost:8787/api/auth/availability
```

Open `http://localhost:4322`, create a development account, sign in, and expect the website to redirect into `http://localhost:3001` with the user's private osionos workspace.

## More

The complete operating guide is [docs/howtouse.md](docs/howtouse.md).
