#!/bin/sh
set -eu

export TRACK_BINOCLE_IN_DOCKER=1
git config --global --add safe.directory /workspace 2>/dev/null || true

APP_DIR=/workspace/apps/opposite-osiris
SDK_DIR=/workspace/infrastructure/baas/sdk
STAMP_DIR="$APP_DIR/node_modules/.cache"
STAMP="$STAMP_DIR/npm-deps.sha256"
SDK_STAMP_DIR="$SDK_DIR/node_modules/.cache"
SDK_STAMP="$SDK_STAMP_DIR/npm-deps.sha256"

sdk_hash="$(cat "$SDK_DIR/package.json" "$SDK_DIR/package-lock.json" | sha256sum | awk '{print $1}')"
sdk_cached_hash=""

if [ -f "$SDK_STAMP" ]; then
  sdk_cached_hash="$(cat "$SDK_STAMP")"
fi

if [ ! -d "$SDK_DIR/node_modules" ] || [ "$sdk_cached_hash" != "$sdk_hash" ]; then
  echo "[entrypoint] Installing mini-baas SDK dependencies in Docker volume..."
  (cd "$SDK_DIR" && npm ci)
  mkdir -p "$SDK_STAMP_DIR"
  printf '%s' "$sdk_hash" > "$SDK_STAMP"
  echo "[entrypoint] SDK dependencies ready."
else
  echo "[entrypoint] SDK dependencies up to date."
fi

current_hash="$(cat package.json package-lock.json ../../infrastructure/baas/sdk/package.json ../../infrastructure/baas/sdk/package-lock.json | sha256sum | awk '{print $1}')"
cached_hash=""

cd "$APP_DIR"

if [ -f "$STAMP" ]; then
  cached_hash="$(cat "$STAMP")"
fi

if [ ! -d node_modules ] || [ "$cached_hash" != "$current_hash" ]; then
  echo "[entrypoint] Installing opposite-osiris dependencies in Docker volume..."
  npm ci
  mkdir -p "$STAMP_DIR"
  printf '%s' "$current_hash" > "$STAMP"
  echo "[entrypoint] Dependencies ready."
else
  echo "[entrypoint] Dependencies up to date."
fi

exec "$@"
