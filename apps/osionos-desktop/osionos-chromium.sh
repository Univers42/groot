#!/usr/bin/env bash
# ===========================================================================
# osionos-chromium.sh — run the standalone osionos in a CHROMIUM app-window.
#
# Why: the Tauri desktop app renders with WebKitGTK, whose compositor is slow
# for inner-container scrolling on many Linux setups (your profile showed ~27fps
# / 200-600% compositor CPU). Chromium renders the exact same app at ~60fps
# (your Playwright bench confirmed it). This serves the bundled offline osionos
# and opens it as a frameless app-window — native-feeling, but Chromium-fast.
#
# Run:  bash apps/osionos-desktop/osionos-chromium.sh
# ===========================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR="$REPO/apps/osionos-desktop/build"
PORT="${OSIONOS_PORT:-8899}"

[ -f "$DIR/index.html" ] || { echo "Build missing — run: bash apps/osionos-desktop/build.sh"; exit 1; }

# Best-effort: bring the local BaaS up (same as the Tauri app does).
( cd "$REPO" && docker compose --profile dev up -d >/dev/null 2>&1 & ) || true

# Static server for the bundled osionos.
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$DIR" >/dev/null 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null || true' EXIT
sleep 1

BROWSER="$(command -v google-chrome || command -v google-chrome-stable || command -v chromium || command -v chromium-browser)"
echo "Opening osionos in $BROWSER (Chromium app-window)…"
"$BROWSER" \
  --app="http://127.0.0.1:$PORT" \
  --user-data-dir="$HOME/.config/osionos-chromium" \
  --class=osionos --name=osionos \
  --enable-gpu-rasterization --ignore-gpu-blocklist \
  >/dev/null 2>&1
