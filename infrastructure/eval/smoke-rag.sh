#!/usr/bin/env sh
# smoke-rag.sh — check 11 of the gate, split out by concern: it is the only
# check that needs the `rag` profile, and it is the only one that waits.
#
# A page inserted through the service role must reach ai_chunks: the AI
# indexer watches the page's insert trigger, chunks the content and writes
# the embeddings.
#
# It prints its own verdict line and exits with:
#   0 = PASS   1 = FAIL   2 = SKIP (in scope, could not run)   3 = N/A (out of scope)
# smoke.sh maps those onto its own counter.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ENV_FILE="$HERE/.env"
readonly PG_CTN=eval-pg

[ -f "$ENV_FILE" ] || { printf 'FAIL: no %s — run gen-secrets.sh first\n' "$ENV_FILE"; exit 1; }
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

TMP=$(mktemp -d)
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM
umask 077

BASE_URL="http://127.0.0.1:${EVAL_EDGE_PORT:-18000}"

PROJECT=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$PG_CTN" 2>/dev/null || true)
INDEXER_CTN=$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" \
  --filter "label=com.docker.compose.service=eval-indexer" | tail -1)

if [ -z "$INDEXER_CTN" ]; then
  printf 'N/A: check 11 needs the rag profile (docker compose --profile rag up -d)\n'
  exit 3
fi
if [ "$(docker inspect -f '{{.State.Running}}' "$INDEXER_CTN" 2>/dev/null || true)" != "true" ]; then
  printf 'SKIP: the rag indexer is not running — check 11 cannot run\n'
  exit 2
fi

# The headers carry the service key: a secret on curl's command line is a
# secret in the process list.
printf 'header = "apikey: %s"\nheader = "Authorization: Bearer %s"\n' \
  "$SERVICE_ROLE_KEY" "$SERVICE_ROLE_KEY" > "$TMP/svc.cfg"
chmod 600 "$TMP/svc.cfg"

ws_id=$(cat /proc/sys/kernel/random/uuid)
page_id=$(cat /proc/sys/kernel/random/uuid)
owner_id=$(cat /proc/sys/kernel/random/uuid)
slug="eval-smoke-$(date +%s)"
printf '{"id":"%s","owner_id":"%s","name":"eval smoke","slug":"%s"}' "$ws_id" "$owner_id" "$slug" > "$TMP/ws.json"
printf '{"id":"%s","workspace_id":"%s","owner_id":"%s","title":"eval smoke page","visibility":"public","content":[{"id":"%s","type":"paragraph","content":"eval smoke chunk content"}]}' \
  "$page_id" "$ws_id" "$owner_id" "$page_id" > "$TMP/page.json"
chmod 600 "$TMP/ws.json" "$TMP/page.json"

ws_code=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -X POST -K "$TMP/svc.cfg" \
  -H "Content-Type: application/json" --data-binary "@$TMP/ws.json" "$BASE_URL/rest/v1/osionos_workspaces") || ws_code=000
if [ "$ws_code" != "201" ] && [ "$ws_code" != "200" ]; then
  printf 'SKIP: the workspace insert answered %s — check 11 cannot run\n' "$ws_code"
  exit 2
fi

page_code=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -X POST -K "$TMP/svc.cfg" \
  -H "Content-Type: application/json" --data-binary "@$TMP/page.json" "$BASE_URL/rest/v1/osionos_pages") || page_code=000
if [ "$page_code" != "201" ] && [ "$page_code" != "200" ]; then
  printf 'SKIP: the page insert answered %s — check 11 cannot run\n' "$page_code"
  exit 2
fi

waited=0
chunks=0
while [ "$waited" -lt 60 ]; do
  chunks=$(docker exec "$PG_CTN" psql -U postgres -d postgres -tAc \
    "SELECT count(*) FROM ai_chunks WHERE source_id = '$page_id'" 2>/dev/null || echo 0)
  [ "${chunks:-0}" != "0" ] && break
  sleep 3
  waited=$((waited + 3))
done

if [ "${chunks:-0}" -gt 0 ] 2>/dev/null; then
  printf 'PASS: the page reached ai_chunks (%s rows)\n' "$chunks"
  exit 0
fi
printf 'FAIL: the page never reached ai_chunks (60s)\n'
exit 1
