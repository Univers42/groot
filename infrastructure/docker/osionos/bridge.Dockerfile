# syntax=docker/dockerfile:1.7
# ============================================================================
# osionos-bridge — workspace persistence layer (the osionos "gateway").
#
# Pure Node (built-ins + the sibling bridge-graph.mjs) — NO npm deps, NO build.
# Brokers the editor's reads/writes to the BaaS and consumes the bridge session
# minted by the api-gateway. Secrets/config injected at RUNTIME via env.
#
# Built from the osionos submodule WITHOUT modifying it (context = the submodule):
#   docker build -f infrastructure/docker/osionos/bridge.Dockerfile \
#     -t dlesieur/osionos-bridge ./apps/osionos/app
# ============================================================================
FROM public.ecr.aws/docker/library/node:22-bookworm-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app

# The bridge server + its standalone route modules (only runtime files it
# needs): graph projection, LiveKit tokens (rtc), permission UX proxy (perms),
# and the social plane (chat/profile/feed + their shared core).
COPY scripts/bridge-api.mjs scripts/bridge-graph.mjs scripts/bridge-rtc.mjs \
	scripts/bridge-perms.mjs scripts/bridge-chat.mjs scripts/bridge-profile.mjs \
	scripts/bridge-feed.mjs scripts/bridge-social-core.mjs ./scripts/

USER node
EXPOSE 4000

HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=6 \
  CMD node -e "fetch('http://127.0.0.1:4000/api/auth/bridge/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "scripts/bridge-api.mjs"]
