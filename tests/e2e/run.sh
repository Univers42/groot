#!/usr/bin/env bash
# Runs the suite in the pinned Playwright container against the live local stack.
# --network host so https://localhost:3001/:3007 resolve to the host's proxy; --rm so no
# container (and no Chromium) outlives the run.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
image="${E2E_IMAGE:-groot-e2e:1.63.0}"
ca="$root/apps/grobase/certs/track-binocle-local-ca.pem"
[[ -r "$ca" ]] || { echo "[e2e] no local CA at $ca — run: make certs" >&2; exit 2; }
docker build -q -t "$image" "$here" >/dev/null
mkdir -p "$here/test-results"
env_args=()
while IFS= read -r name; do env_args+=(-e "$name"); done < <(compgen -e | grep '^E2E_' || true)
# Rootless Docker maps the host user to the container's root and nothing else, so --user
# fails there ("cannot setuid to unmapped uid"); root inside already is this user outside,
# and test-results come back owned by them either way.
user_args=(--user "$(id -u):$(id -g)")
if docker info -f '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then user_args=(); fi
exec docker run --rm -e NPM_CONFIG_UPDATE_NOTIFIER=false --init --network host --ipc host \
  "${user_args[@]}" -e HOME=/tmp/e2e-home \
  "${env_args[@]}" \
  -v "$ca:/certs/local-ca.pem:ro" \
  -v "$here/specs:/e2e/specs:ro" -v "$here/lib:/e2e/lib:ro" \
  -v "$here/playwright.config.ts:/e2e/playwright.config.ts:ro" \
  -v "$here/tsconfig.json:/e2e/tsconfig.json:ro" \
  -v "$here/test-results:/e2e/test-results" \
  "$image" sh -c 'npx tsc -p tsconfig.json && npx playwright test "$@"' sh "$@"
