#!/usr/bin/env bash
# ===========================================================================
# Build the native osionos desktop app with ELECTRON (.deb + .AppImage).
# Chromium renderer -> fast on every OS (unlike Tauri's WebKitGTK on Linux).
#
# 1. Build the STANDALONE osionos frontend (offline-capable, base=./, no
#    prismatica redirect) — same image build as the Tauri shell.
# 2. Extract the dist into renderer/ and inject the shared custom titlebar.
# 3. Package with electron-builder inside a container (no host Node).
#
# Run from anywhere:  bash apps/osionos-electron/build.sh
# Then install:        sudo bash apps/osionos-electron/install-app.sh
# ===========================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"
EL="apps/osionos-electron"

echo "[1/4] Building standalone osionos frontend (offline, base=./)…"
docker build -f infrastructure/docker/osionos/app.Dockerfile \
  --build-arg VITE_ALLOW_OFFLINE_MODE=true \
  --build-arg VITE_REQUIRE_BRIDGE_SESSION=false \
  --build-arg VITE_API_URL=https://localhost:4000 \
  --build-arg VITE_MAIL_APP_URL=https://localhost:3002 \
  --build-arg VITE_CALENDAR_APP_URL=https://localhost:3003 \
  --build-arg VITE_APP_VERSION=desktop \
  --build-arg VITE_BASE=./ \
  -t osionos-electron-frontend:latest apps/osionos/app

echo "[2/4] Extracting dist -> $EL/renderer …"
cid="$(docker create osionos-electron-frontend:latest)"
rm -rf "$EL/renderer" && mkdir -p "$EL/renderer"
docker cp "$cid:/usr/share/nginx/html/." "$EL/renderer/"
docker rm -f "$cid" >/dev/null

echo "[2b/4] Injecting shared custom titlebar…"
docker run --rm -v "$REPO/$EL":/d -v "$REPO/apps/osionos-desktop/chrome":/c -w /d \
  public.ecr.aws/docker/library/node:22-alpine node -e '
  const fs=require("fs"); const idx="renderer/index.html";
  let html=fs.readFileSync(idx,"utf8");
  const snip=fs.readFileSync("/c/titlebar.html","utf8");
  if(!html.includes("osio-titlebar")){ html=html.replace("</body>", snip+"\n</body>"); fs.writeFileSync(idx,html); console.log("[chrome] titlebar injected"); }
  else console.log("[chrome] already present");
'

echo "[3/4] Preparing icon…"
cp -f apps/osionos-desktop/src-tauri/icons/128x128@2x.png "$EL/icon.png" 2>/dev/null \
  || cp -f apps/osionos-desktop/src-tauri/icons/icon.png "$EL/icon.png" 2>/dev/null || true

echo "[4/4] Packaging with electron-builder (container; first run pulls the image)…"
docker run --rm --user "$(id -u):$(id -g)" \
  -e HOME=/tmp -e ELECTRON_CACHE=/tmp/.cache/electron -e ELECTRON_BUILDER_CACHE=/tmp/.cache/electron-builder \
  -e npm_config_cache=/tmp/.npm \
  -v "$REPO/$EL":/project -w /project \
  electronuserland/builder:latest \
  sh -c "npm install --no-audit --no-fund && npm run dist"

echo
echo "Done. Artifacts in $EL/dist/ :"
ls -1 "$EL"/dist/*.deb "$EL"/dist/*.AppImage 2>/dev/null || true
echo "Install with:  sudo bash apps/osionos-electron/install-app.sh"
