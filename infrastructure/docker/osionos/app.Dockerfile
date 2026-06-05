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

COPY . .
RUN --mount=type=cache,id=osionos-pnpm,target=/pnpm/store \
    pnpm config set store-dir /pnpm/store \
 && pnpm install --frozen-lockfile --ignore-scripts

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
ENV VITE_API_URL=$VITE_API_URL \
    VITE_PRISMATICA_URL=$VITE_PRISMATICA_URL \
    VITE_MAIL_APP_URL=$VITE_MAIL_APP_URL \
    VITE_CALENDAR_APP_URL=$VITE_CALENDAR_APP_URL \
    VITE_REQUIRE_BRIDGE_SESSION=$VITE_REQUIRE_BRIDGE_SESSION \
    VITE_ALLOW_OFFLINE_MODE=$VITE_ALLOW_OFFLINE_MODE \
    VITE_PAGE_ACTION_SYNC_ENABLED=$VITE_PAGE_ACTION_SYNC_ENABLED \
    VITE_APP_VERSION=$VITE_APP_VERSION

RUN pnpm exec vite build

FROM public.ecr.aws/docker/library/nginx:1.27-alpine AS runtime
LABEL org.opencontainers.image.title="osionos-app"
LABEL org.opencontainers.image.source="https://github.com/univers42/osionos"
# Reuse the submodule's static+SPA nginx config (listens on :80).
COPY docker/services/node/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /app/build /usr/share/nginx/html
EXPOSE 80
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=6 \
  CMD wget -qO- http://127.0.0.1/ >/dev/null 2>&1 || exit 1
