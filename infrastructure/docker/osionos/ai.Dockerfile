# syntax=docker/dockerfile:1.7
# ============================================================================
# osionos-ai — the AI assistant service (the osionos "AI service").
#
# A stateless Node service: conversations, runs, the OpenAI-compatible gateway.
# Its production dependencies are installed with pnpm (the version pinned in
# its own package.json, through corepack); the service itself runs from the
# TypeScript sources, which Node strips itself — there is NO build step and NO
# compiler in the image. Secrets/config injected at RUNTIME via env (the
# app-session secret, the database URL, the Redis URL, the upstream).
#
# The runtime keeps the repository layout the imports expect: the service's
# sources live in /app/services/osionos-ai/src and reach the bridge modules
# they import through /app/scripts (../../../scripts/bridge-session-token.mjs
# from services/osionos-ai/src/auth.ts, ../../../../scripts/bridge-page-read.mjs
# from services/osionos-ai/src/runs/prompt.ts). Twelve of those modules are the
# IMPORT CLOSURE of services/osionos-ai/src into scripts/ — bridge-session-token
# imports bridge-session-cutoff (which imports bridge-baas-body), and since the
# account platform's P0-4 also bridge-session-revocations and bridge-roles; both
# revocations and cutoff import bridge-session-tracker, which imports
# bridge-access-generation. Share rules (retrieval/shareRules.ts) call
# bridge-page-access, which calls bridge-share-rules:
#   services/osionos-ai/src/auth.ts        -> scripts/bridge-session-token.mjs
#                                           -> scripts/bridge-session-cutoff.mjs
#                                           -> scripts/bridge-baas-body.mjs
#                                           -> scripts/bridge-session-revocations.mjs
#                                           -> scripts/bridge-roles.mjs
#                                           -> scripts/bridge-session-tracker.mjs
#                                           -> scripts/bridge-access-generation.mjs
#   services/osionos-ai/src/runs/prompt.ts -> scripts/bridge-page-read.mjs
#   services/osionos-ai/src/retrieval/acl.ts -> scripts/bridge-live-workspaces.mjs
#   services/osionos-ai/src/retrieval/shareRules.ts -> scripts/bridge-page-access.mjs
#                                           -> scripts/bridge-share-rules.mjs
#   services/osionos-ai/src/retrieval/related.ts -> scripts/bridge-graph-edges.mjs -> scripts/bridge-page-read.mjs
# The thirteenth is the L0 gate of the image prompt (devil C72): the module reads
# its lists next to itself, so they travel with it:
#   scripts/bridge-moderation.mjs          -> scripts/moderation-lists/{en,fr,es}.txt
# They are named one by one below, so a new import that is not copied fails at
# boot with ERR_MODULE_NOT_FOUND instead of running half-configured.
#
# Built from the osionos submodule WITHOUT modifying it (context = the submodule):
#   docker build -f infrastructure/docker/osionos/ai.Dockerfile \
#     -t track-binocle/osionos-ai:local ./apps/osionos/app
# ============================================================================
FROM public.ecr.aws/docker/library/node:22-bookworm-slim AS deps
# pnpm is not in the image: corepack provides the exact version the service's
# package.json pins (pnpm@10.32.1) and refuses to run a different one.
ENV PNPM_HOME=/pnpm
ENV PATH=$PNPM_HOME:$PATH
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
WORKDIR /app/services/osionos-ai
RUN corepack enable
# Only the two files the lockfile is checked against. The lockfile is the
# service's own (services/osionos-ai/pnpm-lock.yaml), not the app's.
COPY services/osionos-ai/package.json services/osionos-ai/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile --prod

FROM public.ecr.aws/docker/library/node:22-bookworm-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app

# The installed production dependencies, exactly as pnpm laid them out (the
# virtual store is inside node_modules, so the whole tree travels).
COPY --from=deps /app/services/osionos-ai/node_modules ./services/osionos-ai/node_modules
# The service itself: its manifest, its sources. No tests, no dev deps.
COPY services/osionos-ai/package.json services/osionos-ai/tsconfig.json ./services/osionos-ai/
COPY services/osionos-ai/src ./services/osionos-ai/src
# The thirteen bridge modules (see the header): the twelve of the import closure
# and the gate of the image prompt. scripts/tests/bridge-image-closure.bats checks
# this list against the closure, so a new import fails CI, not the container.
COPY scripts/bridge-session-token.mjs scripts/bridge-session-cutoff.mjs scripts/bridge-baas-body.mjs scripts/bridge-session-revocations.mjs scripts/bridge-session-tracker.mjs scripts/bridge-access-generation.mjs scripts/bridge-roles.mjs scripts/bridge-page-read.mjs scripts/bridge-page-access.mjs scripts/bridge-share-rules.mjs scripts/bridge-live-workspaces.mjs scripts/bridge-graph-edges.mjs scripts/bridge-moderation.mjs ./scripts/
# The lists of the L0 gate: the module reads them next to itself, at import.
COPY scripts/moderation-lists ./scripts/moderation-lists

USER node
EXPOSE 4300

HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=6 \
  CMD node -e "fetch('http://127.0.0.1:4300/api/ai/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

WORKDIR /app/services/osionos-ai
CMD ["node","--experimental-strip-types","src/server.ts"]
