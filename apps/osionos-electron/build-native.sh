#!/usr/bin/env bash
# ===========================================================================
# osionos NATIVE edition (NO Docker at runtime) — assemble / test / package.
#
#   bash apps/osionos-electron/build-native.sh           # assemble native-runtime/ (with binaries)
#   bash apps/osionos-electron/build-native.sh --test     # + boot the whole stack end-to-end
#   bash apps/osionos-electron/build-native.sh --dist      # + build the frontend + electron-builder
#
# native-runtime/ = gateway (Node, from the prismatica image) + bridge (2 mjs) +
# native/ supervisor + models/*.sql + embedded postgres (zonky) + postgrest + the
# pure-JS `pg` client (zonky ships no psql/pg_isready, so firstrun/readiness use pg).
# Electron's own binary runs the Node children (ELECTRON_RUN_AS_NODE) — no node shipped.
# ===========================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$REPO"
EL=apps/osionos-electron; RT="$EL/native-runtime"; CACHE="$EL/.native-cache"
GW_IMAGE="${AUTH_GATEWAY_IMAGE:-dlesieur/prismatica-auth-gateway:latest}"
GOTRUE_IMAGE="${BAAS_GOTRUE_IMAGE:-public.ecr.aws/supabase/gotrue:v2.188.1}"
PG_VER="${PG_VER:-16.4.0}"; PGRST_VER="${PGRST_VER:-v12.2.3}"
MODE="${1:-}"

echo "[1/5] reset $RT"
rm -rf "$RT"; mkdir -p "$RT/gateway" "$RT/bridge" "$RT/native" "$RT/models" "$RT/pgsql" "$RT/bin"; mkdir -p "$CACHE"

echo "[2/5] extract the auth-gateway Node bundle from $GW_IMAGE"
cid="$(docker create "$GW_IMAGE")"
docker cp "$cid:/app/scripts" "$RT/gateway/scripts" >/dev/null
mkdir -p "$RT/gateway/node_modules/@mini-baas"
docker cp "$cid:/app/node_modules/@mini-baas/js" "$RT/gateway/node_modules/@mini-baas/js" >/dev/null
docker rm -f "$cid" >/dev/null

echo "[3/5] copy bridge + native modules + migrations"
cp apps/osionos/app/scripts/bridge-api.mjs apps/osionos/app/scripts/bridge-graph.mjs "$RT/bridge/"
cp "$EL"/native/firstrun.mjs "$EL"/native/restProxy.mjs "$EL"/native/supervisor.mjs \
   "$EL"/native/supervisor-run.mjs "$EL"/native/bootstrap.sql "$RT/native/"
cp models/*.sql "$RT/models/"

echo "[4/5] acquire binaries (cached in $CACHE): embedded postgres $PG_VER + postgrest $PGRST_VER"
if [ ! -f "$CACHE/pg-$PG_VER.txz" ]; then
  curl -fsSL -o "$CACHE/pg.jar" "https://repo1.maven.org/maven2/io/zonky/test/postgres/embedded-postgres-binaries-linux-amd64/${PG_VER}/embedded-postgres-binaries-linux-amd64-${PG_VER}.jar"
  rm -rf "$CACHE/pgx"; mkdir -p "$CACHE/pgx"; ( cd "$CACHE/pgx" && unzip -oq "../pg.jar" )
  mv "$CACHE/pgx"/postgres-linux-*.txz "$CACHE/pg-$PG_VER.txz"; rm -rf "$CACHE/pgx" "$CACHE/pg.jar"
fi
tar -xJf "$CACHE/pg-$PG_VER.txz" -C "$RT/pgsql"
if [ ! -f "$CACHE/postgrest-$PGRST_VER" ]; then
  curl -fsSL -o "$CACHE/pgrst.tar.xz" "https://github.com/PostgREST/postgrest/releases/download/${PGRST_VER}/postgrest-${PGRST_VER}-linux-static-x64.tar.xz"
  tar -xJf "$CACHE/pgrst.tar.xz" -C "$CACHE"; mv "$CACHE/postgrest" "$CACHE/postgrest-$PGRST_VER"; rm -f "$CACHE/pgrst.tar.xz"
fi
cp "$CACHE/postgrest-$PGRST_VER" "$RT/bin/postgrest"; chmod +x "$RT/bin/postgrest"
echo "  + gotrue (static Go binary) + its 69 migrations from $GOTRUE_IMAGE"
gid="$(docker create "$GOTRUE_IMAGE")"
docker cp "$gid:/usr/local/bin/auth" "$RT/bin/gotrue" >/dev/null; chmod +x "$RT/bin/gotrue"
mkdir -p "$RT/gotrue-migrations"; docker cp "$gid:/usr/local/etc/auth/migrations/." "$RT/gotrue-migrations/" >/dev/null
docker rm -f "$gid" >/dev/null

echo "[5/5] bundle the pure-JS pg client (zonky ships no psql)"
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e npm_config_cache=/tmp/.npm \
  -v "$REPO/$RT":/w -w /w public.ecr.aws/docker/library/node:22-bookworm-slim \
  npm install pg@8 --no-audit --no-fund --omit=dev >/dev/null 2>&1
echo "  assembled $(find "$RT" -type f | wc -l) files ($(du -sh "$RT" | cut -f1)); pg=$(ls "$RT"/pgsql/bin | tr '\n' ' ')"

# ---- --test: boot the whole stack end-to-end in one container --------------
if [ "$MODE" = "--test" ]; then
  echo "==> building the integration test image (node22 + libs; binaries come from the bundle)…"
  docker build -t osio-native-test - < "$EL/Dockerfile.native-test"
  echo "==> booting the native stack end-to-end (no docker-compose, real bundled binaries)…"
  docker rm -f osio-native-run >/dev/null 2>&1 || true
  docker run --rm --name osio-native-run -v "$REPO/$RT":/rt:ro osio-native-test
  exit 0
fi

# ---- --dist: frontend + electron-builder -----------------------------------
if [ "$MODE" = "--dist" ]; then
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
