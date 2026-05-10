# opposite-osiris

Astro website for the local track-binocle pipeline. In this workspace it is run by the root Docker Compose stack at `http://localhost:4322`.

Do not install website dependencies on the host. The package scripts are guarded so direct host execution points back to Docker.

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
- Successful login creates an osionos bridge session and redirects to `http://localhost:3001`.

The complete operating guide is [../../docs/howtouse.md](../../docs/howtouse.md).
