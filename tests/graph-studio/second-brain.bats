#!/usr/bin/env bats
# osionos-app is built with VITE_LEGACY_SECOND_BRAIN=false (app.Dockerfile), so its bundle holds
# the graph_render host and none of the legacy second brain: the gate is folded at build time
# and the legacy chunk is dropped. Read from the BUILT image (GS_IMAGE), as the CI job builds it.

setup_file() {
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  : "${GS_IMAGE:?set GS_IMAGE to the built osionos-app image}"
  JS=$BATS_FILE_TMPDIR/bundle.js
  docker run --rm --entrypoint sh "$GS_IMAGE" -c 'cat /usr/share/nginx/html/assets/*.js' >"$JS"
  [ -s "$JS" ]
  export REPO JS
}

@test "the needles exist in osionos's source, so a zero below is not vacuous" {
  grep -rq 'osio-sb-graph-snapshot' "$REPO/apps/osionos/app/src/features/legacy-second-brain"
  grep -rq 'osio-graph__fg' "$REPO/apps/osionos/app/packages/legacy-graph-engine/src"
  grep -rq 'graph-studio-base' "$REPO/apps/osionos/app/src/features/graph-studio"
}

@test "the bundle carries the graph_render host (its loader reads graph-studio-base)" {
  grep -q 'graph-studio-base' "$JS"
}

@test "the bundle carries none of the legacy second brain" {
  run grep -c -e 'osio-sb-graph-snapshot' -e 'osio-graph__fg' "$JS"
  [ "$output" = 0 ]
}
