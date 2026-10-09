#!/usr/bin/env bats
# The osionos-app image serves graph_render's published pack under /graph-studio/<pin>/, where
# <pin> is groot's apps/graph_render gitlink. These tests run the BUILT image (GS_IMAGE) and read
# the expected bytes from the pack image itself, by the digest app.Dockerfile pins.
#
# Needs docker and curl. The CI job (.github/workflows/graph-studio.yml) builds the image the way
# make does — compose, with GRAPH_RENDER_SHA read from the gitlink — then runs:
#   GS_IMAGE=track-binocle/osionos-web:local GS_BUILD=1 bats tests/graph-studio
# GS_BUILD=1 also runs the build-time negative controls (two more compose builds; the builder
# stage is cached by the first, so only the runtime stage reruns).

DOCKERFILE=infrastructure/docker/osionos/app.Dockerfile

setup_file() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  : "${GS_IMAGE:?set GS_IMAGE to the built osionos-app image}"
  PIN=$(git -C "$REPO" ls-tree HEAD apps/graph_render | awk '$2 == "commit" { print $3 }')
  PACK=$(sed -n 's/^ARG GRAPH_STUDIO_PACK=//p' "$REPO/$DOCKERFILE")
  [ "${#PIN}" -eq 40 ] && [ -n "$PACK" ]
  EXPECTED=$BATS_FILE_TMPDIR/pack
  mkdir -p "$EXPECTED"
  cid=$(docker create "$PACK" none)
  docker cp "$cid:/pack/." "$EXPECTED"
  docker rm "$cid" >/dev/null
  APP=$(docker run -d -p 127.0.0.1::80 "$GS_IMAGE")
  BASE=http://$(docker port "$APP" 80/tcp | head -1)
  for _ in $(seq 50); do curl -fsS -o /dev/null "$BASE/" && break; sleep 0.2; done
  export REPO PIN PACK EXPECTED APP BASE
}

teardown_file() {
  [ -z "${APP:-}" ] || docker rm -f "$APP" >/dev/null
}

# GET $1 into $BATS_TEST_TMPDIR/body; prints "<status> <content-type>".
fetch() {
  curl -sS -o "$BATS_TEST_TMPDIR/body" -D "$BATS_TEST_TMPDIR/headers" -w '%{http_code} %{content_type}' "$@"
}

sha_of() { sha256sum "$1" | cut -d' ' -f1; }

# The sha256 pack.json records for file $1.
listed_sha() {
  sed -n "s/.*\"$1\": *{[^}]*\"sha256\": *\"\([0-9a-f]\{64\}\)\".*/\1/p" "$EXPECTED/pack.json"
}

assert_pack_file() {
  run fetch "$BASE/graph-studio/$PIN/$1"
  [ "$output" = "200 $2" ]
  want=$(listed_sha "$1")
  [ "${#want}" -eq 64 ]
  [ "$(sha_of "$BATS_TEST_TMPDIR/body")" = "$want" ]
  grep -qi '^cache-control: public, immutable' "$BATS_TEST_TMPDIR/headers"
}

@test "the pinned pack was built from the apps/graph_render gitlink" {
  run docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$PACK"
  [ "$output" = "$PIN" ]
  grep -q "^ *\"source_rev\": *\"$PIN\"" "$EXPECTED/pack.json"
}

@test "the image's nginx config is valid" {
  run docker exec "$APP" nginx -t
  [ "$status" -eq 0 ]
}

@test "graph-studio.js is served byte-exact as JavaScript" {
  assert_pack_file graph-studio.js application/javascript
}

@test "worker.js is served byte-exact as JavaScript" {
  assert_pack_file worker.js application/javascript
}

@test "helper.js is served byte-exact as JavaScript" {
  assert_pack_file helper.js application/javascript
}

@test "graph_wasm.wasm is served byte-exact as application/wasm" {
  assert_pack_file graph_wasm.wasm application/wasm
}

@test "graph_wasm_threads.wasm is served byte-exact as application/wasm" {
  assert_pack_file graph_wasm_threads.wasm application/wasm
}

@test "pack.json is served byte-exact as JSON" {
  run fetch "$BASE/graph-studio/$PIN/pack.json"
  [ "$output" = "200 application/json" ]
  [ "$(sha_of "$BATS_TEST_TMPDIR/body")" = "$(sha_of "$EXPECTED/pack.json")" ]
  grep -q "\"source_rev\": *\"$PIN\"" "$BATS_TEST_TMPDIR/body"
}

@test "the wasm, gzip-encoded, decodes to the same bytes" {
  run fetch --compressed "$BASE/graph-studio/$PIN/graph_wasm.wasm"
  [ "$output" = "200 application/wasm" ]
  grep -qi '^content-encoding: gzip' "$BATS_TEST_TMPDIR/headers"
  [ "$(sha_of "$BATS_TEST_TMPDIR/body")" = "$(listed_sha graph_wasm.wasm)" ]
}

@test "a missing file under /graph-studio/ is a 404, never the SPA's index.html" {
  for path in "$PIN/nope.wasm" "$PIN/nope.js" "$PIN/nope" "$PIN/" "0000000000000000000000000000000000000000/graph-studio.js"; do
    run fetch "$BASE/graph-studio/$path"
    [ "${output%% *}" = 404 ]
    run grep -q 'graph-studio-base' "$BATS_TEST_TMPDIR/body"
    [ "$status" -ne 0 ]
  done
}

@test "index.html carries the graph-studio-base meta exactly once, pointing at the pin" {
  run fetch "$BASE/index.html"
  [ "${output%% *}" = 200 ]
  [ "$(grep -o '<meta name="graph-studio-base"[^>]*>' "$BATS_TEST_TMPDIR/body" | wc -l)" -eq 1 ]
  grep -q "<meta name=\"graph-studio-base\" content=\"/graph-studio/$PIN/\"" "$BATS_TEST_TMPDIR/body"
  grep -qi '^cache-control: no-cache' "$BATS_TEST_TMPDIR/headers"
}

@test "the app's routes still fall back to the SPA" {
  fetch "$BASE/index.html" >/dev/null
  cp "$BATS_TEST_TMPDIR/body" "$BATS_TEST_TMPDIR/index"
  for path in / /some/deep/route /workspace/abc; do
    run fetch "$BASE$path"
    [ "$output" = "200 text/html" ]
    cmp -s "$BATS_TEST_TMPDIR/body" "$BATS_TEST_TMPDIR/index"
  done
}

# The same compose build the job ran, expecting commit $1; prints the build log.
compose_build() {
  GRAPH_RENDER_SHA=$1 docker compose -f "$REPO/docker-compose.yml" --profile dev --progress plain \
    build osionos-app 2>&1
}

@test "the build refuses a pack whose source_rev is not the expected commit" {
  [ "${GS_BUILD:-}" = 1 ] || skip "GS_BUILD unset — build-time negative control not run"
  wrong=$(printf '%s' "$PIN" | tr '0-9a-f' '1-9a-f0')
  run compose_build "$wrong"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pack source_rev $PIN is not the expected $wrong"* ]]
}

@test "the build refuses a missing expected commit" {
  [ "${GS_BUILD:-}" = 1 ] || skip "GS_BUILD unset — build-time negative control not run"
  run compose_build ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"GRAPH_RENDER_SHA must be"* ]]
}
