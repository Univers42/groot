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
#     --build-arg GRAPH_RENDER_SHA="$(git ls-tree HEAD apps/graph_render | awk '{print $3}')" \
#     -t track-binocle/osionos-web:local ./apps/osionos/app
#
# It also serves graph_render's published pack under /graph-studio/<GRAPH_RENDER_SHA>/ and
# names that base in index.html (<meta name="graph-studio-base">). GRAPH_RENDER_SHA is groot's
# apps/graph_render gitlink; make's recipes pass it, a raw build must too. The build fails
# unless the pinned pack was built from exactly that commit.
# ============================================================================

# The only place the pack is pinned. Bump it with the apps/graph_render pointer, in one commit:
# a pack whose pack.json source_rev is not the gitlink fails the runtime stage below.
# Ponytail: the served path is keyed by source_rev, not by this digest. A pack rebuilt from the
# same commit (new toolchain, new digest) lands at an unchanged URL that browsers cache as
# immutable for a year, so they keep the old bytes. Never bump the digest alone: a same-commit
# rebuild needs its own path first.
ARG GRAPH_STUDIO_PACK=ghcr.io/univers42/graph-studio-pack@sha256:13349d726600165b57abb2c128c66aac67bfa456634b1ee88ff25e04cdc6792a
FROM ${GRAPH_STUDIO_PACK} AS graph-studio-pack

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
# IDE / Dev-Mode surface. featureFlags.ts reads it via a COMPUTED
# import.meta.env[key], which is populated only from .env FILES (see the
# .env.production.local write below), not the Dockerfile ENV. Empty = OFF.
ARG VITE_OSIO_IDE=
ARG VITE_APP_VERSION=image
# Auth mode: "portal" makes the app show its own login/sign-up portal (no mock,
# no website redirect). Empty = legacy bridge/offline behavior (web image).
ARG VITE_AUTH_MODE=
# BaaS query API (kong), as the BROWSER must reach it — vite inlines this at build
# time and liveRealtimeUrl() derives the realtime socket from it (http->ws), so a
# value only the docker host can resolve strands every client off-box. Default is
# the APP'S OWN origin: the proxy also mounts Kong's /auth/v1 /rest/v1 /realtime/v1
# /storage/v1 /query/v1 /meta/v1 on :3001, so ONE reachable port serves the whole
# app and no extra port has to be tunnelled/forwarded. Kong's own 127.0.0.1:8000
# is docker-host loopback plain HTTP and is NOT a valid browser origin here.
ARG VITE_BAAS_URL=https://localhost:3001
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
# VITE_BAAS_TENANT_ID scopes registry discovery (`X-Baas-Tenant-Id` header —
# /admin/v1/databases 401s without it and returns every tenant's mounts).
ARG VITE_BAAS_LIVE_MOUNTS=
ARG VITE_BAAS_REALTIME_TOKEN=
ARG VITE_BAAS_TENANT_ID=
ARG VITE_CHAT_WS=true
# Giphy search key (GIPHY_API in .env.local). Public beta-style key, client-side
# by design; empty = the GIF picker shows a "not configured" toast.
ARG VITE_GIPHY_API_KEY=
# osionos's build-time gate for the legacy second brain (src/shared/config/legacySecondBrain.ts;
# vite.config.ts `define` reads it from the build env). "false" = every second-brain entry
# point opens graph_render's <graph-studio>, served below under /graph-studio/<sha>/.
# Rollback: build with VITE_LEGACY_SECOND_BRAIN=true (only the vite build reruns).
ARG VITE_LEGACY_SECOND_BRAIN=false
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
    VITE_BAAS_REALTIME_TOKEN=$VITE_BAAS_REALTIME_TOKEN \
    VITE_BAAS_TENANT_ID=$VITE_BAAS_TENANT_ID \
    VITE_LEGACY_SECOND_BRAIN=$VITE_LEGACY_SECOND_BRAIN

