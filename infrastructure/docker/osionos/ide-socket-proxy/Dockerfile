# osionos IDE docker-socket proxy — the only path from the provisioner to the
# isolated dind daemon. Fronts the dind unix socket (shared volume) and exposes
# a filtered TCP endpoint. Runs read-only, non-root (compose adds the socket's
# group via OSIONOS_IDE_DOCKER_GID), on the control net only — never a sandbox net.
FROM node:22-bookworm-slim

WORKDIR /app
COPY proxy.mjs /app/proxy.mjs
COPY create-shape.mjs /app/create-shape.mjs
COPY init-shape.mjs /app/init-shape.mjs
COPY uid-ledger.mjs /app/uid-ledger.mjs
COPY uid-endpoint.mjs /app/uid-endpoint.mjs
COPY json-guard.mjs /app/json-guard.mjs
COPY audit.mjs /app/audit.mjs
COPY escalation-denylist.mjs /app/escalation-denylist.mjs
COPY runtime-pin.mjs /app/runtime-pin.mjs
COPY volume-shape.mjs /app/volume-shape.mjs
# verify.sh runs `node /app/proxy.mjs --selfcheck` in this image, which imports its cases.
COPY create-shape.selfcheck.mjs /app/create-shape.selfcheck.mjs
COPY uid-ledger.selfcheck.mjs /app/uid-ledger.selfcheck.mjs
COPY json-guard.selfcheck.mjs /app/json-guard.selfcheck.mjs

# The owner<->uid ledger lives on a named volume mounted here (compose: osionos-ide-ledger). A fresh
# volume copies this directory's owner, so `node` can write it; the image itself stays read-only.
RUN mkdir /ledger && chown node:node /ledger

USER node

EXPOSE 2375
CMD ["node", "/app/proxy.mjs"]
