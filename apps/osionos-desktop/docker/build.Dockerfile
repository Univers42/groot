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

# Node 22 for the osionos (Vite) frontend build + create-tauri-app.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && corepack enable

# Tauri v2 CLI (pinned to v2 line).
RUN cargo install tauri-cli --version "^2.0" --locked

WORKDIR /work
