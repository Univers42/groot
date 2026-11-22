#!/usr/bin/env bats
# osionos#313: a deploy recreated the web container from an image holding only its own build, so
# every tab still on the previous build got a 404 for the chunk it lazy-loaded next (about 630 of
# 1092 asset files are renamed per build). app.Dockerfile's 40-keep-assets.sh keeps the last five
# builds' /assets in a volume, and osionos's nginx.conf falls back to it for /assets/ only.
# These tests run the real pair (osionos nginx.conf + the script, read out of app.Dockerfile's
# heredoc) in the runtime base image over fake builds. Containers and volumes are named t313-*.
#
# No bind mounts: every file goes in with docker cp and every request is curl inside the
# container, so the tests also run from a bats container that only has the docker socket.
# Without docker they skip, unless KEPT_REQUIRE_DOCKER=1 (the CI step) makes that a failure.
#
# Run (OSIONOS_DIR defaults to the apps/osionos/app submodule):
#   docker run --rm -e KEPT_REQUIRE_DOCKER=1 -e OSIONOS_DIR -v /var/run/docker.sock:/var/run/docker.sock \
#     -v "$PWD:/code" -w /code --entrypoint sh bats/bats:1.11.1 \
#     -c 'apk add -q --no-cache docker-cli && bats scripts/tests/osionos-kept-assets.bats'

DOCKERFILE=infrastructure/docker/osionos/app.Dockerfile
SCRIPT_PATH=/docker-entrypoint.d/40-keep-assets.sh
KEPT=/var/lib/osionos-kept

setup_file() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  OSIONOS_DIR=${OSIONOS_DIR:-$REPO/apps/osionos/app}
  NGINX_IMAGE=${KEPT_NGINX_IMAGE:-$(sed -n 's/^FROM \([^ ]*nginx[^ ]*\) AS runtime$/\1/p' "$REPO/$DOCKERFILE")}
  TAG=t313-bats-$$
  export REPO OSIONOS_DIR NGINX_IMAGE TAG
}

setup() {
  if ! docker info >/dev/null 2>&1; then
    [ "${KEPT_REQUIRE_DOCKER:-}" != 1 ] || { echo "docker is required here (KEPT_REQUIRE_DOCKER=1)"; return 1; }
    skip "no docker daemon reachable"
  fi
  [ -n "$NGINX_IMAGE" ] && [ -f "$OSIONOS_DIR/docker/services/node/nginx.conf" ]
  FIX=$BATS_TEST_TMPDIR/fix
  mkdir -p "$FIX"
  cp "$OSIONOS_DIR/docker/services/node/nginx.conf" "$FIX/default.conf"
  awk -v p="$SCRIPT_PATH" '$1 == "COPY" && $NF == p && index($0, "<<") {on = 1; next}
    on && /^SH$/ {exit} on' "$REPO/$DOCKERFILE" >"$FIX/keep.sh"
  chmod 755 "$FIX/keep.sh"
  VOL=$TAG-$BATS_TEST_NUMBER
}

teardown() {
  docker ps -aq --filter "name=^$TAG-" | xargs -r docker rm -f >/dev/null
  docker volume ls -q --filter "name=^$TAG-" | xargs -r docker volume rm >/dev/null
}

# A fake build $1: its own entry chunk (+ .gz) and font, and one chunk every build shares.
make_build() {
  local dir=$BATS_TEST_TMPDIR/build-$1
  mkdir -p "$dir/assets"
  printf '<!doctype html><title>%s</title>\n' "$1" >"$dir/index.html"
  awk -v b="$1" 'BEGIN { for (i = 0; i < 200; i++) print "export const " b i " = " i ";" }' >"$dir/assets/only-$1.js"
  gzip -9c "$dir/assets/only-$1.js" >"$dir/assets/only-$1.js.gz"
  printf 'font %s\n' "$1" >"$dir/assets/font-$1.ttf"
  printf 'export const shared = 1;\n' >"$dir/assets/shared.js"
  echo "$dir"
}

