#!/usr/bin/env bash
# ===========================================================================
# Build the native osionos desktop app (.deb + .AppImage).
#
# 1. Build a STANDALONE osionos frontend — VITE_ALLOW_OFFLINE_MODE=true so it
#    opens as the pure editor (NO prismatica/landing redirect): it auto-connects
#    to the local BaaS as the seed user when up, and runs offline otherwise.
# 2. Extract that dist and bundle it into the Tauri app.
# 3. Build the Tauri bundles in the container (no host Rust/Node).
#
# Run from anywhere: bash apps/osionos-desktop/build.sh
# Then install: sudo bash apps/osionos-desktop/install-app.sh
# ===========================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

echo "[1/3] Building standalone osionos frontend (offline-capable, no prismatica redirect)…"
docker build -f infrastructure/docker/osionos/app.Dockerfile \
  --build-arg VITE_ALLOW_OFFLINE_MODE=true \
  --build-arg VITE_REQUIRE_BRIDGE_SESSION=false \
  --build-arg VITE_API_URL=https://localhost:4000 \
  --build-arg VITE_MAIL_APP_URL=https://localhost:3002 \
  --build-arg VITE_CALENDAR_APP_URL=https://localhost:3003 \
  --build-arg VITE_APP_VERSION=desktop \
  --build-arg VITE_BASE=./ \
  -t osionos-desktop-frontend:latest apps/osionos/app

echo "[2/3] Extracting osionos dist -> apps/osionos-desktop/build…"
cid="$(docker create osionos-desktop-frontend:latest)"
rm -rf apps/osionos-desktop/build && mkdir -p apps/osionos-desktop/build
docker cp "$cid:/usr/share/nginx/html/." apps/osionos-desktop/build/
docker rm -f "$cid" >/dev/null

echo "[2b/3] Injecting custom window chrome (titlebar) into the bundle…"
docker run --rm -v "$REPO/apps/osionos-desktop":/d -w /d public.ecr.aws/docker/library/node:22-alpine node -e '
  const fs=require("fs");
  const idx="build/index.html";
  let html=fs.readFileSync(idx,"utf8");
  const snip=fs.readFileSync("chrome/titlebar.html","utf8");
  if(!html.includes("osio-titlebar")) { html=html.replace("</body>", snip+"\n</body>"); fs.writeFileSync(idx,html); console.log("[chrome] titlebar injected"); }
  else console.log("[chrome] already present");
'

echo "[3/3] Building the Tauri app (.deb + .AppImage)…"
docker run --rm --user "$(id -u):$(id -g)" \
  -e HOME=/tmp -e CARGO_HOME=/tmp/cargo -e APPIMAGE_EXTRACT_AND_RUN=1 \
  -v "$REPO":/work -w /work/apps/osionos-desktop \
  track-binocle/tauri-build:latest \
  cargo tauri build --bundles deb appimage

echo
echo "Done. Install with:  sudo bash apps/osionos-desktop/install-app.sh"
