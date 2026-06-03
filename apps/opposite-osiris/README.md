# opposite-osiris

Astro website for the local track-binocle pipeline. In this workspace it is run by the root Docker Compose stack at `https://localhost:4322` through the local TLS proxy.

Do not install website dependencies on the host. The package scripts are guarded so direct host execution points back to Docker.

## Docker-Only Commands (No Local Node)

Use the helper script from this app folder:

```sh
./scripts/docker-workflow.sh --help
./scripts/docker-workflow.sh npm run lint
./scripts/docker-workflow.sh npm run check
./scripts/docker-workflow.sh npm run build
./scripts/docker-workflow.sh shell
```

The script finds the repository root, ensures the `opposite-osiris` service is up, then executes commands inside the running container.

VS Code tasks are also available in `.vscode/tasks.json`:

- `docker: up opposite-osiris`
- `docker: logs opposite-osiris`
- `docker: lint`
- `docker: check`
- `docker: build`
- `docker: shell opposite-osiris`

## Run

From the repository root:

```sh
docker compose up -d --build opposite-osiris
```

For the full website to osionos flow, start the complete stack:

```sh
docker compose up -d --build
```

## Runtime Wiring

- `/api/auth` proxies to the Docker `auth-gateway` service.
- `/api` proxies to the Docker Kong gateway.
- Successful login creates an osionos bridge session and redirects to `https://localhost:3001`.

The complete operating guide is [../../docs/howtouse.md](../../docs/howtouse.md).
