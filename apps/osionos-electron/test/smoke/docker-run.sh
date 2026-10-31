#!/bin/sh
# Called by run-smoke.sh under watch.sh; the demo password arrives on fd 3 and goes to the
# container's stdin only.
set -eu
# OSIONOS_BAAS_URL only when set: unset, main.js takes the grobase build.sh baked into
# desktop-config.json (else 127.0.0.1:8000), which is what the installed app does.
set --
[ -z "${OSIONOS_BAAS_URL:-}" ] || set -- -e OSIONOS_BAAS_URL
exec docker run --rm -i --network host --ipc host \
	-v "$E_DIR":/app:ro -v "$HERE":/smoke:ro -v "$OUT":/out \
	-v osionos-electron-smoke-cache:/cache \
	-v "$REPO/apps/grobase/certs/track-binocle-local-ca.pem":/ca.pem:ro \
	-e DEMO_LOGIN_EMAIL -e MACHINE_FOLDER "$@" \
	--entrypoint "/smoke/${ENTRY:-container-entry.sh}" "$IMG" <&3
