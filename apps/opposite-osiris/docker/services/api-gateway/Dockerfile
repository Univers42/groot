# syntax=docker/dockerfile:1.7
# ============================================================================
# prismatica-auth-gateway — the custom API gateway / auth BFF.
#
# Runs scripts/auth-gateway.mjs: the secure server-side broker between the
# website's account model and the app. It holds SERVER-ONLY secrets
# (SERVICE_ROLE_KEY, OSIONOS_BRIDGE_SHARED_SECRET, TURNSTILE_SECRET_KEY, SMTP)
# which are injected at RUNTIME via env — NEVER baked into this image.
#
# It talks to: BaaS/Kong (auth + privileged DB ops via service role), the
# osionos-bridge (mints the osionos session that connects an account to the
# app), Cloudflare Turnstile, and SMTP.
#
# Build context = repository ROOT (needs the @mini-baas/js SDK source):
#   docker build -f apps/opposite-osiris/docker/services/api-gateway/Dockerfile \
#     -t dlesieur/prismatica-auth-gateway .
# ============================================================================

# ---------------------------------------------------------------------------
# Stage 1 — build the @mini-baas/js SDK (the gateway's only npm dependency)
# ---------------------------------------------------------------------------
FROM public.ecr.aws/docker/library/node:22-alpine AS build
RUN corepack enable && corepack prepare pnpm@11.5.1 --activate
WORKDIR /sdk
COPY apps/baas/sdk/ ./
RUN pnpm install --frozen-lockfile --ignore-scripts \
 && pnpm run build

# ---------------------------------------------------------------------------
# Stage 2 — lean runtime: node + the BFF script + email templates + SDK
# ---------------------------------------------------------------------------
FROM public.ecr.aws/docker/library/node:22-alpine AS runtime
ENV NODE_ENV=production
WORKDIR /app

# The gateway code, and the email templates it reads at runtime relative to
# process.cwd() (resolve(process.cwd(), 'src/email-templates')).
COPY apps/opposite-osiris/scripts/auth-gateway.mjs ./scripts/auth-gateway.mjs
COPY apps/opposite-osiris/src/email-templates/ ./src/email-templates/

# The only runtime dependency: the built SDK (it has NO transitive npm deps),
# placed where Node resolves a bare `@mini-baas/js` import from /app.
COPY --from=build /sdk/package.json ./node_modules/@mini-baas/js/package.json
COPY --from=build /sdk/dist/ ./node_modules/@mini-baas/js/dist/

# node:22-alpine ships a non-root `node` user (UID 1000) — run as it.
USER node
EXPOSE 8787

# Secrets/config arrive via env at runtime; only the port is assumed here.
HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=6 \
  CMD node -e "fetch('http://127.0.0.1:8787/api/auth/availability').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "scripts/auth-gateway.mjs"]
