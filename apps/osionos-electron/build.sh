#!/usr/bin/env bash
# ===========================================================================
# Build the native osionos desktop app with ELECTRON (.deb + .AppImage).
# Chromium renderer -> fast on every OS (unlike Tauri's WebKitGTK on Linux).
#
#   bash apps/osionos-electron/build.sh            # FULL edition (HTTPS, BaaS-wired)
#   bash apps/osionos-electron/build.sh --local    # LOCAL edition (HTTP :4000, lean
#                                                  # backend, no mini-baas) -> dist-local/
#   add --win   -> also/only build a Windows .exe (NSIS) via the wine builder image
#   add --all   -> build Linux (.deb/.AppImage) AND Windows (.exe) in one pass
#   e.g.  bash apps/osionos-electron/build.sh --local --all
#
# 1. Build the STANDALONE osionos frontend (offline-capable, base=./).
# 2. Extract the dist into renderer/ and inject the shared custom titlebar.
# 3. Package with electron-builder inside a container (no host Node).
# Install:  sudo bash apps/osionos-electron/install-app.sh   (full)
#           bash apps/osionos-electron/local-edition/install.sh  (local edition)
# ===========================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"
EL="apps/osionos-electron"

# ---- edition: full (default) or local (--local) ---------------------------
# ---- platform: linux (default), --win (Windows .exe), --all (both) ---------
# Windows cross-builds from Linux via electron-builder's wine image; the
# Windows app still needs the Docker backend (Docker Desktop / WSL2) at runtime.
EDITION="full"; PLATFORM="linux"
for a in "$@"; do case "$a" in
  --local|local)      EDITION="local";;
  --win|--windows)    PLATFORM="win";;
  --all|--all-os)     PLATFORM="all";;
esac; done
case "$PLATFORM" in
  win) BUILDER_IMG="electronuserland/builder:wine"; DIST_SCRIPT="dist:win";;
  all) BUILDER_IMG="electronuserland/builder:wine"; DIST_SCRIPT="dist:all";;
  *)   BUILDER_IMG="electronuserland/builder:latest"; DIST_SCRIPT="dist";;
esac
VER="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$EL/package.json" | head -1)"

if [ "$EDITION" = "local" ]; then
  # LOCAL edition: HTTP loopback to the lean bridge. NO mini-baas — the Second Brain
  # graph runs from the note layer (bridge /api/graph/pages) and Database mode from
  # local pages (WorkspaceDatabaseBlock); empty VITE_BAAS_* keeps it from ever calling
  # the absent query-router. Real local login (portal) against the local auth-gateway.
  API_URL="http://localhost:4000"; BAAS_URL=""
  B_API_KEY=""; B_KONG_KEY=""; B_EDGES_DB=""; B_EDGES_TBL=""; B_RESOURCES=""
  B_GENERATORS=""; B_NOTES_TBL=""; B_OVERLAY_TBL=""; B_SBV2=""
  FE_TAG="osionos-electron-frontend:local"; OUT_DIR="dist-local"
  DIST_EXTRA="-- --config.directories.output=dist-local --config.extraMetadata.version=${VER}-local"
  echo "  ▶ LOCAL edition — HTTP http://localhost:4000, lean backend, no mini-baas."
else
  # The FULL bundle bakes the BaaS auth + graph wiring from the local .env (.env is
  # dockerignored, so pass it explicitly as build-args).
  ENV_FILE="apps/osionos/app/.env"
  baas_env() { [ -f "$ENV_FILE" ] && sed -n "s|^$1=||p" "$ENV_FILE" | head -1; }
  B_API_KEY="$(baas_env VITE_BAAS_API_KEY)"; B_KONG_KEY="$(baas_env VITE_BAAS_KONG_KEY)"
  B_EDGES_DB="$(baas_env VITE_BAAS_EDGES_DB_ID)"; B_EDGES_TBL="$(baas_env VITE_BAAS_EDGES_TABLE)"
  B_RESOURCES="$(baas_env VITE_BAAS_GRAPH_RESOURCES)"; B_GENERATORS="$(baas_env VITE_BAAS_GRAPH_GENERATORS)"
  B_NOTES_TBL="$(baas_env VITE_BAAS_NOTES_TABLE)"; B_OVERLAY_TBL="$(baas_env VITE_BAAS_OVERLAY_TABLE)"
  B_SBV2="$(baas_env VITE_SECOND_BRAIN_V2)"
  API_URL="https://localhost:4000"; BAAS_URL="app://osionos/__baas"
  FE_TAG="osionos-electron-frontend:latest"; OUT_DIR="dist"; DIST_EXTRA=""
  if [ -z "$B_API_KEY" ] || [ -z "$B_KONG_KEY" ]; then
    echo "  ⚠️  BaaS keys missing in $ENV_FILE — the graph/database will show 'no nodes'."
  else
    echo "  ✓ baking BaaS keys (api=${B_API_KEY:0:8}…, kong set, edges_db=${B_EDGES_DB:0:8}…)"
  fi
