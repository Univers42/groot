#!/bin/sh
# Called by run-smoke.sh under watch.sh; the demo password arrives on fd 3 and goes to the
# container's stdin only.
set -eu
exec docker run --rm -i --network host --ipc host \
	-v "$E_DIR":/app:ro -v "$HERE":/smoke:ro -v "$OUT":/out \
	-v osionos-electron-smoke-cache:/cache \
	-v "$REPO/apps/grobase/certs/track-binocle-local-ca.pem":/ca.pem:ro \
	-e DEMO_LOGIN_EMAIL \
	-e OSIONOS_BAAS_URL="${OSIONOS_BAAS_URL:-http://127.0.0.1:8000}" \
	--entrypoint /smoke/container-entry.sh "$IMG" <&3