# vite's import.meta.env OBJECT (whole-object reads in the vendored realtime
# plane + wsTransport) is populated ONLY from .env FILES, not the Dockerfile ENV,
# and the host .env is .dockerignored. Write the realtime build env here so
# liveRealtimeUrl()/resolveLiveRealtimeToken() get a non-empty VITE_BAAS_URL +
# valid token and the chat WebSocket actually connects.
RUN printf 'VITE_BAAS_URL=%s\nVITE_BAAS_REALTIME_TOKEN=%s\nVITE_CHAT_WS=%s\nVITE_GIPHY_API_KEY=%s\nVITE_OSIO_IDE=%s\n' \
      "$VITE_BAAS_URL" "$VITE_BAAS_REALTIME_TOKEN" "$VITE_CHAT_WS" "$VITE_GIPHY_API_KEY" "$VITE_OSIO_IDE" > .env.production.local

# Build, then strip source maps from the shipped image (they tripled its size
# and leak source; keep them only in local builds) and precompress static
# assets so nginx's gzip_static serves them with zero CPU per request.
# The app outgrew Node's default ~2 GiB heap during rollup's render phase —
# raise the cap (it's a ceiling, not a reservation).
RUN NODE_OPTIONS=--max-old-space-size=4096 pnpm exec vite build --base "$VITE_BASE" \
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

# ^~ outranks the regex asset location and keeps `location /` (the SPA fallback) out: a missing
# pack file is a 404, never index.html, which would reach WebAssembly.compile as HTML. The path
# is versioned by commit, so every file under it is immutable.
COPY <<'NGINX' /etc/nginx/graph-studio.conf
location ^~ /graph-studio/ {
  expires 1y;
  add_header Cache-Control "public, immutable";
  try_files $uri =404;
}
NGINX

ARG GRAPH_RENDER_SHA=
COPY --from=graph-studio-pack /pack/ /usr/share/nginx/html/graph-studio/${GRAPH_RENDER_SHA}/
# Ponytail: both seds match osionos's text — the `server {` line of its nginx.conf and the single
# `</head>` of the built index.html. If osionos reformats either, the count check fails the build
# (loud, never a silent miss); fix the pattern here. source_rev is read with sed too, so a
# pack.json not written one key per line (studio-pack.sh's format) also fails the build.
RUN <<'CHECK'
set -eu
fail() { echo "[graph-studio] $*" >&2; exit 1; }
fix="build through make (frontends-up, update_web, osionos-app-live), or export GRAPH_RENDER_SHA=\$(git ls-tree HEAD apps/graph_render | awk '{print \$3}')"
case "$GRAPH_RENDER_SHA" in
  *[!0-9a-f]* | '') fail "GRAPH_RENDER_SHA must be the apps/graph_render gitlink (40 hex), got '$GRAPH_RENDER_SHA' — $fix" ;;
esac
[ "${#GRAPH_RENDER_SHA}" -eq 40 ] || fail "GRAPH_RENDER_SHA must be the apps/graph_render gitlink (40 hex), got '$GRAPH_RENDER_SHA' — $fix"
html=/usr/share/nginx/html
pack=$html/graph-studio/$GRAPH_RENDER_SHA
rev=$(sed -n 's/^ *"source_rev": *"\([0-9a-f]*\)".*/\1/p' "$pack/pack.json")
[ "$rev" = "$GRAPH_RENDER_SHA" ] || fail "pack source_rev ${rev:-<none>} is not the expected $GRAPH_RENDER_SHA — bump GRAPH_STUDIO_PACK in app.Dockerfile with the apps/graph_render pointer"
gzip -9k "$pack"/*.js "$pack"/*.wasm
sed -i '/^server {$/a\  include /etc/nginx/graph-studio.conf;' /etc/nginx/conf.d/default.conf
[ "$(grep -c 'include /etc/nginx/graph-studio.conf;' /etc/nginx/conf.d/default.conf)" -eq 1 ] || fail "could not add the /graph-studio/ location to osionos's nginx.conf"
sed -i "s|</head>|<meta name=\"graph-studio-base\" content=\"/graph-studio/$GRAPH_RENDER_SHA/\" />\n</head>|" "$html/index.html"
[ "$(grep -o 'name="graph-studio-base"' "$html/index.html" | wc -l)" -eq 1 ] || fail "could not add the graph-studio-base meta to index.html"
nginx -t
CHECK
EXPOSE 80
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=6 \
  CMD wget -qO- http://127.0.0.1/ >/dev/null 2>&1 || exit 1
