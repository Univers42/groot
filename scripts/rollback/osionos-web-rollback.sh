#!/usr/bin/env bash
# osionos-web-rollback.sh — put the osionos web image back to a named previous image (ADR 0046,
# "proven rollback"), then print the header counts a browser would see. Human-run:
#   PREV_IMAGE=<repo:tag@sha256:digest> [COMPOSE_PROJECT=...] [COMPOSE_FILE=...] \
#     [CHECK_URL=https://localhost:3001] bash scripts/rollback/osionos-web-rollback.sh
# PREV_IMAGE is the exact image the service ran before the change: record `docker inspect
# --format '{{.Image}} {{.Config.Image}}' <container>` before promoting. For the CSP work (#314) the
# target of an enforce rollback is the Report-Only image, never one older than it.
#
# Only the osionos-app service is recreated (--no-deps), so the edge, Kong and the bridge are not
# touched. "Rolled back" is only claimed on the printed table: CSP / Report-Only / XFO per path.
# Caveat: the table counts header lines with curl -sI on a few paths; it does not boot a browser.
# Run the Chromium boot check as well.
set -euo pipefail

prev=${PREV_IMAGE:-}
[[ -n "$prev" ]] || { echo "PREV_IMAGE is required (repo:tag@sha256:digest)" >&2; exit 2; }
docker image inspect "$prev" >/dev/null 2>&1 || { echo "image $prev is not present on this host: pull or load it first" >&2; exit 2; }
check_url=${CHECK_URL:-https://localhost:3001}
service=${SERVICE:-osionos-app}

before=$(docker compose ${COMPOSE_PROJECT:+-p "$COMPOSE_PROJECT"} images -q "$service" 2>/dev/null | head -1 || true)
echo "== before: ${before:-none}"
OSIONOS_APP_IMAGE=$prev docker compose ${COMPOSE_PROJECT:+-p "$COMPOSE_PROJECT"} up -d --no-deps --force-recreate "$service"

for _ in $(seq 60); do
  [[ "$(curl -sk -o /dev/null -w '%{http_code}' "$check_url/")" == 200 ]] && break
  sleep 1
done
echo "== now: $(docker compose ${COMPOSE_PROJECT:+-p "$COMPOSE_PROJECT"} images -q "$service" | head -1)"

printf '%-22s %-4s %-4s %-4s %s\n' path CSP RO XFO status
for path in / /some/deep/route /index.html '/sw.js?v=2' /assets/x.js; do
  head=$(curl -sk -o /dev/null -D - "$check_url$path" | tr -d '\r')
  count() { grep -ci "^$1:" <<<"$head" || true; }
  printf '%-22s %-4s %-4s %-4s %s\n' "$path" "$(count content-security-policy)" \
    "$(count content-security-policy-report-only)" "$(count x-frame-options)" "$(head -1 <<<"$head" | cut -d' ' -f2)"
done
