# osionos IDE workspace sandbox — the persistent per-(user,workspace) container
# a developer gets a real shell into. Runs on the ISOLATED rootless dind daemon
# (never the host/backend daemon — devil condition 1), joined ONLY to the
# internal sandbox network whose sole route off-box is the egress proxy.
#
# Hardening is enforced at CREATE time by the provisioner (cap_drop ALL,
# no-new-privileges, non-root, pids/mem/cpu, RLIMIT_CORE=0, inode+block quota).
# This image adds only toolchains + the PAT-broker credential helper. P3/P5
# extend it with the full language toolchains + language servers.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git python3 procps iproute2 \
    && rm -rf /var/lib/apt/lists/*

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

WORKDIR /workspace
USER coder
# Keep-alive PID 1; shells + tools attach via `docker exec`. P4 replaces this
# with the fs-agent (which also keeps the container alive).
CMD ["sleep", "infinity"]
