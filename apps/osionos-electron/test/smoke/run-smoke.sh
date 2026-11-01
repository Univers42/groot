#!/bin/sh
# Usage: run-smoke.sh full|local|native|machine|pty|terminal
# machine: the C23 /machine run; needs a running osionos-node on 127.0.0.1:4100 and MACHINE_FOLDER,
# and waits for the emailed step-up code in $SMOKE_OUT/code.txt.
# Ponytail: the BaaS target is the grobase the build baked (desktop-config.json), else
# 127.0.0.1:8000, where nothing may listen; BaaS calls are then offline unless OSIONOS_BAAS_URL
# points at a live Kong.
set -eu
EDITION="${1:-full}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# SMOKE_APP_DIR: a built shell elsewhere (with renderer/ and node_modules/), e.g. a branch build.
E_DIR="${SMOKE_APP_DIR:-$(cd "$HERE/../.." && pwd)}"
REPO="$(cd "$HERE/../../../.." && pwd)"
IMG=osionos-electron-smoke:1.49.1
OUT="${SMOKE_OUT:-/tmp/osionos-electron-smoke-out}"

ENTRY=container-entry.sh
SMOKE_SCRIPT=pty-smoke.mjs
LIMITS="--timeout 900 --idle 300"
case "$EDITION" in
full) ;;
# Caveat: the run is silent while it waits for the owner's code, so its idle limit covers that wait.
machine) ENTRY=machine-entry.sh; LIMITS="--timeout 2400 --idle 1800"; : "${MACHINE_FOLDER:?MACHINE_FOLDER must name a folder on this machine}" ;;
local) echo "SKIP local — needs a lean backend on :4000 over plain HTTP; :4000 is the live HTTPS bridge (a second one would touch the live stack)"; exit 0 ;;
# pty: the local terminal (devil verdict 2026-10-31, C1-C8); the API exists before sign-in.
pty) ENTRY=pty-entry.sh; LIMITS="--timeout 600 --idle 300" ;;
# terminal: VS Code's terminal page in the panel's frame (ADR 0038, amendment A1-A6).
terminal) ENTRY=pty-entry.sh; SMOKE_SCRIPT=terminal-page-smoke.mjs; LIMITS="--timeout 600 --idle 300" ;;
native) echo "SKIP native — needs native-runtime/ from build-native.sh (embedded postgres+gotrue, heavy); not built here"; exit 0 ;;
*) echo "usage: $0 full|local|native|machine|pty|terminal" >&2; exit 2 ;;
esac

[ -f "$E_DIR/renderer/index.html" ] || bash "$E_DIR/build.sh" --renderer-only
if [ "$EDITION" = pty ] || [ "$EDITION" = terminal ]; then
	mkdir -p "$OUT"
	docker build -q -t "$IMG" "$HERE" >/dev/null
	export E_DIR HERE REPO IMG OUT ENTRY SMOKE_SCRIPT
	exec "$REPO/.claude/tools/watch.sh" $LIMITS -- sh "$HERE/docker-run.sh" 3</dev/null
fi
# shellcheck source=/dev/null
. "$REPO/scripts/lib/demo-login.sh"
# SMOKE_ENV_FILE: another file holding DEMO_LOGIN_PASSWORD, for an account other than this
# machine's demo login (a remote data center's).
pw="$(demo_login_password "${SMOKE_ENV_FILE:-$REPO/.env.local}")"
mkdir -p "$OUT"
docker build -q -t "$IMG" "$HERE" >/dev/null

# watch.sh backgrounds its child, which detaches fd 0 (stdin = /dev/null); fd 3 survives. The
# password rides a 0700 fifo -> fd 3 -> docker-run.sh stdin, so it is never in an argv or on disk.
fifo_dir="$(mktemp -d)"
trap 'rm -rf "$fifo_dir"' EXIT
mkfifo "$fifo_dir/pw"
printf '%s' "$pw" >"$fifo_dir/pw" &
exec 3<"$fifo_dir/pw"
export E_DIR HERE REPO IMG OUT DEMO_LOGIN_EMAIL ENTRY MACHINE_FOLDER
"$REPO/.claude/tools/watch.sh" $LIMITS -- sh "$HERE/docker-run.sh"
