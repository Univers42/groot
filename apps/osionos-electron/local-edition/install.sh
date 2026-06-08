#!/usr/bin/env bash
# ===========================================================================
# osionos LOCAL edition — one-command install for another Ubuntu machine.
#
# Brings up the LEAN local backend (DB + auth + pages over HTTP :4000; NO TLS,
# NO mini-baas, NO website/mail/calendar) using images PULLED from Docker Hub
# (no source build on this machine), then installs the desktop app.
#
# Prerequisites on the target:
#   - Ubuntu x86-64 (22.04 or 24.04), Docker Engine + compose plugin, internet.
#   - This repo present (it carries the lean compose + the local-secret scripts +
#     DB migrations). No Fly Vault, no certs, no Node/pnpm needed.
#
# Usage:  bash apps/osionos-electron/local-edition/install.sh
# ===========================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO"

echo "==> osionos local edition installer"

# 1) Docker present, daemon reachable, compose plugin available?
if ! command -v docker >/dev/null 2>&1; then
  echo "✗ Docker is required but not installed. Install Docker Engine first:"
  echo "    https://docs.docker.com/engine/install/ubuntu/"
  echo "  then add yourself to the docker group:  sudo usermod -aG docker \$USER  (re-login after)."
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "✗ Docker is installed but the daemon isn't reachable. Common fixes:"
  echo "    - start it:           sudo systemctl start docker"
  echo "    - permission denied:  sudo usermod -aG docker \$USER  (then log out/in)"
  exit 1
fi
docker compose version >/dev/null 2>&1 || {
  echo "✗ The Docker Compose plugin is required (the 'docker compose ...' subcommand)."
  echo "    https://docs.docker.com/compose/install/linux/"
  exit 1
}
echo "✓ Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) ready."

# 2) Pull the lean backend from Docker Hub (override the local-build image tags so
#    nothing is built on this machine).
export BAAS_POSTGRES_IMAGE="${BAAS_POSTGRES_IMAGE:-dlesieur/track-binocle-postgres:latest}"
export BAAS_KONG_IMAGE="${BAAS_KONG_IMAGE:-dlesieur/track-binocle-mini-baas-kong:latest}"
export OSIONOS_BRIDGE_IMAGE="${OSIONOS_BRIDGE_IMAGE:-dlesieur/osionos-bridge:latest}"
export AUTH_GATEWAY_IMAGE="${AUTH_GATEWAY_IMAGE:-dlesieur/prismatica-auth-gateway:latest}"
LEAN="postgres redis kong pg-meta gotrue postgrest mailpit auth-gateway osionos-bridge"
echo "==> Pulling lean backend images from Docker Hub…"
COMPOSE_PROFILES=local docker compose -f docker-compose.yml -f docker-compose.local.yml pull $LEAN || true

# 3) Bring up the lean stack (generates local secrets, HTTP :4000, no TLS/cloud).
echo "==> Starting the lean local stack (make local)…"
if ! make local; then
  echo "✗ 'make local' failed to bring up the backend. Inspect with:"
  echo "    docker compose -f docker-compose.yml -f docker-compose.local.yml --profile local ps"
  echo "    docker compose -f docker-compose.yml -f docker-compose.local.yml --profile local logs --tail=50"
  exit 1
fi

# 4) Install the desktop app (local edition artifacts live in dist-local/).
DIST="apps/osionos-electron/dist-local"
# Auto-build the local-edition app if it isn't here yet (one-command experience).
if [ -z "$(ls "$DIST"/*.AppImage "$DIST"/*.deb 2>/dev/null || true)" ]; then
  echo "==> No local-edition app artifact found — building it (build.sh --local)…"
  bash apps/osionos-electron/build.sh --local
fi
DEB="$(ls -t "$DIST"/osionos-desktop_*_amd64.deb 2>/dev/null | head -1 || true)"
APPIMG="$(ls -t "$DIST"/osionos-*.AppImage 2>/dev/null | head -1 || true)"
if [ -n "$DEB" ]; then
  echo "==> Installing $DEB (needs sudo)…"
  sudo dpkg -i "$DEB" || sudo apt-get install -y -f || sudo dpkg -i --force-depends "$DEB"
  # Electron's chrome-sandbox must be setuid root (Ubuntu 24.04 userns restriction).
  [ -f /opt/osionos/chrome-sandbox ] && sudo chown root:root /opt/osionos/chrome-sandbox && sudo chmod 4755 /opt/osionos/chrome-sandbox || true
  echo "==> Done. Launch 'osionos' from your app menu (talks to http://localhost:4000)."
elif [ -n "$APPIMG" ]; then
  chmod +x "$APPIMG" || true
  echo "==> Done. Run the app:  $APPIMG"
  echo "    (Ubuntu 24.04: if it won't launch, use  $APPIMG --appimage-extract-and-run  or install libfuse2t64.)"
else
  echo "No local-edition artifact found in $DIST. Build it first:  bash apps/osionos-electron/build.sh --local"
fi

echo "==> Backend status:"
docker compose -f docker-compose.yml -f docker-compose.local.yml ps --format '{{.Service}}\t{{.Status}}' 2>/dev/null || true
echo "    Stop the stack:   docker compose -f docker-compose.yml -f docker-compose.local.yml --profile local down"
