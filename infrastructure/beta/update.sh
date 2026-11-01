#!/usr/bin/env bash
# Rebuilds the develop beta when origin/develop moves (groot ADR 0040). Production is never touched:
# only containers and images labelled osionos.beta=1, in compose project osionos-beta (B5).
# A failed fetch, build or health check leaves the running beta as it is (B9).
set -euo pipefail
B=/mnt/storage/dlesieur/osionos-beta
# Production builds with groot main's Dockerfile (deploy/root), not the live checkout's, which lags.
DOCKERFILE="$B/app.Dockerfile"
exec 9>"$B/.lock"
flock -n 9 || { echo "another update is running"; exit 0; }
log() { echo "$(date -Is) $*"; }

cd "$B/src"
timeout 120 git fetch -q origin develop
sha="$(git rev-parse --short=12 origin/develop)"
if [ "$sha" = "$(cat "$B/deployed" 2>/dev/null || true)" ] && [ "${1:-}" != "--force" ]; then exit 0; fi
log "develop is $sha, building"
git checkout -q --detach origin/develop
timeout 600 git submodule update --init --recursive -q

# shellcheck source=/dev/null
. "$B/build.env"   # PUBLIC_* origins and GRAPH_RENDER_SHA only: no secrets.
timeout 120 git -C "$B/root" fetch -q origin main
git -C "$B/root" show origin/main:infrastructure/docker/osionos/app.Dockerfile > "$DOCKERFILE.tmp"
mv "$DOCKERFILE.tmp" "$DOCKERFILE"
BETA=https://baas-beta.tail10f2ea.ts.net
timeout 2700 nice -n 10 ionice -c3 docker build -q \
  -f "$DOCKERFILE" \
  --label osionos.beta=1 --label "osionos.beta.sha=$sha" \
  --build-arg GRAPH_RENDER_SHA="$GRAPH_RENDER_SHA" \
  --build-arg VITE_API_URL=https://baas-beta.tail10f2ea.ts.net:10000 \
  --build-arg VITE_PRISMATICA_URL="$PUBLIC_SITE_ORIGIN" \
  --build-arg VITE_BAAS_URL="$BETA" \
  --build-arg VITE_BAAS_API_KEY= --build-arg VITE_BAAS_KONG_KEY= --build-arg VITE_BAAS_REALTIME_TOKEN= \
  --build-arg VITE_OSIONOS_IDE_URL= \
  --build-arg VITE_MAIL_APP_URL="$PUBLIC_MAIL_ORIGIN" \
  --build-arg VITE_CALENDAR_APP_URL="$PUBLIC_CALENDAR_ORIGIN" \
  --build-arg VITE_WHITEBOARD_APP_URL= \
  --build-arg VITE_REQUIRE_BRIDGE_SESSION=true --build-arg VITE_ALLOW_OFFLINE_MODE=false \
  --build-arg VITE_AUTH_MODE=portal \
  --build-arg VITE_AI_URL=https://baas-beta.tail10f2ea.ts.net:10000 \
  --build-arg VITE_PAGE_ACTION_SYNC_ENABLED=true \
  --build-arg VITE_OSIO_COLLAB_SHARED=1 --build-arg VITE_OSIO_COLLAB_FASTSEND=1 \
  --build-arg VITE_APP_VERSION="beta-$sha" \
  -t "osionos-beta/web:$sha" . >/dev/null

# Health check on a candidate before the switch: the page must come back with its title.
docker rm -f osionos-beta-candidate >/dev/null 2>&1 || true
docker run -d --rm --name osionos-beta-candidate --label osionos.beta=1 --network none "osionos-beta/web:$sha" >/dev/null
ok=0
for _ in $(seq 1 30); do
  if docker exec osionos-beta-candidate wget -qO- http://127.0.0.1/ 2>/dev/null | grep -q "<title>"; then ok=1; break; fi
  sleep 1
done
docker rm -f osionos-beta-candidate >/dev/null 2>&1 || true
[ "$ok" = 1 ] || { log "candidate $sha failed its health check; the beta keeps $(cat "$B/deployed" 2>/dev/null)"; exit 1; }

BETA_SHA="$sha" docker compose -f "$B/compose.yml" up -d app edge
echo "$sha" >"$B/deployed"
log "beta now serves $sha"

# Keep the 2 newest beta images (B12).
docker images --filter label=osionos.beta=1 --format '{{.CreatedAt}}\t{{.Repository}}:{{.Tag}}' \
  | sort -r | tail -n +3 | cut -f2 | xargs -r docker rmi >/dev/null 2>&1 || true
