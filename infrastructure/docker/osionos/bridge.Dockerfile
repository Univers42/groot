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
#     -t track-binocle/osionos-bridge:local ./apps/osionos/app
# ============================================================================
FROM public.ecr.aws/docker/library/node:22-bookworm-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app

# The bridge server and every module it loads. All of them are named bridge-*.mjs or ide-*.mjs,
# so globs replace the hand-kept list: app 08418d7f added bridge-realtime-socket.mjs and
# ide-volume-init.mjs, the list lacked both, and the bridge crash-looped on ERR_MODULE_NOT_FOUND
# (groot main, CI run 39089475219). scripts/tests/bridge-image-closure.bats walks the import
# closure of bridge-api.mjs and fails on any module these globs (minus the .dockerignore) miss.
COPY scripts/bridge-*.mjs scripts/ide-*.mjs ./scripts/
# When the osionos pin includes bridge-moderation.mjs it also includes
# scripts/moderation-lists/ (the module reads them at import via new URL).
# The current pin (redesign/bridge-auth) has neither; COPY of a missing path
# fails the Fresh-Machine Migration job. Re-add the line when the pin advances:
#   COPY scripts/moderation-lists/ ./scripts/moderation-lists/

USER node
EXPOSE 4000

HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=6 \
  CMD node -e "fetch('http://127.0.0.1:4000/api/auth/bridge/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "scripts/bridge-api.mjs"]
