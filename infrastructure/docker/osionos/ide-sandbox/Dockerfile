# osionos IDE workspace sandbox — the persistent per-(user,workspace) container
# a developer gets a real shell into. Runs on the ISOLATED rootless dind daemon
# (never the host/backend daemon — devil condition 1), joined ONLY to the
# internal sandbox network whose sole route off-box is the egress proxy.
#
# Hardening is enforced at CREATE time by the provisioner (cap_drop ALL,
# no-new-privileges, non-root, pids/mem/cpu, RLIMIT_CORE=0, inode+block quota).
# This image adds the toolchains + language servers + the PAT-broker credential
# helper. Everything that needs npm/apt egress runs BEFORE the HTTP_PROXY ENV
# block below — on the build daemon the in-daemon egress proxy does not exist.
FROM debian:bookworm-slim

# Base tools + `ripgrep` (the /api/ide/search backend: `rg --json`) + node/npm
# (runs the fs-agent AND the two language servers below) + pip/venv (a real
# `pip install` is a headline sandbox use case; egress allows pypi over 443).
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git python3 python3-pip python3-venv \
      procps iproute2 ripgrep nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# Language servers (P5) — matches bridge-ide-exec.mjs LSP_SERVERS:
#   typescript → typescript-language-server --stdio
#   python     → pyright-langserver --stdio
# Global, so a `docker exec` LSP relay finds them on PATH. Major-pinned (a dev
# sandbox toolchain, not a project dependency under the release-age policy).
RUN npm install -g --no-audit --no-fund \
      typescript@5 typescript-language-server@4 pyright@1 \
    && npm cache clean --force

# PAT broker (devil condition 13): the credential helper only emits a secret
# when GIT_PAT is present in the GIT PROCESS env — which happens ONLY when the
# provisioner runs `docker exec -e GIT_PAT=… git …` per operation. The long-lived
# interactive shell never carries GIT_PAT, so `env`, `git config -l`, and every
# rc/profile reveal nothing. No credential.helper=store/cache anywhere.
RUN git config --system credential.helper \
      '!f() { test -n "$GIT_PAT" && printf "username=x-access-token\npassword=%s\n" "$GIT_PAT"; }; f' \
    && git config --system credential.useHttpPath true

# All egress flows through the in-daemon CONNECT proxy — the sandbox net is
# `internal` so there is no other route. npm/pip/cargo/go honor these.
ENV HTTP_PROXY=http://ide-egress:8080 \
    HTTPS_PROXY=http://ide-egress:8080 \
    http_proxy=http://ide-egress:8080 \
    https_proxy=http://ide-egress:8080 \
    NO_PROXY=localhost,127.0.0.1 \
    no_proxy=localhost,127.0.0.1 \
    GIT_TERMINAL_PROMPT=0

# Belt-and-suspenders no-core (the provisioner also sets RLIMIT_CORE=0 at create).
RUN printf 'ulimit -c 0\n' > /etc/profile.d/00-nocore.sh \
    && chmod 0644 /etc/profile.d/00-nocore.sh

RUN useradd --uid 10001 --create-home --shell /bin/bash coder \
    && mkdir -p /workspace && chown coder:coder /workspace

# The in-sandbox filesystem agent (P4): watches /workspace and streams
# create/modify/delete events for the gateway, applying the ignore set so a
# `pip install` never floods the page store. Launched per-session by the gateway.
COPY osio-fs-agent.mjs /usr/local/lib/osio-fs-agent.mjs

WORKDIR /workspace
USER coder
# Keep-alive PID 1; shells + tools attach via `docker exec`. P4 replaces this
# with the fs-agent (which also keeps the container alive).
CMD ["sleep", "infinity"]
