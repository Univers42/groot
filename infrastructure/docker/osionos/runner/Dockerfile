# osionos IDE code runner — hardened multi-language execution sandbox.
#
# The CONTAINER is the sandbox (nsjail can't create namespaces under cap_drop:ALL
# on this host — apparmor_restrict_unprivileged_userns=1). Hardening lives in the
# compose service: cap_drop ALL, no-new-privileges, read_only rootfs, internal
# network (no egress), non-root, pids/mem/cpu/ulimits, tmpfs /work. Docker's
# default seccomp+apparmor stay ON. This image only provides toolchains + the
# trusted runner server; it holds NO secrets and joins NO backend network.
#
# node:22 base = the server runtime AND JavaScript/TypeScript execution
# (--experimental-strip-types). Add a language = one apt package + a LANGS entry
# in server.mjs.
FROM node:22-bookworm-slim

# Toolchains for every language the runner's LANGS map declares runnable, so a
# language never shows as runnable in the UI but fails with "... : not found".
# node (js/ts) comes from the base image; the rest are one apt package each.
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 \
      gcc \
      g++ \
      default-jdk-headless \
      ca-certificates \
      black \
      clang-format \
      ruby \
      php-cli \
      lua5.4 \
      perl \
      golang-go \
      rustc \
    && ln -s /usr/bin/lua5.4 /usr/local/bin/lua \
    && rm -rf /var/lib/apt/lists/*

# Non-root runtime user. /work is the mount point for a compose tmpfs (writable
# scratch under an otherwise read-only rootfs).
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin runner \
    && mkdir -p /work

WORKDIR /app
COPY server.mjs /app/server.mjs

USER runner
EXPOSE 7900
# --disable-sigusr1: user code runs as this same uid and may signal PID 1. Node's default
# SIGUSR1 action starts the inspector on 127.0.0.1:9229, which that same code could then
# attach to — taking over the server that brokers every user's runs. Measured before this
# flag: one `kill -USR1 1` from uid 10001 → "Debugger listening". (Node >= 22.14.)
CMD ["node", "--disable-sigusr1", "/app/server.mjs"]
