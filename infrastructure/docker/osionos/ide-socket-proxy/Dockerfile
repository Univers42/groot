# osionos IDE docker-socket proxy — the only path from the provisioner to the
# isolated dind daemon. Fronts the dind unix socket (shared volume) and exposes
# a filtered TCP endpoint. Runs read-only, non-root (in the docker group so it
# can read the shared socket), on the control net only — never a sandbox net.
FROM node:22-bookworm-slim

WORKDIR /app
COPY proxy.mjs /app/proxy.mjs

EXPOSE 2375
CMD ["node", "/app/proxy.mjs"]
