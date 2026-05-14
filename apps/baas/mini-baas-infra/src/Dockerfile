# syntax=docker/dockerfile:1.7
# File: src/Dockerfile
# Unified NestJS multi-stage Dockerfile for all mini-BaaS apps.
# Build a specific app via: docker build --build-arg APP=adapter-registry src/

ARG NODE_VERSION=20
ARG APP=adapter-registry

# ─── Stage 1: Install ALL dependencies (dev + prod) ──────────────
FROM public.ecr.aws/docker/library/node:${NODE_VERSION}-alpine AS deps
WORKDIR /app
COPY --link package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
  npm ci --ignore-scripts --prefer-offline --no-audit --no-fund

# ─── Stage 2: Build the specific app ─────────────────────────────
FROM deps AS build
ARG APP
COPY --link tsconfig.json tsconfig.build.json nest-cli.json ./
COPY --link libs/ ./libs/
COPY --link apps/${APP}/ ./apps/${APP}/
RUN npx nest build ${APP}

# ─── Stage 3: Prune to production dependencies ───────────────────
FROM deps AS prod-deps
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
  npm prune --omit=dev --ignore-scripts --no-audit --no-fund

# ─── Stage 4: Production image ───────────────────────────────────
FROM public.ecr.aws/docker/library/node:${NODE_VERSION}-alpine AS runtime
ARG APP
ENV NODE_ENV=production \
  APP_NAME=${APP}

RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app

# Copy production-only deps without a second registry install.
COPY --from=prod-deps --chown=appuser:appgroup /app/node_modules ./node_modules
COPY --from=prod-deps --chown=appuser:appgroup /app/package.json /app/package-lock.json ./

# Copy compiled output
COPY --from=build --chown=appuser:appgroup --chmod=0555 /app/dist/ ./dist/

USER appuser

# Default CMD — nest build outputs to dist/apps/<APP>/apps/<APP>/src/main.js
CMD ["sh", "-c", "node dist/apps/${APP_NAME}/apps/${APP_NAME}/src/main.js"]
