# track-binocle BaaS SDK integration

`track-binocle` talks to the BaaS through the public Kong gateway and the project SDK boundary. Frontend code should not call Postgres, PostgREST, pg-meta, Redis, or Supavisor directly.

## Start The Stack

Use the root Docker Compose stack:

```sh
docker compose up -d --build
```

The stack exposes:

- Kong gateway: `http://localhost:8000`
- Website proxy: `http://localhost:4322/api`
- Auth gateway: `http://localhost:8787/api/auth`

All other service traffic stays inside the Docker network.

## Frontend Environment

The Docker bootstrap writes the ignored website environment file at `apps/opposite-osiris/.env.local`.

Expected browser-facing defaults:

```dotenv
PUBLIC_BAAS_URL=/api
PUBLIC_AUTH_GATEWAY_URL=/api/auth
PUBLIC_SITE_URL=http://localhost:4322
```

The website container proxies `/api` to Kong and `/api/auth` to the auth gateway. Browser code uses relative URLs and never needs direct database credentials.

## SDK Initialization

The website uses the local `@mini-baas/js` package through Docker-managed dependency volumes. Keep SDK access behind the project helpers and route requests through the gateway:

```ts
import { createClient } from '@mini-baas/js';
import { baasConfig } from './baas-config';

export const client = createClient({
  url: baasConfig.url,
  anonKey: baasConfig.anonKey,
});
```

Use [docs/howtouse.md](howtouse.md) for the full Docker-only workflow.
