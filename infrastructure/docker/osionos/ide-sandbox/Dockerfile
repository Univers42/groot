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
# Go and gopls come from the official golang image, not go.dev/dl: dl.google.com
# and proxy.golang.org's toolchain downloads answer 403/404 on some networks
# (measured 2026-10-13), while module downloads still work. Go and gopls are pinned
# together because an unpinned gopls@latest outgrew the Go here (v0.23.0 needs
# go >= 1.26) and made go fetch a toolchain. CGO_ENABLED=0 keeps gopls static: the
# golang image is trixie and this sandbox is bookworm. GOTOOLCHAIN=local turns a
# future mismatch into a plain "requires go" error instead of a download.
FROM golang:1.26.9 AS gotools
ARG GOPLS_VERSION=v0.23.0
RUN CGO_ENABLED=0 GOTOOLCHAIN=local GOBIN=/out go install "golang.org/x/tools/gopls@${GOPLS_VERSION}"

FROM debian:bookworm-slim

# Base tools + `ripgrep` (the /api/ide/search backend: `rg --json`) + node/npm
# (runs the fs-agent AND the two language servers below) + pip/venv (a real
# `pip install` is a headline sandbox use case; egress allows pypi over 443).
# Base tools + compile toolchains for a real multi-language dev shell:
#   gcc/g++/clang/make → C/C++    rustc/cargo → Rust    default-jdk → Java
#   clangd → the C/C++ language server (P5).  Go + its LSP land below (tarball).
# openssh-client is there for `ssh-keygen -Y verify` against ~/.ssh/allowed_signers (P5-3-c). Its
# setuid ssh-keysign and setgid ssh-agent are stripped: the box uses neither, and the setuid count
# asserted at the end stays the one measured without them.
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git python3 python3-pip python3-venv \
      procps iproute2 ripgrep nodejs npm openssh-client \
      gcc g++ clang clangd make rustc cargo default-jdk-headless \
    && chmod a-s /usr/lib/openssh/ssh-keysign /usr/bin/ssh-agent \
    && rm -rf /var/lib/apt/lists/*

# Language servers (P5) — matches bridge-ide-exec.mjs LSP_SERVERS:
#   typescript → typescript-language-server --stdio
#   python     → pyright-langserver --stdio
#   java       → jdtls-launch (wrapper that starts Eclipse JDT LS on stdio)
# Global, so a `docker exec` LSP relay finds them on PATH. Major-pinned (a dev
# sandbox toolchain, not a project dependency under the release-age policy).
RUN npm install -g --no-audit --no-fund \
      typescript@5 typescript-language-server@4 pyright@1 \
    && npm cache clean --force

# 42 school work: valgrind and gdb for leak and crash hunts, readline's headers for
# minishell, norminette for the norm, strace for gnlTester's `make m` (exit 127 without
# it; tracing its own child needs no capability under the default seccomp profile).
# A libft built in this sandbox on 2026-10-14 found none of them. norminette lives in its own venv: bookworm's pip refuses a
# system-wide install (PEP 668). norminette 3.3.60 (built 2026-08-29) has no
# dependencies, so one hash pins the whole install.
RUN apt-get update && apt-get install -y --no-install-recommends \
      valgrind gdb libreadline-dev strace \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/norminette \
    && echo "norminette==3.3.60 --hash=sha256:c963ff9ff11180351f19b2f7e26a734bba8ee601a4a0c5e8f8f4a807770cf285" > /tmp/norminette.req \
    && /opt/norminette/bin/pip install --no-cache-dir --require-hashes --only-binary :all: -r /tmp/norminette.req \
    && rm /tmp/norminette.req \
    && ln -s /opt/norminette/bin/norminette /usr/local/bin/norminette

# Compiled-language language servers (P5, extended) — matches bridge-ide-exec.mjs
# LSP_SERVERS: go → gopls, rust → rust-analyzer, c/cpp → clangd (from apt above),
# java → jdtls-launch. Go and gopls come from the gotools stage above (bookworm
# apt Go is too old); rust-analyzer ships a self-contained release binary; JDT LS
# needs a Java 21 runtime (separate from the user's Java 17 JDK). All downloads
# need egress and MUST stay ABOVE the HTTP_PROXY ENV block below (on the build
# daemon the in-daemon egress proxy does not exist yet).
COPY --from=gotools /usr/local/go /usr/local/go
COPY --from=gotools /out/gopls /usr/local/bin/gopls
ENV PATH="/usr/local/go/bin:${PATH}" GOTOOLCHAIN=local
# Symlink go/gofmt into /usr/local/bin: the interactive sandbox shell is `bash -l`,
# whose /etc/profile resets PATH and drops the ENV addition above — but keeps
# /usr/local/bin. Without this, `go` is "command not found" in the terminal.
RUN ln -s /usr/local/go/bin/go /usr/local/bin/go \
    && ln -s /usr/local/go/bin/gofmt /usr/local/bin/gofmt

# Temurin JRE 21.0.12.1+1 (built 2026-08-19) — Eclipse JDT LS requires Java 21
# runtime (eclipse.jdt.ls README line 45). User `java` stays 17 from default-jdk.
# sha256: 2413149700df0f7d440500a84a8f764c535f21e5a5e87d38328b64eec2c5b500
RUN curl -fsSL "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jre_x64_linux_hotspot_21.0.12.1_1.tar.gz" \
      -o /tmp/jre21.tar.gz \
    && echo "2413149700df0f7d440500a84a8f764c535f21e5a5e87d38328b64eec2c5b500  /tmp/jre21.tar.gz" | sha256sum -c - \
    && mkdir -p /opt/jre21 \
    && tar --no-same-owner -xzf /tmp/jre21.tar.gz -C /opt/jre21 --strip-components=1 \
    && rm /tmp/jre21.tar.gz

# Eclipse JDT LS 1.61.0 (built 2026-09-03; 1.62.0 is too new under the 14-day
# release-age rule). sha256: 338e7e73d61836651ba2453919a0d34fa763eb4e7c03342092309bffb8934c64
RUN curl -fsSL "https://download.eclipse.org/jdtls/milestones/1.61.0/jdt-language-server-1.61.0-202609031315.tar.gz" \
      -o /tmp/jdtls.tar.gz \
    && echo "338e7e73d61836651ba2453919a0d34fa763eb4e7c03342092309bffb8934c64  /tmp/jdtls.tar.gz" | sha256sum -c - \
    && mkdir -p /opt/jdtls \
    && tar --no-same-owner -xzf /tmp/jdtls.tar.gz -C /opt/jdtls \
    && rm /tmp/jdtls.tar.gz
# The launcher jar name carries a build qualifier; resolve it to a fixed path so
# jdtls-launch never globs at runtime. Zero or several matches fail the build.
RUN set -- /opt/jdtls/plugins/org.eclipse.equinox.launcher_*.jar; \
    if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then \
      echo "jdtls: expected exactly 1 equinox launcher jar, found: $*" >&2; exit 1; \
    fi; \
    ln -s "$1" /opt/jdtls/launcher.jar

# rust-analyzer 2026-09-28 (built 2026-09-28), pinned by digest: `releases/latest`
# with no checksum let any upstream re-publish land in the image unchecked.
ARG RUST_ANALYZER_VERSION=2026-09-28
ARG RUST_ANALYZER_SHA256=23f711d86b5f826e22886f01d7355dc01e0f4c1357dafa29710a95b903b48c85
RUN curl -fsSL "https://github.com/rust-lang/rust-analyzer/releases/download/${RUST_ANALYZER_VERSION}/rust-analyzer-x86_64-unknown-linux-gnu.gz" \
      -o /tmp/rust-analyzer.gz \
    && echo "${RUST_ANALYZER_SHA256}  /tmp/rust-analyzer.gz" | sha256sum -c - \
    && gunzip -c /tmp/rust-analyzer.gz > /usr/local/bin/rust-analyzer \
    && chmod +x /usr/local/bin/rust-analyzer \
    && rm /tmp/rust-analyzer.gz

# Python debug adapter (S5-D): debugpy 1.8.22 (built 2026-09-15) has no dependencies, so
# one hash pins the install; the bridge's DAP relay runs `debugpy-adapter` on stdio. A
# breakpoint was hit through it on this image's Python 3.11 on 2026-10-14. Node debugging
# is not here: js-debug needs Node >= 20 (the image has 18) and the startDebugging request.
RUN echo "debugpy==1.8.22 --hash=sha256:192b73e8d53bbd60225220c0943627bf249ac93d0ea3090e23c45f3e0ceb6a35" > /tmp/debugpy.req \
    && python3 -m pip install --no-cache-dir --require-hashes --only-binary :all: --no-deps \
         --target /opt/debugpy -r /tmp/debugpy.req \
    && rm /tmp/debugpy.req
COPY debugpy-adapter.sh /usr/local/bin/debugpy-adapter
RUN chmod 755 /usr/local/bin/debugpy-adapter

# A terminal that feels like a computer: tmux to survive a dropped tab, less as the pager, man
# for the manual. Debian's slim dpkg config drops /usr/share/man, so man-db alone would find no
# page; the drop-in re-admits man pages for this layer, and the base tools' pages (excluded when
# they were first installed) are reinstalled. The drop-in is removed so later installs keep the
# slim behaviour. Needs egress: it must stay above the HTTP_PROXY ENV block.
RUN echo 'path-include=/usr/share/man/*' > /etc/dpkg/dpkg.cfg.d/zz-man \
    && apt-get update && apt-get install -y --no-install-recommends \
      tmux less man-db manpages manpages-dev \
    && apt-get install -y --no-install-recommends --reinstall \
      bash coreutils findutils grep sed tar gzip diffutils \
    && rm -f /etc/dpkg/dpkg.cfg.d/zz-man \
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

# User-space toolchain defaults for login shells (comments in the file). Root-owned and 0644: /etc
# stays unwritable for the box user. conda-forge is micromamba's only default channel.
COPY user-space.profile.sh /etc/profile.d/10-user-space.sh
COPY conda.condarc /etc/conda/.condarc
RUN chmod 0644 /etc/profile.d/10-user-space.sh /etc/conda/.condarc

RUN useradd --uid 10001 --create-home --shell /bin/bash coder \
    && mkdir -p /workspace && chown coder:coder /workspace

# Login shell choice without /etc: `chsh -s` saves a path under ~/.config/osio and osio-login (the
# PTY Cmd) starts it, else bash. The setuid /usr/bin/chsh cannot work here (read-only /etc,
# no-new-privileges), so it is removed and the shim shadows nothing. The persistent home volume
# at /home/coder is what makes the choice outlive a box.
COPY osio-shell.sh /usr/local/lib/osio-shell.sh
COPY osio-login.sh /usr/local/bin/osio-login
COPY osio-chsh.sh /usr/local/bin/chsh
RUN rm -f /usr/bin/chsh \
    && chmod 0644 /usr/local/lib/osio-shell.sh \
    && chmod 0755 /usr/local/bin/osio-login /usr/local/bin/chsh \
    && ! find / -xdev -name chsh -perm /6000 -print | grep -q .

# The ownership init (ADR 0011): the ide-server runs this image with this entrypoint before every
# box create, to give a user's two volumes to that user's uid. Never the box's own entrypoint.
COPY osio-volume-init.sh /usr/local/sbin/osio-volume-init
RUN chmod 0755 /usr/local/sbin/osio-volume-init

# The in-sandbox filesystem agent (P4): watches /workspace and streams
# create/modify/delete events for the gateway, applying the ignore set so a
# `pip install` never floods the page store. Launched per-session by the gateway.
COPY osio-fs-agent.mjs /usr/local/lib/osio-fs-agent.mjs
# The ignore set is what keeps build output, dependency trees and half-written saves out of
# the page store: an image whose matcher is wrong must not build.
RUN node /usr/local/lib/osio-fs-agent.mjs --selfcheck

# jdtls-launch wrapper: speaks LSP on stdio, invoked by the bridge via
# /api/ide/lsp?lang=java. Must be on PATH for the relay.
COPY jdtls-launch.sh /usr/local/bin/jdtls-launch
RUN chmod 755 /usr/local/bin/jdtls-launch

# box-init: PID 1 (see ENTRYPOINT and box-init.c), built with the image's own gcc.
COPY box-init.c /tmp/box-init.c
RUN gcc -Wall -Wextra -Werror -O2 -o /usr/local/sbin/box-init /tmp/box-init.c && rm /tmp/box-init.c

# docker-ide runs userns-remap with a 65536-id range: one file owned outside it makes
# `docker load` fail on the VM (jdtls's tarball once shipped uid 1001380000).
RUN if find / -xdev \( -uid +65535 -o -gid +65535 \) -print -quit | grep -q .; then \
      echo "files owned outside the userns-remap range:" >&2; \
      find / -xdev \( -uid +65535 -o -gid +65535 \) | head -5 >&2; exit 1; \
    fi

# Opt-in (--build-arg STRIP_SETUID=1): a box for anyone but the operator needs zero setuid/setgid
# entries (devil R8, ADR 0022 stage 1); the operator image keeps its measured baseline of 7. Setgid
# directories (/usr/local/*, /var/mail) count too, so the strip covers every type. Default 0 changes
# no file in the image.
ARG STRIP_SETUID=0
RUN if [ "$STRIP_SETUID" = 1 ]; then \
      find / -xdev -perm /6000 -exec chmod a-s {} + \
      && test -z "$(find / -xdev -perm /6000)"; \
    fi

# The box's account file lives on the box's /tmp tmpfs so the terminal can show the user's own
# name (ADR 0009). The link is the LAST step: from here on, root lookups in a build RUN fail.
# It is safe only because the box runs with no-new-privileges, CapDrop ALL, a read-only rootfs
# and a numeric User; with any of them gone, a user-written passwd plus a setuid binary gives
# root in the box. The build asserts what it can: the link, one 10001 account, no new setuid.
# box-init and osio-login copy passwd.base at run time, swapping the coder line's 10001 uid for the
# box's own, so that line is the template they match: keep it exactly as asserted here.
# SETUID_BASELINE is the count measured on 2026-10-17 (7) plus one of headroom.
ARG SETUID_BASELINE=8
RUN cp /etc/passwd /etc/passwd.base \
    && test "$(grep -c ':10001:' /etc/passwd.base)" = 1 \
    && grep -q '^coder:x:10001:10001:' /etc/passwd.base \
    && ln -sf /tmp/.osio/passwd /etc/passwd \
    && test "$(readlink /etc/passwd)" = /tmp/.osio/passwd \
    && test "$(find / -xdev -perm -4000 -type f | wc -l)" -le "${SETUID_BASELINE}"

WORKDIR /workspace
# Numeric: dockerd resolves a user name against the image's own passwd, which now points at a
# file that does not exist before the box starts. This is only the image's default: every box is
# created with its owner's "<uid>:10001" (20000-59999, ADR 0011) and the socket proxy refuses any
# other User, 10001:10001 included, so no box runs as the account baked in above.
USER 10001:10001
# PID 1 is box-init: it reaps every orphan (with `sleep infinity` as PID 1, hellish's `make -j8`
# left 469 zombies and every fork failed, 2026-10-14) and, unlike tini, cannot be stopped from
# inside the box (tini exits when its child dies: `pkill -x sleep` stopped the box). The Cmd
# stays `sleep infinity`, as its child: the socket proxy requires that Cmd (create-shape.mjs).
# Shells and tools attach via `docker exec`.
ENTRYPOINT ["/usr/local/sbin/box-init"]
CMD ["sleep", "infinity"]