fi

echo "[1/4] Building standalone osionos frontend ($EDITION, base=./)…"
docker build -f infrastructure/docker/osionos/app.Dockerfile \
  --build-arg VITE_ALLOW_OFFLINE_MODE=false \
  --build-arg VITE_REQUIRE_BRIDGE_SESSION=false \
  --build-arg VITE_AUTH_MODE=portal \
  --build-arg VITE_BAAS_URL="$BAAS_URL" \
  --build-arg VITE_BAAS_API_KEY="$B_API_KEY" \
  --build-arg VITE_BAAS_KONG_KEY="$B_KONG_KEY" \
  --build-arg VITE_BAAS_EDGES_DB_ID="$B_EDGES_DB" \
  --build-arg VITE_BAAS_EDGES_TABLE="$B_EDGES_TBL" \
  --build-arg VITE_BAAS_GRAPH_RESOURCES="$B_RESOURCES" \
  --build-arg VITE_BAAS_GRAPH_GENERATORS="$B_GENERATORS" \
  --build-arg VITE_BAAS_NOTES_TABLE="$B_NOTES_TBL" \
  --build-arg VITE_BAAS_OVERLAY_TABLE="$B_OVERLAY_TBL" \
  --build-arg VITE_SECOND_BRAIN_V2="$B_SBV2" \
  --build-arg VITE_API_URL="$API_URL" \
  --build-arg VITE_MAIL_APP_URL=https://localhost:3002 \
  --build-arg VITE_CALENDAR_APP_URL=https://localhost:3003 \
  --build-arg VITE_APP_VERSION="desktop-$EDITION" \
  --build-arg VITE_BASE=./ \
  -t "$FE_TAG" apps/osionos/app

echo "[2/4] Extracting dist -> $EL/renderer …"
cid="$(docker create "$FE_TAG")"
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

echo "[4/4] Packaging with electron-builder ($PLATFORM, $BUILDER_IMG; first run pulls the image)…"
# Wine (Windows target) refuses a HOME it doesn't own — /tmp is root-owned — so give the
# builder a project-local, user-owned HOME for its wine prefix. Electron/npm caches stay in
# /tmp (sticky-writable, reused across builds, no re-download).
mkdir -p "$REPO/$EL/.builder-home"
docker run --rm --user "$(id -u):$(id -g)" \
  -e HOME=/project/.builder-home -e WINEPREFIX=/project/.builder-home/.wine \
  -e ELECTRON_CACHE=/tmp/.cache/electron -e ELECTRON_BUILDER_CACHE=/tmp/.cache/electron-builder \
  -e npm_config_cache=/tmp/.npm \
  -v "$REPO/$EL":/project -w /project \
  "$BUILDER_IMG" \
  sh -c "npm install --no-audit --no-fund && npm run $DIST_SCRIPT $DIST_EXTRA"

echo
echo "Done ($EDITION/$PLATFORM). Artifacts in $EL/$OUT_DIR/ :"
ls -1 "$EL"/"$OUT_DIR"/*.deb "$EL"/"$OUT_DIR"/*.AppImage "$EL"/"$OUT_DIR"/*.exe 2>/dev/null || true
if [ "$EDITION" = "local" ]; then
  echo "Install the local edition with:  bash apps/osionos-electron/local-edition/install.sh"
else
  echo "Install with:  sudo bash apps/osionos-electron/install-app.sh"
fi