# Starts build $1 as container $2 with docker-run mount flags $3...; waits until nginx answers.
start_build() {
  local build=$1 name=$TAG-$2 dir
  shift 2
  dir=$(make_build "$build")
  docker create --name "$name" "$@" "$NGINX_IMAGE" >/dev/null
  docker cp "$FIX/default.conf" "$name:/etc/nginx/conf.d/default.conf"
  docker cp "$FIX/keep.sh" "$name:$SCRIPT_PATH"
  docker cp "$dir/." "$name:/usr/share/nginx/html/"
  docker start "$name" >/dev/null
  for _ in $(seq 50); do
    docker exec "$name" curl -fso /dev/null http://127.0.0.1/ 2>/dev/null && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || break
    sleep 0.1
  done
  docker logs "$name" 2>&1 | tail -20
  return 1
}

# One deploy: the previous container stops, build $1 starts on the shared volume.
deploy() {
  docker ps -q --filter "name=^$TAG-" | xargs -r docker stop -t 1 >/dev/null
  DEPLOYS=$((${DEPLOYS:-0} + 1))
  start_build "$1" "$1-$DEPLOYS" -v "$VOL:$KEPT"
}

current() { docker ps -q --filter "name=^$TAG-" | head -1; }

# GET $1 from the running container, gzip accepted; prints the status line and headers, lowercased.
fetch() {
  docker exec "$(current)" curl -sS -o /dev/null -D - -H 'Accept-Encoding: gzip' "http://127.0.0.1$1" |
    tr -d '\r' | tr 'A-Z' 'a-z'
}

status_of() { fetch "$1" | awk 'NR == 1 { print $2 }'; }

# The D313-1 headers on an asset answer ($1 = fetch output).
assert_asset_headers() {
  grep -qx 'content-type: application/javascript' <<<"$1"
  grep -qx 'content-encoding: gzip' <<<"$1"
  grep -qx 'cache-control: public, immutable' <<<"$1"
  grep -q '^expires: ' <<<"$1"
  grep -qx 'x-frame-options: deny' <<<"$1"
  grep -qx "content-security-policy: frame-ancestors 'none'" <<<"$1"
}

@test "(i) after A->B, A's chunk answers 200 javascript, gzip, immutable, unframeable" {
  deploy a
  deploy b
  out=$(fetch /assets/only-a.js)
  echo "$out"
  [[ "$out" == "http/1.1 200 ok"* ]]
  assert_asset_headers "$out"
  assert_asset_headers "$(fetch /assets/only-b.js)"
}

@test "(ii) a missing .js and a missing .ttf answer 404, never the app page" {
  deploy a
  deploy b
  [ "$(status_of /assets/nope-deadbeef.js)" = 404 ]
  out=$(fetch /assets/KaTeX_Main-Regular-deadbeef.ttf)
  echo "$out"
  [ "$(awk 'NR == 1 { print $2 }' <<<"$out")" = 404 ]
}

@test "(iii) after K+1 = 6 builds the oldest build's own files are gone, the current one intact" {
  for build in a b c d e f; do deploy "$build"; done
  [ "$(status_of /assets/only-a.js)" = 404 ]
  [ "$(status_of /assets/font-a.ttf)" = 404 ]
  for build in b c d e; do [ "$(status_of "/assets/only-$build.js")" = 200 ]; done
  for path in only-f.js only-f.js.gz font-f.ttf shared.js; do [ "$(status_of "/assets/$path")" = 200 ]; done
  run docker run --rm -v "$VOL:$KEPT:ro" --entrypoint ls "$NGINX_IMAGE" "$KEPT/assets"
  [[ "$output" != *only-a* ]] && [[ "$output" == *only-f.js.gz* ]]
}

# The container still serves its own build after the script skipped, saying why ($1).
assert_serves_own_build() {
  [ "$(status_of /assets/only-a.js)" = 200 ]
  docker logs "$(current)" 2>&1 | grep "40-keep-assets.sh: skipped: " | grep -q "$1"
}

