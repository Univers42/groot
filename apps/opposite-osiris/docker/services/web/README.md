# opposite-osiris — standalone production image

A self-contained image of the **website**: nginx serves the static `astro build`
output **and** reverse-proxies `/api/*` to the BaaS. This is the "image alone,
still connected" shape — every dynamic feature (signup, login, newsletter, email
confirm, password reset) keeps working because the image carries its own proxy
layer, exactly mirroring the Vite dev-proxy routing.

> **Cutover (2026-06-05):** this image IS the pipeline website. `local-https-proxy`
> serves it at `https://localhost:4322`; the old in-repo `astro dev` service is
> retired (compose profile `legacy-website`). Published to Docker Hub as
> **`dlesieur/opposite-osiris-web`** (`:latest`), so the stack can `docker compose
> pull` it without the in-repo source. Verified end-to-end with the Playwright
> playground: throwaway account signup → osionos bridge handoff → persistence.

| File | Purpose |
| ---- | ------- |
| `Dockerfile` | 2-stage: node builds `dist/`, nginx serves + proxies it |
| `Dockerfile.dockerignore` | keeps the build context small (this build only) |
| `default.conf.template` | nginx server, rendered at start via `envsubst` |

## Why it isn't "just a static brochure"

The browser only ever calls **same-origin relative** paths (`/api`, `/api/auth`,
`/api/newsletter`). In `astro dev` the Vite proxy routes those to the backend; in
a plain static build nothing does, so auth/newsletter would 404. This image's
nginx replicates that routing:

| Request prefix | Upstream (default) | Path rewrite |
| -------------- | ------------------ | ------------ |
| `/api/auth/*` | `auth-gateway:8787` | none |
| `/api/newsletter/*` | `auth-gateway:8787` | none |
| `/api/*` (everything else) | `kong:8000` | strips leading `/api` |
| everything else | static files in `dist/` | — |

## Build & run (local stack)

Easiest — via the opt-in compose profile (the BaaS dev stack must also be up):

```bash
# 1) bring up the BaaS (auth-gateway, kong, postgres, …)
make all                       # or: docker compose --profile dev up -d

# 2) build + run the standalone website image, connected to that stack
PUBLIC_BAAS_ANON_KEY=$(grep -m1 '^PUBLIC_BAAS_ANON_KEY=' .env.local | cut -d= -f2-) \
  docker compose --profile web-image up -d --build opposite-osiris-web
# → http://localhost:4323   (plain HTTP; see "TLS" below)
```

Raw docker (no compose), connected to the running stack's network:

```bash
docker build -f apps/opposite-osiris/docker/services/web/Dockerfile \
  -t opposite-osiris-web:local \
  --build-arg PUBLIC_BAAS_ANON_KEY=<anon-jwt> .
docker run -d --name oo-web --network track-binocle_default -p 127.0.0.1:4323:8080 \
  opposite-osiris-web:local
```

## Configuration

### Build args — inlined into the browser bundle (`astro build`)
These cannot change after build; rebuild to change them.

| Build arg | Default | Notes |
| --------- | ------- | ----- |
| `PUBLIC_BAAS_URL` | `/api` | keep relative — proxied at runtime |
| `PUBLIC_AUTH_GATEWAY_URL` | `/api/auth` | keep relative |
| `PUBLIC_BAAS_ANON_KEY` | _(empty)_ | public anon JWT; needed by the email-confirm / password-reset pages (SDK direct calls). Other flows go through auth-gateway and don't need it. |
| `PUBLIC_SITE_URL` | `https://localhost:4323` | canonical URL + sitemap |
| `PUBLIC_OSIONOS_APP_URL` | `https://localhost:3001` | "open editor" link |
| `PUBLIC_AUTH_REQUIRE_EMAIL_VERIFICATION` | `false` | |
| `PUBLIC_TURNSTILE_SITE_KEY` | _(empty)_ | empty = localhost bypass |

### Runtime env — the BaaS connection (env-driven, default local, overridable)

| Env var | Default | Notes |
| ------- | ------- | ----- |
| `OO_AUTH_UPSTREAM` | `http://auth-gateway:8787` | serves `/api/auth/*` + `/api/newsletter/*` |
| `OO_BAAS_UPSTREAM` | `http://kong:8000` | serves the rest of `/api/*` |
| `OO_RESOLVER` | `127.0.0.11` | DNS for lazy upstream resolution (Docker embedded DNS). Set to your platform's DNS for non-Docker upstreams. |

Point at an external BaaS (staging/prod):

```bash
docker run -d -p 8080:8080 \
  -e OO_AUTH_UPSTREAM=https://gateway.example.com \
  -e OO_BAAS_UPSTREAM=https://baas.example.com \
  -e OO_RESOLVER=1.1.1.1 \
  opposite-osiris-web:local
```

## Notes / caveats

- **TLS** is terminated **upstream** (ingress / load balancer / the project's
  `local-https-proxy`). The image serves plain HTTP on `:8080`. `Strict-Transport-Security`
  is still emitted so it's honored once a TLS front-end is in place.
- **Security headers** (HSTS, `X-Frame-Options: DENY`, `frame-ancestors 'none'`,
  Referrer-Policy, Permissions-Policy) are added by nginx, matching
  `infrastructure/tls/nginx.conf`. The strict script/style CSP still comes from
  the app's per-page `<meta>` (Astro `security.csp`).
- **Build gotcha (`node-linker=hoisted`)**: `astro.config.mjs` imports `vite`
  directly, but `vite` is only a transitive dep. The Dockerfile installs with a
  flat/hoisted node_modules so that bare import resolves; a default isolated pnpm
  install fails with `Cannot find module 'vite'`.
- Lazy DNS means the image **starts even if the BaaS is down**; `/api` calls fail
  until the backend is reachable, then succeed — no restart needed.
