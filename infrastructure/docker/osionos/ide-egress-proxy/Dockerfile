# osionos IDE egress proxy — the sole off-box route for a sandbox.
#
# Hardened like the sandbox itself (devil condition 7): the compose service runs
# it cap_drop ALL, no-new-privileges, read-only rootfs, non-root. It joins ONLY
# the internal proxy-net (sandbox side) + a single egress net — never mini-baas,
# default, or the runner net. Node built-ins only; no npm install, no secrets.
FROM node:22-bookworm-slim

RUN useradd --uid 10002 --create-home --shell /usr/sbin/nologin egress
WORKDIR /app
COPY proxy.mjs /app/proxy.mjs

USER egress
EXPOSE 8080
CMD ["node", "/app/proxy.mjs"]
