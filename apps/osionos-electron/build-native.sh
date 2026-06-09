#!/usr/bin/env bash
# ===========================================================================
# Assemble the osionos NATIVE-edition runtime bundle (no Docker at runtime):
#   gateway (Node bundle extracted from the prismatica image) + bridge (2 mjs)
#   + native/ supervisor modules + models/*.sql  ->  native-runtime/
#
#   bash apps/osionos-electron/build-native.sh           # assemble only
#   bash apps/osionos-electron/build-native.sh --test    # + build test image + boot the
#                                                         #   whole stack end-to-end (no compose)
#
# (Binary acquisition — embedded postgres + the PostgREST release — and the
#  electron-builder packaging live in the --dist path, added next.)
# ===========================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$REPO"
EL=apps/osionos-electron; RT="$EL/native-runtime"
GW_IMAGE="${AUTH_GATEWAY_IMAGE:-dlesieur/prismatica-auth-gateway:latest}"

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

if [ "${1:-}" != "--test" ]; then
  echo "done (assembly only). Re-run with --test to boot the stack end-to-end."
  exit 0
fi

echo "==> building the integration test image (postgres16 + node22 + postgrest)…"
docker build -t osio-native-test - < "$EL/Dockerfile.native-test"
echo "==> booting the native stack end-to-end (no docker-compose)…"
docker rm -f osio-native-run >/dev/null 2>&1 || true
docker run --rm --name osio-native-run -v "$REPO/$RT":/rt:ro osio-native-test
