# syntax=docker/dockerfile:1.7
# ============================================================================
# osionos-app — the block editor SPA, as a standalone static image.
#
# Builds the Vite app (build/) and serves it via nginx (static + SPA fallback,
# using the submodule's own nginx.conf). The editor talks to the osionos-bridge
# cross-origin at VITE_API_URL (no /api proxy needed in this image).
#
# Built from the osionos submodule WITHOUT modifying it (context = the submodule).
# NOTE: the submodule's docker/services/node/Dockerfile.prod runs
# `pnpm run build` -> `bash scripts/docker-run.sh build`, but doesn't COPY that
# script; the real build is just `vite build`, which we invoke directly here.
#   docker build -f infrastructure/docker/osionos/app.Dockerfile \
#     -t dlesieur/osionos-app ./apps/osionos/app
# ============================================================================
FROM public.ecr.aws/docker/library/node:22-alpine AS builder
ENV PNPM_HOME=/pnpm
ENV PATH=$PNPM_HOME:$PATH
RUN corepack enable && corepack prepare pnpm@10.32.1 --activate
WORKDIR /app

# Manifests first: the dependency install stays cached across source edits
# (with COPY . . before it, every source change re-ran the full pnpm install).
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
RUN --mount=type=cache,id=osionos-pnpm,target=/pnpm/store \
    pnpm config set store-dir /pnpm/store \
 && pnpm install --frozen-lockfile --ignore-scripts

COPY . .

# Vite inlines VITE_* at build time. Defaults target the local pipeline
# (bridge at :4000, website at :4322); the committed .env supplies the rest.
ARG VITE_API_URL=https://localhost:4000
ARG VITE_PRISMATICA_URL=https://localhost:4322
ARG VITE_MAIL_APP_URL=https://localhost:3002
ARG VITE_CALENDAR_APP_URL=https://localhost:3003
ARG VITE_REQUIRE_BRIDGE_SESSION=true
ARG VITE_ALLOW_OFFLINE_MODE=false
ARG VITE_PAGE_ACTION_SYNC_ENABLED=true
ARG VITE_APP_VERSION=image
# Auth mode: "portal" makes the app show its own login/sign-up portal (no mock,
# no website redirect). Empty = legacy bridge/offline behavior (web image).
ARG VITE_AUTH_MODE=
# BaaS query API (kong). Default matches the .env; the desktop build overrides to
# https://localhost:8000 so the secure app:// window isn't mixed-content/redirect blocked.
ARG VITE_BAAS_URL=http://127.0.0.1:8000
# Asset base. Web/nginx image keeps "/" (absolute). The desktop bundle passes
# "./" so assets resolve relative to index.html inside the Tauri webview.
ARG VITE_BASE=/
# BaaS auth + graph wiring. The DESKTOP build bakes these from the local .env so
# the graph + database surfaces can reach the mini-baas query API; the web image
# leaves them empty (runtime backend-config). Empty defaults = web build unchanged.
ARG VITE_BAAS_API_KEY=
ARG VITE_BAAS_KONG_KEY=
ARG VITE_BAAS_EDGES_DB_ID=
ARG VITE_BAAS_EDGES_TABLE=
ARG VITE_BAAS_GRAPH_RESOURCES=
ARG VITE_BAAS_GRAPH_GENERATORS=
ARG VITE_BAAS_NOTES_TABLE=
ARG VITE_BAAS_OVERLAY_TABLE=
ARG VITE_SECOND_BRAIN_V2=
# Live-database mode (notion-database-sys × mini-baas): the mount catalog
# fallback (admin listing is internal-only, browsers can't reach it) and the
# realtime WS token minted by `make seed-live-demo`. Empty = feature dormant.
ARG VITE_BAAS_LIVE_MOUNTS=
ARG VITE_BAAS_REALTIME_TOKEN=
ENV VITE_API_URL=$VITE_API_URL \
    VITE_PRISMATICA_URL=$VITE_PRISMATICA_URL \
    VITE_MAIL_APP_URL=$VITE_MAIL_APP_URL \
    VITE_CALENDAR_APP_URL=$VITE_CALENDAR_APP_URL \
    VITE_REQUIRE_BRIDGE_SESSION=$VITE_REQUIRE_BRIDGE_SESSION \
    VITE_ALLOW_OFFLINE_MODE=$VITE_ALLOW_OFFLINE_MODE \
    VITE_PAGE_ACTION_SYNC_ENABLED=$VITE_PAGE_ACTION_SYNC_ENABLED \
    VITE_AUTH_MODE=$VITE_AUTH_MODE \
    VITE_BAAS_URL=$VITE_BAAS_URL \
    VITE_APP_VERSION=$VITE_APP_VERSION \
    VITE_BAAS_API_KEY=$VITE_BAAS_API_KEY \
    VITE_BAAS_KONG_KEY=$VITE_BAAS_KONG_KEY \
    VITE_BAAS_EDGES_DB_ID=$VITE_BAAS_EDGES_DB_ID \
    VITE_BAAS_EDGES_TABLE=$VITE_BAAS_EDGES_TABLE \
    VITE_BAAS_GRAPH_RESOURCES=$VITE_BAAS_GRAPH_RESOURCES \
    VITE_BAAS_GRAPH_GENERATORS=$VITE_BAAS_GRAPH_GENERATORS \
    VITE_BAAS_NOTES_TABLE=$VITE_BAAS_NOTES_TABLE \
    VITE_BAAS_OVERLAY_TABLE=$VITE_BAAS_OVERLAY_TABLE \
    VITE_SECOND_BRAIN_V2=$VITE_SECOND_BRAIN_V2 \
    VITE_BAAS_LIVE_MOUNTS=$VITE_BAAS_LIVE_MOUNTS \
    VITE_BAAS_REALTIME_TOKEN=$VITE_BAAS_REALTIME_TOKEN

# Build, then strip source maps from the shipped image (they tripled its size
# and leak source; keep them only in local builds) and precompress static
# assets so nginx's gzip_static serves them with zero CPU per request.
RUN pnpm exec vite build --base "$VITE_BASE" \
 && find build -name '*.map' -delete \
 && find build -type f \( -name '*.js' -o -name '*.css' -o -name '*.svg' \
      -o -name '*.json' -o -name '*.wasm' \) -size +1k -print0 \
    | xargs -0 -P "$(nproc)" -n 16 gzip -9k

FROM public.ecr.aws/docker/library/nginx:1.27-alpine AS runtime
LABEL org.opencontainers.image.title="osionos-app"
LABEL org.opencontainers.image.source="https://github.com/univers42/osionos"
# Reuse the submodule's static+SPA nginx config (listens on :80).
COPY docker/services/node/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /app/build /usr/share/nginx/html
EXPOSE 80
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=6 \
  CMD wget -qO- http://127.0.0.1/ >/dev/null 2>&1 || exit 1
