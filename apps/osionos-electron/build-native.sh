#!/usr/bin/env bash
# ===========================================================================
# osionos NATIVE edition (NO Docker at runtime) — assemble / test / package.
#
#   bash apps/osionos-electron/build-native.sh           # assemble native-runtime/
#   bash apps/osionos-electron/build-native.sh --test     # + boot the whole stack
#                                                          #   end-to-end in one container
#   bash apps/osionos-electron/build-native.sh --dist      # + acquire binaries + build the
#                                                          #   frontend + electron-builder (.deb/.AppImage)
#
# Runtime bundle = gateway (Node, from the prismatica image) + bridge (2 mjs) +
# native/ supervisor + models/*.sql + (for --dist) embedded postgres + postgrest.
# Electron's own binary runs the Node children (ELECTRON_RUN_AS_NODE), so no node ship.
# ===========================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$REPO"
EL=apps/osionos-electron; RT="$EL/native-runtime"
GW_IMAGE="${AUTH_GATEWAY_IMAGE:-dlesieur/prismatica-auth-gateway:latest}"
MODE="${1:-}"

echo "[1/3] reset $RT"
rm -rf "$RT"; mkdir -p "$RT/gateway" "$RT/bridge" "$RT/native" "$RT/models"

echo "[2/3] extract the auth-gateway Node bundle from $GW_IMAGE"
cid="$(docker create "$GW_IMAGE")"
docker cp "$cid:/app/scripts" "$RT/gateway/scripts" >/dev/null
mkdir -p "$RT/gateway/node_modules/@mini-baas"
docker cp "$cid:/app/node_modules/@mini-baas/js" "$RT/gateway/node_modules/@mini-baas/js" >/dev/null
docker rm -f "$cid" >/dev/null

echo "[3/3] copy bridge + native modules + migrations"
cp apps/osionos/app/scripts/bridge-api.mjs apps/osionos/app/scripts/bridge-graph.mjs "$RT/bridge/"
cp "$EL"/native/firstrun.mjs "$EL"/native/restProxy.mjs "$EL"/native/supervisor.mjs \
   "$EL"/native/supervisor-run.mjs "$EL"/native/bootstrap.sql "$RT/native/"
cp models/*.sql "$RT/models/"
echo "  assembled $(find "$RT" -type f | wc -l) files ($(du -sh "$RT" | cut -f1))"

# ---- --test: boot the whole stack end-to-end in one container --------------
if [ "$MODE" = "--test" ]; then
  echo "==> building the integration test image (postgres16 + node22 + postgrest)…"
  docker build -t osio-native-test - < "$EL/Dockerfile.native-test"
  echo "==> booting the native stack end-to-end (no docker-compose)…"
  docker rm -f osio-native-run >/dev/null 2>&1 || true
  docker run --rm --name osio-native-run -v "$REPO/$RT":/rt:ro osio-native-test
  exit 0
fi

# ---- --dist: acquire binaries + frontend + electron-builder ----------------
if [ "$MODE" = "--dist" ]; then
  PG_VER="${PG_VER:-16.4.0}"; PGRST_VER="${PGRST_VER:-v12.2.3}"
  mkdir -p "$RT/pgsql" "$RT/bin" "$RT/.dl"
  echo "==> [bin] embedded postgres $PG_VER (linux-amd64, self-contained)…"
  curl -fsSL -o "$RT/.dl/pg.jar" "https://repo1.maven.org/maven2/io/zonky/test/postgres/embedded-postgres-binaries-linux-amd64/${PG_VER}/embedded-postgres-binaries-linux-amd64-${PG_VER}.jar"
  ( cd "$RT/.dl" && unzip -oq pg.jar && tar -xJf postgres-linux-*.txz -C "$REPO/$RT/pgsql" )
  echo "==> [bin] postgrest $PGRST_VER (linux static)…"
  curl -fsSL -o "$RT/.dl/pgrst.tar.xz" "https://github.com/PostgREST/postgrest/releases/download/${PGRST_VER}/postgrest-${PGRST_VER}-linux-static-x64.tar.xz"
  tar -xJf "$RT/.dl/pgrst.tar.xz" -C "$RT/bin"
  rm -rf "$RT/.dl"
  echo "   postgres: $("$RT/pgsql/bin/postgres" --version 2>/dev/null || echo '??'); postgrest: $("$RT/bin/postgrest" --help >/dev/null 2>&1 && echo ok || echo '??')"

  echo "==> [fe] building the native frontend (talks to the bridge on 127.0.0.1:4000)…"
  docker build -f infrastructure/docker/osionos/app.Dockerfile \
    --build-arg VITE_ALLOW_OFFLINE_MODE=false --build-arg VITE_REQUIRE_BRIDGE_SESSION=false \
    --build-arg VITE_AUTH_MODE=portal --build-arg VITE_BAAS_URL="" \
    --build-arg VITE_API_URL="http://127.0.0.1:4000" --build-arg VITE_APP_VERSION="desktop-native" \
    --build-arg VITE_BASE=./ -t osionos-electron-frontend:native apps/osionos/app
  cid2="$(docker create osionos-electron-frontend:native)"; rm -rf "$EL/renderer"; mkdir -p "$EL/renderer"
  docker cp "$cid2:/usr/share/nginx/html/." "$EL/renderer/"; docker rm -f "$cid2" >/dev/null
  docker run --rm -v "$REPO/$EL":/d -v "$REPO/apps/osionos-desktop/chrome":/c -w /d \
    public.ecr.aws/docker/library/node:22-alpine node -e '
    const fs=require("fs"); const idx="renderer/index.html"; let h=fs.readFileSync(idx,"utf8");
    const s=fs.readFileSync("/c/titlebar.html","utf8");
    if(!h.includes("osio-titlebar")){fs.writeFileSync(idx,h.replace("</body>",s+"\n</body>"));console.log("[chrome] titlebar injected");}'
  cp -f apps/osionos-desktop/src-tauri/icons/128x128@2x.png "$EL/icon.png" 2>/dev/null || true

  echo "==> [pkg] electron-builder (native config, extraResources=native-runtime)…"
  VER="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$EL/package.json" | head -1)"
  mkdir -p "$EL/.builder-home"
  docker run --rm --user "$(id -u):$(id -g)" \
    -e HOME=/project/.builder-home -e ELECTRON_CACHE=/tmp/.cache/electron -e ELECTRON_BUILDER_CACHE=/tmp/.cache/electron-builder -e npm_config_cache=/tmp/.npm \
    -v "$REPO/$EL":/project -w /project electronuserland/builder:latest \
    sh -c "npm install --no-audit --no-fund && npm run dist:native -- --config.extraMetadata.version=${VER}-native"
  echo "Done. Native artifacts in $EL/dist-native/ :"
  ls -1 "$EL"/dist-native/*.deb "$EL"/dist-native/*.AppImage 2>/dev/null || true
  exit 0
fi

echo "done (assembly only). Re-run with --test (boot e2e) or --dist (build the app)."