@test "(iv) unmounted, read-only or full: nginx still starts and serves the current build" {
  start_build a bare
  assert_serves_own_build "not a mounted volume"
  docker rm -f "$(current)" >/dev/null
  docker volume create "$VOL" >/dev/null
  start_build a ro -v "$VOL:$KEPT:ro"
  assert_serves_own_build "not writable"
  docker rm -f "$(current)" >/dev/null
  docker volume create --opt type=tmpfs --opt device=tmpfs --opt o=size=16m "$VOL-full" >/dev/null
  start_build a full -v "$VOL-full:$KEPT"
  assert_serves_own_build "under 1 GiB"
}

@test "(v) restarting the same build does not count as a new build" {
  for build in a b c d e; do deploy "$build"; done
  for _ in 1 2 3; do deploy e; done
  docker restart -t 1 "$(current)" >/dev/null
  for _ in $(seq 50); do docker exec "$(current)" curl -fso /dev/null http://127.0.0.1/ 2>/dev/null && break; sleep 0.1; done
  [ "$(status_of /assets/only-a.js)" = 200 ]
  deploy f
  [ "$(status_of /assets/only-a.js)" = 404 ]
  [ "$(status_of /assets/only-b.js)" = 200 ]
}

@test "(vi) a file left half-copied is never served, and is gone after the next start" {
  deploy a
  docker stop -t 1 "$(current)" >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/plant/.incoming"
  printf 'export const torn' >"$BATS_TEST_TMPDIR/plant/.incoming/only-z.js"
  docker create --name "$TAG-plant" -v "$VOL:$KEPT" "$NGINX_IMAGE" >/dev/null
  docker cp "$BATS_TEST_TMPDIR/plant/." "$TAG-plant:$KEPT/"
  docker rm "$TAG-plant" >/dev/null
  deploy b
  for path in /assets/only-z.js /assets/.incoming/only-z.js /assets/../.incoming/only-z.js /.incoming/only-z.js; do
    out=$(docker exec "$(current)" curl -s --path-as-is "http://127.0.0.1$path")
    [ "$out" != 'export const torn' ] || { echo "served the torn file at $path"; false; }
  done
  run docker run --rm -v "$VOL:$KEPT:ro" --entrypoint find "$NGINX_IMAGE" "$KEPT" -name only-z.js
  [ -z "$output" ]
}

# D313-13: after a security or storage-format deploy, old tabs must not keep running old code.
@test "--purge drops every earlier build, keeps the running one, and fails loudly without a volume" {
  deploy a
  deploy b
  run docker exec "$(current)" "$SCRIPT_PATH" --purge
  [ "$status" -eq 0 ]
  [ "$(status_of /assets/only-a.js)" = 404 ]
  deploy c
  [ "$(status_of /assets/only-b.js)" = 200 ]
  docker rm -f "$(current)" >/dev/null
  start_build a bare
  run docker exec "$(current)" "$SCRIPT_PATH" --purge
  [ "$status" -ne 0 ]
}

# D313-12: the first fixed image finds an empty volume; seeding it from the running pre-fix
# container's assets before the swap keeps that build's chunks too.
@test "--seed keeps the assets tar read from stdin as one more build" {
  start_build a old
  docker cp "$TAG-old:/usr/share/nginx/html/assets" - >"$BATS_TEST_TMPDIR/seed.tar"
  docker create -i --name "$TAG-seed" -v "$VOL:$KEPT" "$NGINX_IMAGE" "$SCRIPT_PATH" --seed >/dev/null
  docker cp "$FIX/keep.sh" "$TAG-seed:$SCRIPT_PATH"
  run docker start -ai "$TAG-seed" <"$BATS_TEST_TMPDIR/seed.tar"
  echo "$output"
  [ "$status" -eq 0 ]
  deploy b
  [ "$(status_of /assets/only-a.js)" = 200 ]
  for build in c d e; do deploy "$build"; done
  [ "$(status_of /assets/only-a.js)" = 200 ]
  deploy f
  [ "$(status_of /assets/only-a.js)" = 404 ]
}
