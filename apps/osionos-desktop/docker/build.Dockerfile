# syntax=docker/dockerfile:1.7
# ===========================================================================
# Tauri build environment for the osionos desktop app.
#
# Builds the native Linux app IN A CONTAINER (no host Rust/Node needed —
# honors the Docker-first rule). The produced .AppImage/.deb runs on the host,
# which needs the WebKitGTK/GTK RUNTIME libs (one-time `sudo apt install` —
# see apps/osionos-desktop/README.md).
#
# Tauri v2 toolchain: Rust + Node + WebKitGTK 4.1 + libsoup3 + appindicator +
# AppImage tooling. Build context = repo root.
# ===========================================================================
FROM docker.io/library/node:22-bookworm-slim AS node-toolchain

FROM docker.io/library/rust:1-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    APPIMAGE_EXTRACT_AND_RUN=1

# Tauri v2 system dependencies (Debian Bookworm ships webkit2gtk-4.1 + soup3).
RUN apt-get update && apt-get install -y --no-install-recommends \
      libwebkit2gtk-4.1-dev \
      libgtk-3-dev \
      libayatana-appindicator3-dev \
      librsvg2-dev \
      libsoup-3.0-dev \
      libssl-dev \
      pkg-config \
      build-essential \
      curl \
      file \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*


# Node 22 for the osionos (Vite) frontend build + create-tauri-app. From the official image, on the
# same Debian release: the nodesource setup script this replaces ran unverified in a root shell.
COPY --from=node-toolchain /usr/local/bin/node /usr/local/bin/node
COPY --from=node-toolchain /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=node-toolchain /usr/local/include/node /usr/local/include/node
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && ln -s ../lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack \
 && corepack enable

# Tauri v2 CLI (pinned to v2 line).
RUN cargo install tauri-cli --version "^2.0" --locked

WORKDIR /work

# build.sh runs this image with --user "$(id -u):$(id -g)", which overrides this; a run without it
# gets an unprivileged user too.
USER 1000:1000
