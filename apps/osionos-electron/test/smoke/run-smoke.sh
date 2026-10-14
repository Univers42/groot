#!/bin/sh
# Usage: run-smoke.sh full|local|native
# Ponytail: the BaaS target defaults to 127.0.0.1:8000, where nothing listens on this host, so
# full-edition BaaS calls are offline unless OSIONOS_BAAS_URL points at a live Kong.
set -eu
EDITION="${1:-full}"
HERE="$(cd "$(dirname "$0")" && pwd)"
E_DIR="$(cd "$HERE/../.." && pwd)"
REPO="$(cd "$E_DIR/../.." && pwd)"
IMG=osionos-electron-smoke:1.49.1
OUT="${SMOKE_OUT:-/tmp/osionos-electron-smoke-out}"

case "$EDITION" in
full) ;;
local) echo "SKIP local — needs a lean backend on :4000 over plain HTTP; :4000 is the live HTTPS bridge (a second one would touch the live stack)"; exit 0 ;;
native) echo "SKIP native — needs native-runtime/ from build-native.sh (embedded postgres+gotrue, heavy); not built here"; exit 0 ;;
*) echo "usage: $0 full|local|native" >&2; exit 2 ;;
esac

[ -f "$E_DIR/renderer/index.html" ] || bash "$E_DIR/build.sh" --renderer-only
# shellcheck source=/dev/null
. "$REPO/scripts/lib/demo-login.sh"
pw="$(demo_login_password "$REPO/.env.local")"
mkdir -p "$OUT"
docker build -q -t "$IMG" "$HERE" >/dev/null

# watch.sh backgrounds its child, which detaches fd 0 (stdin = /dev/null); fd 3 survives. The
# password rides a 0700 fifo -> fd 3 -> docker-run.sh stdin, so it is never in an argv or on disk.
fifo_dir="$(mktemp -d)"
trap 'rm -rf "$fifo_dir"' EXIT
mkfifo "$fifo_dir/pw"
printf '%s' "$pw" >"$fifo_dir/pw" &
exec 3<"$fifo_dir/pw"
export E_DIR HERE REPO IMG OUT DEMO_LOGIN_EMAIL
"$REPO/.claude/tools/watch.sh" --timeout 900 --idle 300 -- sh "$HERE/docker-run.sh"
