# osionos IDE docker-socket proxy — the only path from the provisioner to the
# isolated dind daemon. Fronts the dind unix socket (shared volume) and exposes
# a filtered TCP endpoint. Runs read-only, non-root (compose adds the socket's
# group via OSIONOS_IDE_DOCKER_GID), on the control net only — never a sandbox net.
FROM node:22-bookworm-slim

WORKDIR /app
COPY proxy.mjs /app/proxy.mjs
COPY create-shape.mjs /app/create-shape.mjs
# verify.sh runs `node /app/proxy.mjs --selfcheck` in this image, which imports its cases.
COPY create-shape.selfcheck.mjs /app/create-shape.selfcheck.mjs

USER node

EXPOSE 2375
CMD ["node", "/app/proxy.mjs"]
