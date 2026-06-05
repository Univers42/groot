# syntax=docker/dockerfile:1.7
# ============================================================================
# opposite-osiris — standalone PRODUCTION image.
#
# Stage 1 (build): compile the @mini-baas/js SDK, then `astro build` the static
#                  site. PUBLIC_* values are INLINED into the client bundle at
#                  build time (Astro/Vite), so they are build args. The relative
#                  /api defaults stay constant across environments.
# Stage 2 (runtime): nginx serves the static build AND reverse-proxies /api/* to
#                  the BaaS — exactly mirroring the Vite dev-proxy routing. The
#                  upstreams are RUNTIME env (envsubst), default to the local
#                  Docker stack, and are overridable for staging/prod.
#
# Build context = repository ROOT (the app depends on apps/baas/sdk via file:).
#   docker build -f apps/opposite-osiris/docker/services/web/Dockerfile -t opposite-osiris-web .
# ============================================================================

# ---------------------------------------------------------------------------
# Stage 1 — build the static site
# ---------------------------------------------------------------------------
FROM public.ecr.aws/docker/library/node:22-alpine AS build

RUN corepack enable && corepack prepare pnpm@11.5.1 --activate
WORKDIR /workspace

# SDK first — it is a file: dependency of the app and must be built (tsc) before
# the app installs/links it. Install WITH dev deps (typescript) so the build runs.
COPY apps/baas/sdk apps/baas/sdk
RUN cd apps/baas/sdk \
 && pnpm install --frozen-lockfile --ignore-scripts \
 && pnpm run build

# App sources.
COPY apps/opposite-osiris apps/opposite-osiris
WORKDIR /workspace/apps/opposite-osiris

# Strip any host-specific env files that leaked into the build context so the
# build is deterministic and driven only by the ARGs below.
RUN rm -f .env.local .env.production.local .env.development.local

# --- Build-time PUBLIC_* config (inlined into the browser bundle). -----------
# Defaults target the local stack; override with --build-arg for staging/prod.
# PUBLIC_BAAS_URL / PUBLIC_AUTH_GATEWAY_URL stay RELATIVE on purpose: same-origin
# requests that nginx (this image) proxies to the BaaS at runtime.
ARG PUBLIC_BAAS_URL=/api
ARG PUBLIC_AUTH_GATEWAY_URL=/api/auth
ARG PUBLIC_BAAS_ANON_KEY=
ARG PUBLIC_SITE_URL=https://localhost:4322
ARG PUBLIC_OSIONOS_APP_URL=https://localhost:3001
ARG PUBLIC_AUTH_REQUIRE_EMAIL_VERIFICATION=false
ARG PUBLIC_TURNSTILE_SITE_KEY=

# Highest-precedence env file so the ARGs win over anything committed/copied.
RUN printf '%s\n' \
      "PUBLIC_BAAS_URL=${PUBLIC_BAAS_URL}" \
      "PUBLIC_AUTH_GATEWAY_URL=${PUBLIC_AUTH_GATEWAY_URL}" \
      "PUBLIC_BAAS_ANON_KEY=${PUBLIC_BAAS_ANON_KEY}" \
      "PUBLIC_SITE_URL=${PUBLIC_SITE_URL}" \
      "PUBLIC_OSIONOS_APP_URL=${PUBLIC_OSIONOS_APP_URL}" \
      "PUBLIC_AUTH_REQUIRE_EMAIL_VERIFICATION=${PUBLIC_AUTH_REQUIRE_EMAIL_VERIFICATION}" \
      "PUBLIC_TURNSTILE_SITE_KEY=${PUBLIC_TURNSTILE_SITE_KEY}" \
    > .env.production.local

# Install app deps and produce the static site.
#  * node-linker=hoisted -> a flat, npm-style node_modules. REQUIRED because
#    astro.config.mjs does `import { loadEnv } from 'vite'`, but `vite` is only a
#    transitive dep (via astro). pnpm's default isolated layout does not place
#    `vite` at the project root, so Astro's Vite-based config loader cannot
#    resolve the bare import ("Cannot find module 'vite'"). A hoisted layout puts
#    a real node_modules/vite at the root, matching the dev volume that builds OK.
#  * NOT --prod: --prod changes hoisting and re-breaks the vite import.
# Only the BUILD stage carries these deps; the runtime stage is nginx-only.
# Call astro directly to bypass the container-only.mjs guard.
ENV TRACK_BINOCLE_IN_DOCKER=1 NODE_ENV=production
RUN pnpm install --frozen-lockfile --ignore-scripts --config.node-linker=hoisted \
 && node_modules/.bin/astro build

# ---------------------------------------------------------------------------
# Stage 2 — runtime: nginx serving static + proxying /api/* to the BaaS
# ---------------------------------------------------------------------------
FROM public.ecr.aws/docker/library/nginx:1.27-alpine AS runtime

COPY --from=build /workspace/apps/opposite-osiris/dist /usr/share/nginx/html
COPY apps/opposite-osiris/docker/services/web/default.conf.template /etc/nginx/templates/default.conf.template

# Runtime, env-driven BaaS connection. Defaults = local Docker stack service DNS.
# Override for staging/prod, e.g. -e OO_BAAS_UPSTREAM=https://baas.example.com
#   OO_AUTH_UPSTREAM  -> serves /api/auth/* and /api/newsletter/* (no path strip)
#   OO_BAAS_UPSTREAM  -> serves the rest of /api/*           (strips the /api prefix)
#   OO_RESOLVER       -> DNS for runtime upstream resolution (127.0.0.11 = Docker)
ENV OO_AUTH_UPSTREAM=http://auth-gateway:8787 \
    OO_BAAS_UPSTREAM=http://kong:8000 \
    OO_RESOLVER=127.0.0.11 \
    NGINX_ENVSUBST_FILTER=^OO_ \
    NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx/conf.d

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=5 \
  CMD wget -qO- http://127.0.0.1:8080/ >/dev/null 2>&1 || exit 1
